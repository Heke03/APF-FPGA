`timescale 1ns/1ps
// H3: everything that runs on the board for the stand-alone demo - apf_core in
// closed loop with the virtual power stage, through the ADC stand-in, and the
// THD meter on grid current a. The board top level (switches, LEDs, 7-segment
// displays) wraps this module; nothing outside the FPGA is driven.
module apf_vps_system_H3 #(
    parameter         COS_FILE    = "cos_table_4096.hex",
    parameter         THD_TABLE_FILE = "thd_table_200.hex",
    parameter integer CONV_CYCLES = 1000                  // ADC stand-in delay, 20 us
) (
    input  logic        clk,                 // 50 MHz
    input  logic        rst_n,
    input  logic        run_request,         // operator: start compensating
    input  logic        load_step,           // 0: 33 ohm load, 1: 22 ohm
    input  logic        noise_en,            // ~1 count rms ADC noise
    output logic [2:0]  gate_hi,
    output logic [2:0]  gate_lo,
    output logic        switching,
    output logic        pll_locked,
    output logic        compensating_ready,
    output logic [3:0]  fault_flags,         // {pll_lost, over_voltage, over_current, measurement}
    output logic [31:0] freq_word,
    output logic [11:0] vdc_avg,             // apf_core's cycle average, 10 counts/V
    output logic signed [15:0] idc_cmd,
    // plant values, for the displays and Signal Tap
    output logic signed [23:0] vg_a,         // 2^-12 V
    output logic signed [31:0] i_load_a,     // 2^-24 A
    output logic signed [31:0] i_inv_a,      // 2^-24 A
    output logic signed [41:0] vdc,          // 2^-24 V
    output logic [31:0] shoot_count,
    // grid current a (load - inverter): THD every 0.1 s and the peak in the same 0.1 s
    output logic [13:0] thd,                 // 0.01 %
    output logic        thd_valid,
    output logic        thd_done,            // one clock per reading
    output logic [9:0]  thd_window_pos,      // samples taken in the meter's current window
    output logic [32:0] i_grid_peak,         // 2^-24 A
    output logic        sample_now           // one clock per frame: the ADC and the meter sample now
);
    logic adc_start, adc_valid, step_done;
    logic [11:0] adc_code [0:6];
    logic [11:0] code [0:6];
    logic signed [23:0] vg [0:2];
    logic signed [31:0] il [0:2], i_inv [0:2];

    apf_core #(.COS_FILE(COS_FILE)) core (
        .clk, .rst_n, .run_request, .adc_valid, .adc_code, .adc_start,
        .gate_hi, .gate_lo, .switching, .pll_locked, .compensating_ready,
        .fault_flags, .freq_word, .vdc_avg, .idc_cmd
    );

    virtual_power_stage_H3 #(.COS_FILE(COS_FILE)) plant (
        .clk, .rst_n, .gate_hi, .gate_lo, .contactor(switching), .load_step,
        .step_done, .vg, .il, .i_inv, .vdc, .code, .shoot_count
    );

    vps_adc_H3 #(.CONV_CYCLES(CONV_CYCLES)) adc (
        .clk, .rst_n, .adc_start, .noise_en, .code_now(code), .adc_valid, .adc_code
    );

    assign vg_a = vg[0];
    assign i_load_a = il[0];
    assign i_inv_a = i_inv[0];

    // ---- grid current a: THD meter (sampled with the ADC frame) and peak ----
    wire signed [32:0] i_grid = 33'(il[0]) - 33'(i_inv[0]);
    wire [32:0] i_grid_abs = i_grid[32] ? 33'(-i_grid) : 33'(i_grid);

    thd_meter_H3 #(.TABLE_FILE(THD_TABLE_FILE)) meter (
        .clk, .rst_n, .sample_en(adc_start), .sample(32'(i_grid)),
        .thd, .thd_valid, .reading_done(thd_done), .window_pos(thd_window_pos)
    );
    assign sample_now = adc_start && rst_n;      // adc_start is high all through reset

    logic [32:0] peak_run;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            peak_run <= '0; i_grid_peak <= '0;
        end else if (thd_done) begin
            i_grid_peak <= peak_run; peak_run <= i_grid_abs;
        end else if (i_grid_abs > peak_run)
            peak_run <= i_grid_abs;
    end
endmodule
