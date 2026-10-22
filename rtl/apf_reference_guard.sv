// Fixed-rate frame guard for the synthesizable current-reference calculation.
// The first frame establishes the cadence. Later frames must arrive exactly
// FRAME_CYCLES clocks apart. A missed or early frame flushes the complete
// reference history; the offending frame is not sent to the calculator.
// ready_for_frame means calculation idle, NOT that this clock is a legal
// cadence time. The external acquisition scheduler must enforce that timing.
module apf_reference_guard #(
    parameter integer FRAME_CYCLES = 5000,
    parameter integer WINDOW = 200
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 frame_valid,
    input  logic                 invalidate,
    input  logic                 angle_valid,
    input  logic signed [15:0]   load_a,
    input  logic signed [15:0]   load_b,
    input  logic signed [15:0]   load_c,
    input  logic signed [17:0]   cos_a,
    input  logic signed [17:0]   cos_b,
    input  logic signed [17:0]   cos_c,
    output logic                 ready_for_frame,
    output logic                 result_valid,
    output logic                 reference_ready,
    output logic                 input_error,
    output logic                 cadence_error,
    output logic signed [17:0]   mean_d,
    output logic signed [17:0]   source_a,
    output logic signed [17:0]   source_b,
    output logic signed [17:0]   source_c,
    output logic signed [17:0]   reference_a,
    output logic signed [17:0]   reference_b,
    output logic signed [17:0]   reference_c
);
    localparam integer AGE_WIDTH = (FRAME_CYCLES > 1) ?
                                   $clog2(FRAME_CYCLES) : 1;
    logic armed;
    logic [AGE_WIDTH-1:0] age;
    logic at_deadline;
    logic bad_cadence;
    logic core_invalidate;
    logic core_frame_valid;

    always_comb begin
        at_deadline = (age == FRAME_CYCLES - 1);
        bad_cadence = armed && (frame_valid != at_deadline);
        core_invalidate = invalidate || !angle_valid || bad_cadence;
        core_frame_valid = frame_valid && !core_invalidate;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            armed <= 1'b0;
            age <= '0;
            cadence_error <= 1'b0;
        end else begin
            cadence_error <= 1'b0;
            if (invalidate || !angle_valid) begin
                armed <= 1'b0;
                age <= '0;
            end else if (bad_cadence) begin
                armed <= 1'b0;
                age <= '0;
                cadence_error <= 1'b1;
            end else if (frame_valid) begin
                // Track cadence-qualified acquisition events independently of
                // coefficient/busy rejection inside the reference calculator.
                armed <= 1'b1;
                age <= '0;
            end else if (armed) begin
                age <= age + 1'b1;
            end
        end
    end

    apf_reference #(.WINDOW(WINDOW)) reference_core (
        .clk(clk), .rst_n(rst_n),
        .frame_valid(core_frame_valid), .invalidate(core_invalidate),
        .angle_valid(angle_valid),
        .load_a(load_a), .load_b(load_b), .load_c(load_c),
        .cos_a(cos_a), .cos_b(cos_b), .cos_c(cos_c),
        .ready_for_frame(ready_for_frame), .result_valid(result_valid),
        .reference_ready(reference_ready), .input_error(input_error),
        .mean_d(mean_d), .source_a(source_a), .source_b(source_b),
        .source_c(source_c), .reference_a(reference_a),
        .reference_b(reference_b), .reference_c(reference_c)
    );

    // synthesis translate_off
    initial begin
        if (FRAME_CYCLES < 1 || WINDOW < 1)
            $fatal(1, "FRAME_CYCLES and WINDOW must be positive");
    end
    // synthesis translate_on
endmodule
