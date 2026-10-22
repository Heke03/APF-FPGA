// Predictive (deadbeat) current controller and DC-link voltage loop for the
// three-wire shunt APF. One computation per 10 kHz frame, about 70 clocks.
//
// Design study: model/closed_loop_design.py (float). Per frame k:
//   1. Rebuild the voltage the inverter applied over [k, k+1] from the
//      duties issued last frame, and predict the filter current at k+1.
//   2. Predict the reference for k+2 from the stored reference one grid cycle
//      earlier (load harmonics repeat every cycle), minus the DC-link term.
//   3. Choose the inverter voltage that moves the predicted current toward
//      that reference (gain G of deadbeat), plus grid-voltage feedforward.
//   4. Add min/max common-mode injection, divide by Vdc, add dead-time
//      compensation, and issue duties 0..HALF_TICKS for frame k+1.
//   The DC-link PI runs once per grid cycle on the average of that cycle.
//
// Units (set by the ADC scaling in apf_core):
//   grid voltage: 16 counts/V  | current: 800 units/A (ADC counts * 8)
//   Vdc input:    10 counts/V  | cos: Q16
// Constant gains assume Ts = 100 us and L = 3 mH; see the parameter notes.
module current_controller #(
    parameter integer HALF_TICKS = 2500,
    parameter integer WINDOW     = 200,     // frames per grid cycle
    parameter integer PRED_LEAD  = 3,       // history slot ahead of the write slot
    parameter integer K_PRED     = 6827,    // Q12: Ts/L * 800/16  (current units per voltage unit)
    parameter integer K_CTRL     = 1229,    // Q12: G * L/Ts * 16/800 with G = 0.5
    parameter integer DT_COMP    = 50,      // dead time / Ts * HALF_TICKS
    parameter integer VDC_REF    = 3000,    // 300 V
    parameter integer VDC_RAMP   = 100,     // counts per grid cycle (500 V/s)
    parameter integer KP_DC      = 8,       // current units per Vdc count (0.1 A/V)
    parameter integer KI_DC      = 410,     // Q8, per grid cycle (1 A/(V s))
    parameter integer IDC_MAX    = 8000,    // 10 A
    parameter integer VDC16_MIN  = 800      // divider floor (50 V)
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                go,          // all inputs below are valid for frame k
    input  logic                run,         // inverter switching from the next frame
    input  logic signed [12:0]  vg_a, vg_b,  // grid phase voltages
    input  logic signed [15:0]  if_a, if_b,  // filter (inverter) currents
    input  logic [11:0]         vdc,
    input  logic                ref_ok,      // apf_reference produced reference_a/b for frame k
    input  logic signed [17:0]  ref_a, ref_b,
    input  logic signed [17:0]  cos_next_a, cos_next_b,  // PLL cosines for frame k+1
    output logic                ready_to_run,  // one full cycle of reference history stored
    output logic                duty_valid,
    output logic [15:0]         duty_a, duty_b, duty_c,
    output logic signed [15:0]  idc_cmd,
    output logic [11:0]         vdc_avg,
    output logic [11:0]         vdc_target
);
    localparam integer IDX_W = $clog2(WINDOW);
    localparam integer CNT_W = $clog2(WINDOW + 1);
    localparam logic [35:0] SCALE_NUM = 36'(HALF_TICKS) << 24;
    localparam logic [25:0] RECIP_WINDOW = 26'(((64'd1 << 24) + WINDOW - 1) / WINDOW);
    localparam logic [11:0] RECIP_7500_SCALED = 12'd2237;   // 2^24 / (3 * HALF_TICKS) for 2500
    localparam integer ACC_MAX = IDC_MAX * 256;
    localparam logic signed [21:0] DT_POS = 22'(DT_COMP);
    localparam logic signed [21:0] DT_NEG = 22'(-DT_COMP);

    typedef enum logic [3:0] {
        IDLE, DIVIDE, UPREV1, UPREV2, PREDICT1, PREDICT2, REFER, CONTROL1, CONTROL2,
        OFFSET, DUTY1, DUTY2, FINISH, DC_LOOP
    } state_t;
    state_t state;


    // Captured frame
    logic signed [12:0] vg_q [0:1];
    logic signed [12:0] vg_prev [0:1];
    logic signed [15:0] if_q [0:1];
    logic signed [17:0] ref_a_q, ref_b_q;
    logic signed [17:0] cos_q [0:1];
    logic [11:0] vdc_q;
    logic run_q, ref_ok_q, fresh;

    // Divider: scale = HALF_TICKS * 2^24 / vdc16
    logic [12:0] vdc16;
    logic [35:0] div_num;
    logic [26:0] div_rem;
    logic [27:0] div_shift;
    logic [25:0] scale;
    logic [5:0] step;

    logic [11:0] raw [0:2];          // last raw duties (without dead-time compensation)
    logic signed [14:0] dsum [0:1];
    logic signed [27:0] vd_prod [0:1];
    logic signed [19:0] u_prev [0:1];
    logic signed [13:0] dv [0:1];
    logic signed [19:0] e1 [0:1];
    logic signed [19:0] i_pred [0:2];
    logic signed [19:0] rp [0:1];
    logic signed [20:0] u [0:2];
    logic signed [20:0] x [0:2];
    logic signed [20:0] off;
    logic signed [12:0] raw_n [0:2];

    // DC-link loop
    logic [19:0] vdc_sum;
    logic [CNT_W-1:0] vdc_cnt;
    logic avg_ok;
    logic signed [31:0] dc_integ;

    logic [IDX_W-1:0] wr_idx, rd_idx;
    logic [CNT_W-1:0] fill;
    logic hist_we;
    // Reference history: one grid cycle of {ref_a, ref_b} (block RAM, no reset).
    logic [35:0] hist [0:WINDOW-1];
    logic [35:0] hist_q;
    always_ff @(posedge clk) begin
        if (hist_we) hist[wr_idx] <= {ref_a_q, ref_b_q};
        hist_q <= hist[rd_idx];
    end

    function automatic logic [11:0] clamp_duty(input logic signed [21:0] v);
        if (v < 0) return '0;
        if (v > HALF_TICKS) return 12'(HALF_TICKS);
        return v[11:0];
    endfunction

    function automatic logic signed [20:0] max3(input logic signed [20:0] a, b, c);
        logic signed [20:0] m;
        m = (a > b) ? a : b;
        return (m > c) ? m : c;
    endfunction

    function automatic logic signed [20:0] min3(input logic signed [20:0] a, b, c);
        logic signed [20:0] m;
        m = (a < b) ? a : b;
        return (m < c) ? m : c;
    endfunction

    always_comb begin
        div_shift = {div_rem, div_num[35]};
        // (wr_idx + PRED_LEAD) mod WINDOW, without a divider (PRED_LEAD < WINDOW).
        if (32'(wr_idx) + PRED_LEAD >= WINDOW)
            rd_idx = IDX_W'(32'(wr_idx) + PRED_LEAD - WINDOW);
        else
            rd_idx = IDX_W'(32'(wr_idx) + PRED_LEAD);
        hist_we = (state == FINISH) && ref_ok_q;
        ready_to_run = (fill == WINDOW) && avg_ok;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            for (int p = 0; p < 2; p++) begin
                vg_q[p] <= '0; vg_prev[p] <= '0; if_q[p] <= '0; cos_q[p] <= '0;
                dsum[p] <= '0; vd_prod[p] <= '0; u_prev[p] <= '0; dv[p] <= '0;
                e1[p] <= '0; rp[p] <= '0;
            end
            for (int p = 0; p < 3; p++) begin
                raw[p] <= 12'(HALF_TICKS / 2); i_pred[p] <= '0; u[p] <= '0; x[p] <= '0; raw_n[p] <= '0;
            end
            ref_a_q <= '0; ref_b_q <= '0; vdc_q <= '0;
            run_q <= 1'b0; ref_ok_q <= 1'b0; fresh <= 1'b1;
            vdc16 <= '0; div_num <= '0; div_rem <= '0; scale <= '0; step <= '0;
            off <= '0;
            wr_idx <= '0; fill <= '0;
            vdc_sum <= '0; vdc_cnt <= '0; avg_ok <= 1'b0; vdc_avg <= '0;
            vdc_target <= '0; dc_integ <= '0; idc_cmd <= '0;
            duty_valid <= 1'b0;
            duty_a <= 16'(HALF_TICKS / 2); duty_b <= 16'(HALF_TICKS / 2); duty_c <= 16'(HALF_TICKS / 2);
        end else begin
            duty_valid <= 1'b0;
            case (state)
                IDLE: if (go) begin
                    vg_q[0] <= vg_a; vg_q[1] <= vg_b;
                    if_q[0] <= if_a; if_q[1] <= if_b;
                    ref_a_q <= ref_a; ref_b_q <= ref_b;
                    cos_q[0] <= cos_next_a; cos_q[1] <= cos_next_b;
                    vdc_q <= vdc;
                    run_q <= run && (fill == WINDOW) && ref_ok && avg_ok;
                    ref_ok_q <= ref_ok;
                    // vdc in 16 counts/V: vdc * 1.6
                    vdc16 <= 13'((26'(vdc) * 26'd13107) >> 13);   // 4095 * 13107 needs 26 bits
                    step <= '0;
                    state <= DIVIDE;
                end
                DIVIDE: begin
                    if (step == 0) begin
                        div_num <= SCALE_NUM;
                        div_rem <= '0;
                        if (vdc16 < VDC16_MIN) vdc16 <= 13'(VDC16_MIN);
                    end else begin
                        if (div_shift >= {15'd0, vdc16}) begin
                            div_rem <= 27'(div_shift - {15'd0, vdc16});
                            scale <= {scale[24:0], 1'b1};
                        end else begin
                            div_rem <= div_shift[26:0];
                            scale <= {scale[24:0], 1'b0};
                        end
                        div_num <= {div_num[34:0], 1'b0};
                    end
                    if (step == 6'd36) state <= UPREV1;
                    step <= step + 1'b1;
                end
                UPREV1: begin
                    // Differential voltage applied over [k, k+1]: Vdc * (3 d_p - sum d) / (3 * HALF_TICKS)
                    dsum[0] <= 15'({raw[0], 1'b0}) - 15'(raw[1]) - 15'(raw[2]);
                    dsum[1] <= 15'({raw[1], 1'b0}) - 15'(raw[0]) - 15'(raw[2]);
                    dv[0] <= 14'(vg_q[0]) - 14'(vg_prev[0]);
                    dv[1] <= 14'(vg_q[1]) - 14'(vg_prev[1]);
                    state <= UPREV2;
                end
                UPREV2: begin
                    vd_prod[0] <= $signed({1'b0, vdc16}) * dsum[0];
                    vd_prod[1] <= $signed({1'b0, vdc16}) * dsum[1];
                    state <= PREDICT1;
                end
                PREDICT1: begin
                    for (int p = 0; p < 2; p++) begin
                        u_prev[p] <= 20'((44'(vd_prod[p]) * 44'($signed({1'b0, RECIP_7500_SCALED}))) >>> 24);
                    end
                    state <= PREDICT2;
                end
                PREDICT2: begin
                    // Grid voltage averaged over [k, k+1] ~ vg + dv/2.
                    for (int p = 0; p < 2; p++)
                        e1[p] <= 20'(u_prev[p]) - 20'(vg_q[p]) - 20'(dv[p] >>> 1);
                    state <= REFER;
                end
                REFER: begin
                    for (int p = 0; p < 2; p++) begin
                        if (fresh)   // inverter was not switching over [k, k+1]
                            i_pred[p] <= 20'(if_q[p]);
                        else
                            i_pred[p] <= 20'(if_q[p]) + 20'((40'(e1[p]) * 40'(K_PRED)) >>> 12);
                    end
                    rp[0] <= 20'($signed(hist_q[35:18])) - 20'((36'(idc_cmd) * 36'(cos_q[0])) >>> 16);
                    rp[1] <= 20'($signed(hist_q[17:0]))  - 20'((36'(idc_cmd) * 36'(cos_q[1])) >>> 16);
                    state <= CONTROL1;
                end
                CONTROL1: begin
                    i_pred[2] <= -(i_pred[0] + i_pred[1]);
                    for (int p = 0; p < 2; p++)
                        u[p] <= 21'(vg_q[p]) + 21'((21'(dv[p]) * 3) >>> 1) +
                                21'((41'(rp[p] - i_pred[p]) * 41'(K_CTRL)) >>> 12);
                    state <= CONTROL2;
                end
                CONTROL2: begin
                    u[2] <= -(u[0] + u[1]);
                    state <= OFFSET;
                end
                OFFSET: begin
                    off <= -((max3(u[0], u[1], u[2]) + min3(u[0], u[1], u[2])) >>> 1);
                    state <= DUTY1;
                end
                DUTY1: begin
                    for (int p = 0; p < 3; p++) x[p] <= u[p] + off;
                    state <= DUTY2;
                end
                DUTY2: begin
                    for (int p = 0; p < 3; p++)
                        raw_n[p] <= 13'(clamp_duty(22'(HALF_TICKS / 2) +
                                     22'((48'(x[p]) * 48'($signed({1'b0, scale}))) >>> 24)));
                    state <= FINISH;
                end
                FINISH: begin
                    for (int p = 0; p < 2; p++) vg_prev[p] <= vg_q[p];
                    if (run_q) begin
                        for (int p = 0; p < 3; p++) raw[p] <= raw_n[p][11:0];
                        duty_a <= 16'(clamp_duty(22'(raw_n[0]) + (i_pred[0] > 0 ? DT_POS : DT_NEG)));
                        duty_b <= 16'(clamp_duty(22'(raw_n[1]) + (i_pred[1] > 0 ? DT_POS : DT_NEG)));
                        duty_c <= 16'(clamp_duty(22'(raw_n[2]) + (i_pred[2] > 0 ? DT_POS : DT_NEG)));
                        duty_valid <= 1'b1;
                        fresh <= 1'b0;
                    end else begin
                        for (int p = 0; p < 3; p++) raw[p] <= 12'(HALF_TICKS / 2);
                        fresh <= 1'b1;
                    end
                    // Store this frame's reference; drop the history if it is broken.
                    if (ref_ok_q) begin
                        wr_idx <= (wr_idx == WINDOW - 1) ? '0 : wr_idx + 1'b1;
                        if (fill != WINDOW) fill <= fill + 1'b1;
                    end else begin
                        wr_idx <= '0;
                        fill <= '0;
                    end
                    // DC-link average over one grid cycle.
                    if (vdc_cnt == WINDOW - 1) begin
                        vdc_avg <= 12'((46'(vdc_sum + vdc_q) * 46'(RECIP_WINDOW)) >> 24);
                        vdc_sum <= '0;
                        vdc_cnt <= '0;
                        avg_ok <= 1'b1;
                        state <= DC_LOOP;
                    end else begin
                        vdc_sum <= vdc_sum + vdc_q;
                        vdc_cnt <= vdc_cnt + 1'b1;
                        state <= IDLE;
                    end
                end
                DC_LOOP: begin
                    // Once per grid cycle: ramp the target, then PI on the cycle average.
                    if (!run_q) begin
                        vdc_target <= vdc_avg;
                        dc_integ <= '0;
                        idc_cmd <= '0;
                    end else begin
                        logic [11:0] tgt;
                        logic signed [13:0] err;
                        logic signed [31:0] acc;
                        logic signed [31:0] cmd;
                        tgt = (vdc_target + VDC_RAMP >= VDC_REF) ? 12'(VDC_REF) : 12'(vdc_target + VDC_RAMP);
                        err = $signed({2'b0, tgt}) - $signed({2'b0, vdc_avg});
                        acc = dc_integ + 32'(err) * KI_DC;
                        if (acc > ACC_MAX) acc = ACC_MAX;
                        else if (acc < -ACC_MAX) acc = -ACC_MAX;
                        cmd = 32'(err) * KP_DC + (acc >>> 8);
                        if (cmd > IDC_MAX) cmd = IDC_MAX;
                        else if (cmd < -IDC_MAX) cmd = -IDC_MAX;
                        vdc_target <= tgt;
                        dc_integ <= acc;
                        idc_cmd <= 16'(cmd);
                    end
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
