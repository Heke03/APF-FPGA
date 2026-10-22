`timescale 1ns/1ps
// Independent known-value checks for minimal and non-power-of-two windows.
module tb_reference_parameters;
    logic clk = 1'b0;
    always #10 clk = ~clk;
    logic rst_n = 1'b0, frame_valid = 1'b0, invalidate = 1'b0;
    logic angle_valid = 1'b1;
    logic signed [15:0] load_a = 0, load_b = 0, load_c = 0;
    logic signed [17:0] cos_a = 65536, cos_b = -32768, cos_c = -32768;
    wire [1:0] ready, valid, reference_ready, input_error;
    wire signed [17:0] mean_d [0:1];
    wire signed [17:0] source_a [0:1], source_b [0:1], source_c [0:1];
    wire signed [17:0] reference_a [0:1], reference_b [0:1], reference_c [0:1];
    integer checked_frames = 0;

    for (genvar g = 0; g < 2; g = g + 1) begin : configurations
        apf_reference #(.WINDOW((g == 0) ? 1 : 3)) dut (
            .clk(clk), .rst_n(rst_n), .frame_valid(frame_valid),
            .invalidate(invalidate), .angle_valid(angle_valid),
            .load_a(load_a), .load_b(load_b), .load_c(load_c),
            .cos_a(cos_a), .cos_b(cos_b), .cos_c(cos_c),
            .ready_for_frame(ready[g]), .result_valid(valid[g]),
            .reference_ready(reference_ready[g]), .input_error(input_error[g]),
            .mean_d(mean_d[g]), .source_a(source_a[g]),
            .source_b(source_b[g]), .source_c(source_c[g]),
            .reference_a(reference_a[g]), .reference_b(reference_b[g]),
            .reference_c(reference_c[g])
        );
    end

    task automatic flush_history;
        @(negedge clk); invalidate = 1'b1;
        @(posedge clk); #1;
        if (reference_ready !== 2'b00 || valid !== 2'b00 || input_error !== 2'b00)
            $fatal(1, "Parameter invalidation did not clear status");
        for (integer k = 0; k < 2; k = k + 1)
            if (mean_d[k] !== 0 || source_a[k] !== 0 || source_b[k] !== 0 ||
                source_c[k] !== 0 || reference_a[k] !== 0 ||
                reference_b[k] !== 0 || reference_c[k] !== 0)
                $fatal(1, "Parameter invalidation did not clear outputs");
        @(negedge clk); invalidate = 1'b0;
    endtask

    task automatic check_frame(input integer a, b, c, expected_one, expected_three,
                               input bit three_ready);
        integer timeout_cycles, expected_mean, sa, sb, sc;
        bit expected_ready;
        @(negedge clk);
        if (ready !== 2'b11) $fatal(1, "Parameter DUT not ready");
        load_a = a; load_b = b; load_c = c; frame_valid = 1'b1;
        @(negedge clk); frame_valid = 1'b0;
        timeout_cycles = 0;
        while (valid !== 2'b11 && timeout_cycles < 20) begin
            @(posedge clk); #1; timeout_cycles = timeout_cycles + 1;
        end
        if (valid !== 2'b11 || input_error !== 2'b00)
            $fatal(1, "Parameter completion timeout/error");
        for (integer k = 0; k < 2; k = k + 1) begin
            expected_ready = (k == 0) || three_ready;
            expected_mean = (k == 0) ? expected_one : expected_three;
            // All expectations are small exact integers; SV division rounds to zero.
            sa = expected_mean * $signed(cos_a) / 65536;
            sb = expected_mean * $signed(cos_b) / 65536;
            sc = expected_mean * $signed(cos_c) / 65536;
            if (reference_ready[k] !== expected_ready || mean_d[k] !== expected_mean ||
                source_a[k] !== sa || source_b[k] !== sb || source_c[k] !== sc ||
                reference_a[k] !== (expected_ready ? a-sa : 0) ||
                reference_b[k] !== (expected_ready ? b-sb : 0) ||
                reference_c[k] !== (expected_ready ? c-sc : 0))
                $fatal(1, "Parameter result mismatch frame=%0d WINDOW=%0d mean=%0d expected=%0d",
                       checked_frames, (k == 0) ? 1 : 3, mean_d[k], expected_mean);
        end
        checked_frames = checked_frames + 1;
        @(posedge clk); #1;
        if (valid !== 2'b00) $fatal(1, "Parameter result_valid was not one cycle");
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        // Balanced even currents yield d=v with these exact phase cosines.
        check_frame(2, -1, -1, 2, 0, 0);
        check_frame(4, -2, -2, 4, 0, 0);
        check_frame(6, -3, -3, 6, 4, 1);
        check_frame(8, -4, -4, 8, 6, 1);
        // Dirty RAM must not leak through after a logical history reset.
        flush_history();
        check_frame(-2, 1, 1, -2, 0, 0);
        check_frame(-2, 1, 1, -2, 0, 0);
        check_frame(-4, 2, 2, -4, -2, 1); // -8/3 truncates to -2.
        flush_history();
        check_frame(3, -1, -2, 3, 0, 0);
        check_frame(3, -1, -2, 3, 0, 0);
        check_frame(3, -1, -2, 3, 3, 1); // -3/2 source rounds to -1.
        flush_history();
        cos_a = 0; cos_b = 0; cos_c = 0;
        check_frame(2, -1, -1, 0, 0, 0);
        check_frame(4, -2, -2, 0, 0, 0);
        check_frame(6, -3, -3, 0, 0, 1);
        flush_history();
        cos_a = -65536; cos_b = 0; cos_c = 65536;
        check_frame(-3, 0, 3, 4, 0, 0); // Both inclusive coefficient endpoints.
        $display("ALL PASS: WINDOW=1 and WINDOW=3, %0d known-value frames, rolling mean, signed truncation, dirty-history rewarm, coefficient endpoints", checked_frames);
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "Parameter test timeout");
    end
endmodule
