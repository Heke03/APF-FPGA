`timescale 1ns/1ps
// Internal, synchronous three-channel sample interface; NOT an ADC pin driver.
// All three codes must belong to one completed frame. The ADC adapter must
// assemble that frame, handle its clock domain, and then assert frame_valid.
// Examples below are provisional code-domain settings, not sensor calibration.
module measurement_frontend #(
    parameter integer ADC_BITS = 12,
    parameter [ADC_BITS-1:0] OFFSET_A = 2048,
    parameter [ADC_BITS-1:0] OFFSET_B = 2056,
    parameter [ADC_BITS-1:0] OFFSET_C = 2040,
    parameter [ADC_BITS-1:0] CODE_MIN = 16,
    parameter [ADC_BITS-1:0] CODE_MAX = 4079,
    parameter integer TIMEOUT_CYCLES = 5000
) (
    input wire clk,
    input wire rst_n,
    input wire frame_valid,
    input wire [ADC_BITS-1:0] adc_a, adc_b, adc_c,
    output reg signed [ADC_BITS:0] sample_a, sample_b, sample_c,
    output reg sample_valid,
    output reg measurement_ready,
    output reg range_fault,
    output reg stale_fault
);
    localparam integer AGE_BITS = (TIMEOUT_CYCLES < 2) ? 1 :
                                 $clog2(TIMEOUT_CYCLES + 1);
    reg [AGE_BITS-1:0] age_cycles;
    wire frame_in_range = (adc_a >= CODE_MIN) && (adc_a <= CODE_MAX) &&
                          (adc_b >= CODE_MIN) && (adc_b <= CODE_MAX) &&
                          (adc_c >= CODE_MIN) && (adc_c <= CODE_MAX);
    wire accept_frame = frame_valid && frame_in_range;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_a <= 0;
            sample_b <= 0;
            sample_c <= 0;
            sample_valid <= 0;
            measurement_ready <= 0;
            range_fault <= 0;
            stale_fault <= 0;
            age_cycles <= 0;
        end else begin
            sample_valid <= 0;
            // A valid frame on the deadline wins over timeout.
            if (accept_frame) begin
                // Zero extension BEFORE signed subtraction preserves negative
                // results, including codes below the calibrated zero point.
                sample_a <= $signed({1'b0, adc_a}) - $signed({1'b0, OFFSET_A});
                sample_b <= $signed({1'b0, adc_b}) - $signed({1'b0, OFFSET_B});
                sample_c <= $signed({1'b0, adc_c}) - $signed({1'b0, OFFSET_C});
                sample_valid <= 1;
                measurement_ready <= 1;
                range_fault <= 0;
                stale_fault <= 0;
                age_cycles <= 0;
            end else begin
                // Reject the whole frame; preserve the last accepted values.
                // Rejected frames do not refresh the missing-data watchdog.
                if (frame_valid) begin
                    range_fault <= 1;
                    measurement_ready <= 0;
                end
                if (age_cycles < TIMEOUT_CYCLES)
                    age_cycles <= age_cycles + 1'b1;
                if (age_cycles >= TIMEOUT_CYCLES - 1) begin
                    stale_fault <= 1;
                    measurement_ready <= 0;
                end
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (ADC_BITS < 2 || ADC_BITS > 24 || CODE_MIN > CODE_MAX ||
            TIMEOUT_CYCLES < 1)
            $fatal(1, "Invalid measurement frontend parameters");
    end
    // synthesis translate_on
endmodule
