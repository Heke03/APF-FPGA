// APF control core: ADC frame in, six gate signals out.
//
//   ADC frame (7 channels) -> scaling + range check -> srf_pll + apf_reference
//   -> current_controller -> three_phase_pwm -> gates
//
// Channels (12-bit codes, sampled together at pwm frame_start):
//   0 vg_a, 1 vg_b   grid phase voltage, 16 counts/V, zero at OFFSET_V
//   2 il_a, 3 il_b   load current,       100 counts/A, zero at OFFSET_I
//   4 if_a, 5 if_b   inverter current,   100 counts/A, zero at OFFSET_I
//   6 vdc            DC link,            10 counts/V,  zero at 0
// Phase c is -(a + b) everywhere (three-wire system, no neutral).
//
// Sequencing: switching starts only when run_request is high, the PLL is
// locked, the reference and its one-cycle history are ready, and there is no
// fault. Any fault latches, stops switching (and in the system testbench opens
// the inverter contactor), and is cleared by dropping run_request.
module apf_core #(
    parameter integer CLK_HZ      = 50_000_000,
    parameter integer PWM_HZ      = 10_000,
    parameter integer DEAD_CYCLES = 100,
    parameter integer OFFSET_V    = 2048,
    parameter integer OFFSET_I    = 2048,
    parameter integer CODE_MIN    = 16,
    parameter integer CODE_MAX    = 4079,
    parameter integer OC_LIMIT    = 1500,   // inverter current trip, counts (15 A)
    parameter integer OV_LIMIT    = 3800,   // DC-link trip, counts (380 V)
    parameter         COS_FILE    = "cos_table_4096.hex"
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        run_request,
    input  logic        adc_valid,         // one pulse per frame; codes stable while high
    input  logic [11:0] adc_code [0:6],
    output logic        adc_start,         // start conversions (PWM carrier boundary)
    output logic [2:0]  gate_hi,
    output logic [2:0]  gate_lo,
    output logic        switching,         // gates are being driven
    output logic        pll_locked,
    output logic        compensating_ready,
    output logic [3:0]  fault_flags,       // {pll_lost, over_voltage, over_current, measurement}
    output logic [31:0] freq_word,
    output logic [11:0] vdc_avg,
    output logic signed [15:0] idc_cmd
);
    localparam integer HALF_TICKS = CLK_HZ / (2 * PWM_HZ);
    localparam logic signed [15:0] OC_POS = 16'(OC_LIMIT * 8);
    localparam logic signed [15:0] OC_NEG = 16'(-OC_LIMIT * 8);

    // ---------------- measurement scaling ----------------
    logic signed [12:0] vg_a, vg_b, vg_c;
    logic signed [15:0] il_a, il_b, il_c, if_a, if_b, if_c;
    logic [11:0] vdc;
    logic frame, range_bad, meas_fault_now;

    function automatic logic signed [12:0] centered(input logic [11:0] code, input integer offset);
        return $signed({1'b0, code}) - 13'(offset);
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vg_a <= '0; vg_b <= '0; vg_c <= '0;
            il_a <= '0; il_b <= '0; il_c <= '0;
            if_a <= '0; if_b <= '0; if_c <= '0;
            vdc <= '0; frame <= 1'b0; range_bad <= 1'b1;
        end else begin
            frame <= adc_valid;
            if (adc_valid) begin
                logic bad;
                bad = 1'b0;
                for (int ch = 0; ch < 6; ch++)
                    if (adc_code[ch] < CODE_MIN || adc_code[ch] > CODE_MAX) bad = 1'b1;
                range_bad <= bad;
                vg_a <= centered(adc_code[0], OFFSET_V);
                vg_b <= centered(adc_code[1], OFFSET_V);
                vg_c <= -(centered(adc_code[0], OFFSET_V) + centered(adc_code[1], OFFSET_V));
                // Currents are carried as counts * 8 for extra resolution in the reference math.
                il_a <= 16'(centered(adc_code[2], OFFSET_I)) <<< 3;
                il_b <= 16'(centered(adc_code[3], OFFSET_I)) <<< 3;
                il_c <= -((16'(centered(adc_code[2], OFFSET_I)) + 16'(centered(adc_code[3], OFFSET_I))) <<< 3);
                if_a <= 16'(centered(adc_code[4], OFFSET_I)) <<< 3;
                if_b <= 16'(centered(adc_code[5], OFFSET_I)) <<< 3;
                if_c <= -((16'(centered(adc_code[4], OFFSET_I)) + 16'(centered(adc_code[5], OFFSET_I))) <<< 3);
                vdc <= adc_code[6];
            end
        end
    end

    // ---------------- PLL ----------------
    logic pll_ready, pll_done, pll_overrun, pll_low;
    logic signed [17:0] pll_err;
    logic [25:0] pll_amp;
    logic [31:0] theta;
    logic signed [17:0] cos_a, cos_b, cos_c, sin_a, sin_b, sin_c;

    srf_pll #(.COS_FILE(COS_FILE)) pll (
        .clk, .rst_n,
        .sample_valid(frame), .sample_ok(!range_bad),
        .v_a(16'(vg_a)), .v_b(16'(vg_b)), .v_c(16'(vg_c)),
        .ready(pll_ready), .result_valid(pll_done), .overrun(pll_overrun),
        .angle_valid(pll_locked), .low_amplitude(pll_low),
        .phase_error(pll_err), .amplitude(pll_amp), .freq_word, .theta,
        .cos_a, .cos_b, .cos_c, .sin_a, .sin_b, .sin_c
    );

    // ---------------- reference ----------------
    logic ref_ready_for_frame, ref_done, ref_ready, ref_input_error;
    logic signed [17:0] mean_d, src_a, src_b, src_c, ref_a, ref_b, ref_c;

    apf_reference #(.WINDOW(200)) reference (
        .clk, .rst_n,
        .frame_valid(frame && pll_locked), .invalidate(range_bad && frame),
        .angle_valid(pll_locked),
        .load_a(il_a), .load_b(il_b), .load_c(il_c),
        .cos_a, .cos_b, .cos_c,
        .ready_for_frame(ref_ready_for_frame), .result_valid(ref_done),
        .reference_ready(ref_ready), .input_error(ref_input_error),
        .mean_d, .source_a(src_a), .source_b(src_b), .source_c(src_c),
        .reference_a(ref_a), .reference_b(ref_b), .reference_c(ref_c)
    );

    // ---------------- current + DC-link control ----------------
    logic run_ctrl, ctrl_ready, duty_valid;
    logic [15:0] duty_a, duty_b, duty_c;
    logic [11:0] vdc_target;

    current_controller #(.HALF_TICKS(HALF_TICKS)) ctrl (
        .clk, .rst_n,
        .go(pll_done), .run(run_ctrl),
        .vg_a, .vg_b, .if_a, .if_b, .vdc,
        .ref_ok(ref_ready && pll_locked), .ref_a, .ref_b,
        .cos_next_a(cos_a), .cos_next_b(cos_b),
        .ready_to_run(ctrl_ready), .duty_valid,
        .duty_a, .duty_b, .duty_c,
        .idc_cmd, .vdc_avg, .vdc_target
    );

    // ---------------- protection and sequencing ----------------
    logic [3:0] fault_now;
    logic fault_any, pwm_enable, pwm_fault, first_duty, fault_ack, frame_start;

    function automatic logic over(input logic signed [15:0] i8);
        return (i8 > OC_POS) || (i8 < OC_NEG);
    endfunction

    always_comb begin
        fault_now[0] = frame && range_bad;
        fault_now[1] = frame && (over(if_a) || over(if_b) || over(if_c));
        fault_now[2] = frame && (vdc > OV_LIMIT);
        fault_now[3] = run_ctrl && !pll_locked;
        compensating_ready = pll_locked && ctrl_ready;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fault_flags <= '0;
            run_ctrl <= 1'b0;
            first_duty <= 1'b0;
            pwm_enable <= 1'b0;
            fault_ack <= 1'b0;
        end else begin
            fault_ack <= 1'b0;
            if (!run_request) begin
                // Dropping the request stops switching and clears latched faults.
                run_ctrl <= 1'b0;
                first_duty <= 1'b0;
                pwm_enable <= 1'b0;
                if (fault_flags != 0 || pwm_fault) fault_ack <= 1'b1;
                fault_flags <= '0;
            end else if (fault_flags != 0 || fault_now != 0) begin
                fault_flags <= fault_flags | fault_now;
                run_ctrl <= 1'b0;
                first_duty <= 1'b0;
                pwm_enable <= 1'b0;
            end else begin
                if (!run_ctrl && compensating_ready && pll_done)
                    run_ctrl <= 1'b1;
                if (run_ctrl && duty_valid)
                    first_duty <= 1'b1;
                // Gates start on the carrier boundary that loads the first real duty.
                if (first_duty && frame_start)
                    pwm_enable <= 1'b1;
            end
        end
    end

    assign fault_any = (fault_flags != 0) || (fault_now != 0);

    three_phase_pwm #(.CLK_HZ(CLK_HZ), .PWM_HZ(PWM_HZ), .DEAD_CYCLES(DEAD_CYCLES)) pwm (
        .clk, .rst_n,
        .enable(pwm_enable), .fault_active(fault_any), .fault_ack(fault_ack || (!run_request && !pwm_enable)),
        .duty_valid(duty_valid && run_ctrl), .duty_a, .duty_b, .duty_c,
        .gate_hi, .gate_lo, .fault_latched(pwm_fault), .frame_start
    );

    assign adc_start = frame_start;
    assign switching = pwm_enable && !pwm_fault;
endmodule
