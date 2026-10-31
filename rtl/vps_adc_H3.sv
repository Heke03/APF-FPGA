`timescale 1ns/1ps
// H3: stand-in for the ADC when apf_core runs on the virtual power stage.
// Takes the 7 codes of the current plant state when apf_core asks for a
// conversion (adc_start, at the PWM carrier boundary) and delivers them
// CONV_CYCLES later with adc_valid, like a real ADC would. Optional noise of
// about 1 count rms (binomial: 4 random bits counted, minus 2) on every channel.
module vps_adc_H3 #(
    parameter integer CONV_CYCLES = 1000     // 20 us at 50 MHz
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        adc_start,
    input  logic        noise_en,
    input  logic [11:0] code_now [0:6],     // from virtual_power_stage_H3
    output logic        adc_valid,
    output logic [11:0] adc_code [0:6]
);
    logic [31:0] lfsr;                       // x^32 + x^22 + x^2 + x + 1
    logic [11:0] held [0:6];
    logic [15:0] count;
    logic busy;

    function automatic logic [11:0] noisy(input logic [11:0] c, input logic [3:0] r);
        logic signed [13:0] x;
        x = $signed({2'b00, c}) + 14'(r[0]) + 14'(r[1]) + 14'(r[2]) + 14'(r[3]) - 14'sd2;
        if (x < 0) return 12'd0;
        if (x > 4095) return 12'd4095;
        return 12'(x);
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr <= 32'hACE1_2468;
            count <= '0; busy <= 1'b0; adc_valid <= 1'b0;
            for (int ch = 0; ch < 7; ch++) begin held[ch] <= 12'd2048; adc_code[ch] <= 12'd2048; end
        end else begin
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            adc_valid <= 1'b0;
            if (adc_start) begin
                for (int ch = 0; ch < 7; ch++)
                    held[ch] <= noise_en ? noisy(code_now[ch], lfsr[4 * ch +: 4]) : code_now[ch];
                count <= 16'(CONV_CYCLES);
                busy <= 1'b1;
            end else if (busy) begin
                if (count == 0) begin
                    for (int ch = 0; ch < 7; ch++) adc_code[ch] <= held[ch];
                    adc_valid <= 1'b1;
                    busy <= 1'b0;
                end else
                    count <= count - 16'd1;
            end
        end
    end
endmodule
