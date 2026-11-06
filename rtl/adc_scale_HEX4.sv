`timescale 1ns/1ps
// HEX4: turns the AD7606's 16-bit values into the 12-bit codes apf_core was designed
// for (16 counts/V, 100 counts/A, 10 counts/V), so apf_core itself does not change:
//
//   code = round((raw - RAW_ZERO) * GAIN / 2^16) + CODE_ZERO, limited to 0..4095
//
// GAIN and RAW_ZERO are the calibration constants of each channel: they take out the
// sensor's gain error and offset. A negative GAIN turns a sensor mounted the other way
// round. The defaults come from matlab/frontend_sizing_HEX4.m.
module adc_scale_HEX4 #(
    // channel:                       vdc     if_b    if_a    il_b    il_a    vg_b    vg_a
    parameter logic [6:0][17:0] GAIN_Q16 = {18'sd12941, 18'sd6329, 18'sd6329, 18'sd6329, 18'sd6329, 18'sd7016, 18'sd7016},
    parameter logic [6:0][15:0] RAW_ZERO = '0,
    parameter logic [6:0][11:0] CODE_ZERO = {12'd0, 12'd2048, 12'd2048, 12'd2048, 12'd2048, 12'd2048, 12'd2048}
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic signed [15:0] raw [0:7],        // channel 8 is not used
    input  logic        raw_valid,
    output logic [11:0] code [0:6],
    output logic        code_valid
);
    logic signed [16:0] diff [0:6];
    logic signed [34:0] prod [0:6];
    logic [2:0] v;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v <= '0; code_valid <= 1'b0;
            for (int ch = 0; ch < 7; ch++) begin diff[ch] <= '0; prod[ch] <= '0; code[ch] <= CODE_ZERO[ch]; end
        end else begin
            v <= {v[1:0], raw_valid};
            code_valid <= v[2];
            for (int ch = 0; ch < 7; ch++) begin
                logic signed [20:0] y;
                diff[ch] <= 17'(raw[ch]) - 17'($signed(RAW_ZERO[ch]));
                prod[ch] <= diff[ch] * $signed(GAIN_Q16[ch]);
                y = 21'((prod[ch] + 35'sd32768) >>> 16) + 21'($signed({1'b0, CODE_ZERO[ch]}));
                if (v[1]) code[ch] <= (y < 0) ? 12'd0 : (y > 4095) ? 12'd4095 : 12'(y);
            end
        end
    end
endmodule
