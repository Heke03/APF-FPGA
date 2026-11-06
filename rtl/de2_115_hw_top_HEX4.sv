`timescale 1ns/1ps
// HEX4: the DE2-115 top level for REAL hardware: apf_core reads the sensors through an
// AD7606 on the 40-pin header and drives a real inverter through gate_guard_HEX4. It
// is a separate design: de2_115_top_H3 (the virtual power stage) is not changed.
//
// NOT YET CONNECTED TO ANY HARDWARE. The power-stage values and the sensor choice are
// still placeholders until the team decides. See docs/HEX4_progress.md before wiring it.
//
//   KEY0        reset (hold); also a reset at power-up
//   KEY1        new waveform recording (flipping SW0..SW2 triggers it)
//   SW17        arm the power stage. Down: all gates off, whatever else happens
//   SW0         run: arm first, then flip this up. After any trip: SW17 down, SW17 up, flip SW0 again
//   SW1, SW2    no function except to trigger a recording
//   SW4..SW3    right display: 00 THD of grid current a, %     01 PLL frequency, Hz
//                              10 peak grid current a, A       11 trip cause (see LEDR9..4)
//   HEX7..HEX4  DC-link voltage, V              HEX3..HEX0  the reading above
//   LEDG0..3    PLL locked, ready, switching, armed
//   LEDG7       the ADC is running               LEDG8  a recording is ready to read
//   LEDR17..12  gates A high, A low, B high, B low, C high, C low
//   LEDR11      gate drivers OK                  LEDR10  ADC fault
//   LEDR9..4    trip cause (gate_guard_HEX4)     LEDR3..0 faults: PLL lost, over-voltage, over-current, measurement
module de2_115_hw_top_HEX4 #(
    parameter         COS_FILE       = "cos_table_4096.hex",
    parameter         THD_TABLE_FILE = "thd_table_200.hex",
    parameter integer RESET_CLKS     = 1_000_000,    // reset lasts 20 ms after KEY0 / power-up
    parameter integer DEBOUNCE_CLKS  = 500_000,      // a switch must be steady 10 ms
    parameter integer REFRESH        = 10_000_000,   // displays updated every 0.2 s
    parameter integer CAP_LOG2       = 14            // recording: 2^14 samples = 1.64 s
) (
    input  logic        CLOCK_50,
    input  logic [3:0]  KEY,                         // pressed = 0
    input  logic [17:0] SW,
    output logic [8:0]  LEDG,
    output logic [17:0] LEDR,
    output logic [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7,
    // AD7606 on the 40-pin header (pin map: quartus/de2_115_hw_pins_HEX4.tcl)
    input  logic [15:0] ADC_DB,
    input  logic        ADC_BUSY,
    input  logic        ADC_FRSTDATA,
    output logic        ADC_CONVST,                  // to CONVST A and CONVST B
    output logic        ADC_RD_N,
    output logic        ADC_CS_N,
    output logic        ADC_RESET,
    output logic        ADC_RANGE,                   // 1: +-10 V
    output logic [2:0]  ADC_OS,                      // 000: no oversampling
    // gate drivers
    output logic        GATE_EN_N,                   // high: buffer disabled (also while the FPGA loads)
    output logic        GATE_A_HI, GATE_A_LO, GATE_B_HI, GATE_B_LO, GATE_C_HI, GATE_C_LO,
    input  logic        DRIVERS_OK,                  // high: all gate drivers are fine
    output logic        CONTACTOR
);
    wire clk = CLOCK_50;
    assign ADC_RANGE = 1'b1;
    assign ADC_OS = 3'b000;

    // ---- reset: KEY0, and at power-up (registers start at 0 after configuration) ----
    logic [1:0] key_sync = 2'b00;
    logic [$clog2(RESET_CLKS+1)-1:0] rst_cnt = '0;
    logic rst_n = 1'b0;
    always @(posedge clk) begin                      // always, not always_ff: the variables have power-up values
        key_sync <= {key_sync[0], KEY[0]};
        if (!key_sync[1]) rst_cnt <= '0;
        else if (rst_cnt != RESET_CLKS) rst_cnt <= rst_cnt + 1'b1;
        rst_n <= (rst_cnt == RESET_CLKS);
    end

    // ---- switches and KEY1: synchronize, then accept a change once steady ----
    localparam integer NSW = 7;                      // SW0..SW4, bit 5 = KEY1 pressed, bit 6 = SW17
    logic [NSW-1:0] sw_s1, sw_s2, sw, sw_prev;
    logic [$clog2(DEBOUNCE_CLKS+1)-1:0] db_cnt [NSW];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sw_s1 <= '0; sw_s2 <= '0; sw <= '0; sw_prev <= '0;
            for (int i = 0; i < NSW; i++) db_cnt[i] <= '0;
        end else begin
            sw_s1 <= {SW[17], ~KEY[1], SW[4:0]}; sw_s2 <= sw_s1; sw_prev <= sw;
            for (int i = 0; i < NSW; i++)
                if (sw_s2[i] == sw[i]) db_cnt[i] <= '0;
                else if (db_cnt[i] == DEBOUNCE_CLKS) begin sw[i] <= sw_s2[i]; db_cnt[i] <= '0; end
                else db_cnt[i] <= db_cnt[i] + 1'b1;
        end
    end
    wire arm_sw = sw[6];

    // ---- gate driver status: synchronized, and it must stay low 4 clocks (80 ns) to count ----
    logic [1:0] ok_s;
    logic [2:0] ok_low;
    logic drivers_ok;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ok_s <= '0; ok_low <= '0; drivers_ok <= 1'b0;
        end else begin
            ok_s <= {ok_s[0], DRIVERS_OK};
            if (ok_s[1]) begin ok_low <= '0; drivers_ok <= 1'b1; end
            else if (ok_low == 3'd3) drivers_ok <= 1'b0;
            else ok_low <= ok_low + 1'b1;
        end
    end

    // ---- ADC -> 12-bit codes -> apf_core -> gate guard ----
    logic adc_start, raw_valid, adc_ready, code_valid;
    logic signed [15:0] raw [0:7];
    logic [11:0] code [0:6];
    logic [3:0] adc_fault;
    logic [2:0] core_hi, core_lo, hi_out, lo_out;
    logic switching, pll_locked, compensating_ready;
    logic [3:0] fault_flags;
    logic [31:0] freq_word;
    logic [11:0] vdc_avg;
    logic signed [15:0] idc_cmd;
    logic tripped, guard_running;
    logic [5:0] cause;

    // run: only a flip of SW0 made while armed starts the inverter, and any trip ends it
    logic run_enable;
    logic [3:0] fault_seen;       // apf_core clears its faults when it stops: keep them for the LEDs until disarmed
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run_enable <= 1'b0; fault_seen <= '0;
        end else begin
            if (!sw[0] || !arm_sw || tripped) run_enable <= 1'b0;
            else if (sw[0] && !sw_prev[0] && guard_running) run_enable <= 1'b1;
            if (!arm_sw) fault_seen <= fault_flags;
            else fault_seen <= fault_seen | fault_flags;
        end
    end

    ad7606_if_HEX4 adc (
        .clk, .rst_n, .start(adc_start), .clear_faults(!arm_sw),
        .ad_reset(ADC_RESET), .ad_convst(ADC_CONVST), .ad_cs_n(ADC_CS_N), .ad_rd_n(ADC_RD_N),
        .ad_busy(ADC_BUSY), .ad_frstdata(ADC_FRSTDATA), .ad_db(ADC_DB),
        .raw, .raw_valid, .ready(adc_ready), .fault(adc_fault)
    );
    adc_scale_HEX4 scale (.clk, .rst_n, .raw, .raw_valid, .code, .code_valid);

    apf_core #(.COS_FILE(COS_FILE)) core (
        .clk, .rst_n, .run_request(run_enable), .adc_valid(code_valid), .adc_code(code), .adc_start,
        .gate_hi(core_hi), .gate_lo(core_lo), .switching, .pll_locked, .compensating_ready,
        .fault_flags, .freq_word, .vdc_avg, .idc_cmd
    );

    gate_guard_HEX4 guard (
        .clk, .rst_n, .arm(arm_sw), .drivers_ok, .adc_fault(adc_fault != 0), .core_fault(fault_flags != 0),
        .core_switching(switching), .frame_tick(code_valid), .hi_in(core_hi), .lo_in(core_lo),
        .hi_out, .lo_out, .gate_en_n(GATE_EN_N), .contactor(CONTACTOR), .tripped, .cause, .running(guard_running)
    );
    assign {GATE_C_HI, GATE_B_HI, GATE_A_HI} = hi_out;
    assign {GATE_C_LO, GATE_B_LO, GATE_A_LO} = lo_out;

    // ---- what the sensors read, in the units the display and the recorder use ----
    wire signed [12:0] vg_c = $signed({1'b0, code[0]}) - 13'sd2048;
    wire signed [12:0] il_c = $signed({1'b0, code[2]}) - 13'sd2048;
    wire signed [12:0] if_c = $signed({1'b0, code[4]}) - 13'sd2048;
    wire signed [13:0] ig_c = 14'(il_c) - 14'(if_c);                 // grid current a, 100 counts/A

    logic [13:0] thd;
    logic thd_valid, thd_done;
    logic [9:0] thd_window_pos;
    thd_meter_H3 #(.TABLE_FILE(THD_TABLE_FILE)) meter (
        .clk, .rst_n, .sample_en(code_valid), .sample(32'(ig_c) * 32'sd167772),   // 2^-24 A
        .thd, .thd_valid, .reading_done(thd_done), .window_pos(thd_window_pos)
    );
    logic [13:0] peak_run, peak_counts;
    wire [13:0] ig_abs = ig_c[13] ? 14'(-ig_c) : 14'(ig_c);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin peak_run <= '0; peak_counts <= '0; end
        else if (thd_done) begin peak_counts <= peak_run; peak_run <= '0; end
        else if (code_valid && ig_abs > peak_run) peak_run <= ig_abs;
    end

    // ---- waveform recording, same recorder and same PC script as the H3 board design ----
    function automatic logic [15:0] sat16(input logic signed [34:0] x);          // round, >>> 16, 16 bit
        logic signed [34:0] y;
        y = (x + 35'sd32768) >>> 16;
        return (y > 32767) ? 16'h7FFF : (y < -32768) ? 16'h8000 : 16'(y);
    endfunction
    logic cap_we, cap_ready;
    logic [15:0] cap_ig, cap_il, cap_ii, cap_vd, cap_vg;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cap_we <= 1'b0; cap_ig <= '0; cap_il <= '0; cap_ii <= '0; cap_vd <= '0; cap_vg <= '0;
        end else begin
            cap_we <= code_valid;
            cap_ig <= sat16(35'(ig_c) * 35'sd671089);                    // counts * 10.24 -> 2^-10 A
            cap_il <= sat16(35'(il_c) * 35'sd671089);
            cap_ii <= sat16(35'(if_c) * 35'sd671089);
            cap_vd <= sat16(35'($signed({1'b0, code[6]})) * 35'sd419430);    // counts * 6.4 -> 2^-6 V
            cap_vg <= 16'(vg_c) <<< 3;                                   // counts * 8 -> 2^-7 V
        end
    end
    capture_H3 #(.DEPTH_LOG2(CAP_LOG2)) cap (
        .clk, .rst_n, .sample_en(cap_we), .ig(cap_ig), .il(cap_il), .ii(cap_ii), .vd(cap_vd), .vg(cap_vg),
        .trig(sw[2:0] != sw_prev[2:0]), .sw_before(sw_prev[2:0]), .sw_after(sw[2:0]),
        .arm(sw[5] && !sw_prev[5]), .meter_pos(thd_window_pos), .ready(cap_ready)
    );

    // ---- the right display's reading ----
    logic        have_thd;
    logic [45:0] f_prod;
    logic [13:0] f_centi, value;
    logic [1:0]  fmt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            have_thd <= 1'b0; f_prod <= '0; f_centi <= '0; value <= '0; fmt <= 2'd0;
        end else begin
            if (thd_done) have_thd <= 1'b1;
            f_prod <= 46'(freq_word) * 46'd15625 + (46'd1 << 25);    // 0.01 Hz, as in the H3 design
            f_centi <= (f_prod[45:26] > 9999) ? 14'd9999 : 14'(f_prod[45:26]);
            case (sw[4:3])
                2'b00: begin value <= thd; fmt <= (have_thd && thd_valid) ? 2'd1 : 2'd0; end
                2'b01: begin value <= f_centi; fmt <= 2'd1; end
                2'b10: begin value <= peak_counts; fmt <= have_thd ? 2'd1 : 2'd0; end   // 100 counts/A = 0.01 A
                2'b11: begin value <= 14'(cause); fmt <= 2'd2; end
            endcase
        end
    end
    logic [6:0] hex [0:7];
    display_H3 #(.REFRESH(REFRESH)) disp (.clk, .rst_n, .vdc_avg, .value, .fmt, .hex);
    assign {HEX7, HEX6, HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} =
           {hex[7], hex[6], hex[5], hex[4], hex[3], hex[2], hex[1], hex[0]};

    // ---- LEDs ----
    assign LEDG = {cap_ready, adc_ready && adc_fault == 0, 3'b0, guard_running, switching, compensating_ready, pll_locked};
    assign LEDR = {hi_out[0], lo_out[0], hi_out[1], lo_out[1], hi_out[2], lo_out[2],
                   drivers_ok, adc_fault != 0, cause, fault_seen};
endmodule
