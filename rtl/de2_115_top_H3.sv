`timescale 1ns/1ps
// H3: DE2-115 top level of the stand-alone demo. The APF controller runs in
// closed loop with the virtual power stage inside the FPGA (apf_vps_system_H3);
// this level only connects it to the board's buttons, switches, LEDs and displays.
// Port names as in Terasic's DE2-115 pin list; nothing else on the board is driven.
//
//   KEY0        reset (hold); also a reset at power-up
//   SW0         run: filter on / off          SW1  load 33 / 22 ohm
//   SW2         ADC noise on / off            SW4..SW3  right display:
//                 00 THD of grid current a, %   ("4_40" = 4.40 %, "----" = no reading yet)
//                 01 PLL frequency, Hz          ("50_0")
//                 10 peak grid current a, A, over the same 0.1 s as the THD
//                 11 shoot-through count        (always 0)
//   HEX7..HEX4  DC-link voltage, V              HEX3..HEX0  the reading above
//   LEDG0..3    PLL locked, ready, switching, 22 ohm load
//   LEDR17..12  gates A high, A low, B high, B low, C high, C low (glow while switching)
//   LEDR3..0    faults: PLL lost, over-voltage, over-current, measurement
module de2_115_top_H3 #(
    parameter         COS_FILE       = "cos_table_4096.hex",
    parameter         THD_TABLE_FILE = "thd_table_200.hex",
    parameter integer RESET_CLKS     = 1_000_000,    // reset lasts 20 ms after KEY0 / power-up
    parameter integer DEBOUNCE_CLKS  = 500_000,      // a switch must be steady 10 ms
    parameter integer REFRESH        = 10_000_000    // displays updated every 0.2 s
) (
    input  logic        CLOCK_50,
    input  logic [3:0]  KEY,                         // pressed = 0
    input  logic [17:0] SW,
    output logic [8:0]  LEDG,
    output logic [17:0] LEDR,
    output logic [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7
);
    wire clk = CLOCK_50;

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

    // ---- switches: synchronize, then accept a change once steady ----
    localparam integer NSW = 5;
    logic [NSW-1:0] sw_s1, sw_s2, sw;
    logic [$clog2(DEBOUNCE_CLKS+1)-1:0] db_cnt [NSW];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sw_s1 <= '0; sw_s2 <= '0; sw <= '0;
            for (int i = 0; i < NSW; i++) db_cnt[i] <= '0;
        end else begin
            sw_s1 <= SW[NSW-1:0]; sw_s2 <= sw_s1;
            for (int i = 0; i < NSW; i++)
                if (sw_s2[i] == sw[i]) db_cnt[i] <= '0;
                else if (db_cnt[i] == DEBOUNCE_CLKS) begin sw[i] <= sw_s2[i]; db_cnt[i] <= '0; end
                else db_cnt[i] <= db_cnt[i] + 1'b1;
        end
    end

    // ---- the APF and its virtual power stage ----
    logic [2:0]  gate_hi, gate_lo;
    logic        switching, pll_locked, compensating_ready;
    logic [3:0]  fault_flags;
    logic [31:0] freq_word, shoot_count;
    logic [11:0] vdc_avg;
    logic signed [15:0] idc_cmd;
    logic signed [23:0] vg_a;
    logic signed [31:0] i_load_a, i_inv_a;
    logic signed [41:0] vdc;
    logic [13:0] thd;
    logic        thd_valid, thd_done;
    logic [32:0] i_grid_peak;

    apf_vps_system_H3 #(.COS_FILE(COS_FILE), .THD_TABLE_FILE(THD_TABLE_FILE)) sys (
        .clk, .rst_n, .run_request(sw[0]), .load_step(sw[1]), .noise_en(sw[2]),
        .gate_hi, .gate_lo, .switching, .pll_locked, .compensating_ready, .fault_flags,
        .freq_word, .vdc_avg, .idc_cmd, .vg_a, .i_load_a, .i_inv_a, .vdc, .shoot_count,
        .thd, .thd_valid, .thd_done, .i_grid_peak
    );

    // ---- the right display's reading ----
    logic        have_thd;                       // a first reading exists
    logic [45:0] f_prod;
    logic [39:0] i_prod;
    logic [13:0] f_centi, i_centi, value;
    logic [1:0]  fmt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            have_thd <= 1'b0; f_prod <= '0; i_prod <= '0; f_centi <= '0; i_centi <= '0;
            value <= '0; fmt <= 2'd0;
        end else begin
            if (thd_done) have_thd <= 1'b1;
            // f = freq_word * 10 kHz / 2^32 -> 0.01 Hz: freq_word * 15625 / 2^26, rounded
            f_prod <= 46'(freq_word) * 46'd15625 + (46'd1 << 25);
            f_centi <= (f_prod[45:26] > 9999) ? 14'd9999 : 14'(f_prod[45:26]);
            // 2^-24 A -> 0.01 A, rounded
            i_prod <= 40'(i_grid_peak) * 40'd100 + (40'd1 << 23);
            i_centi <= (i_prod[39:24] > 9999) ? 14'd9999 : 14'(i_prod[39:24]);
            case (sw[4:3])
                2'b00: begin value <= thd; fmt <= (have_thd && thd_valid) ? 2'd1 : 2'd0; end
                2'b01: begin value <= f_centi; fmt <= 2'd1; end
                2'b10: begin value <= i_centi; fmt <= have_thd ? 2'd1 : 2'd0; end
                2'b11: begin value <= (shoot_count > 9999) ? 14'd9999 : 14'(shoot_count); fmt <= 2'd2; end
            endcase
        end
    end

    logic [6:0] hex [0:7];
    display_H3 #(.REFRESH(REFRESH)) disp (.clk, .rst_n, .vdc_avg, .value, .fmt, .hex);
    assign {HEX7, HEX6, HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} =
           {hex[7], hex[6], hex[5], hex[4], hex[3], hex[2], hex[1], hex[0]};

    // ---- LEDs ----
    assign LEDG = {5'b0, sw[1], switching, compensating_ready, pll_locked};
    assign LEDR = {gate_hi[0], gate_lo[0], gate_hi[1], gate_lo[1], gate_hi[2], gate_lo[2],
                   8'b0, fault_flags};
endmodule
