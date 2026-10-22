`timescale 1ns/1ps
// Parameter corners only: eight-bit ADC codes and two watchdog limits.
module tb_measurement_parameters;
    reg clk = 0, rst_n = 0;
    reg valid_1 = 0, valid_7 = 0;
    reg [7:0] a1 = 240, b1 = 15, c1 = 128;
    reg [7:0] a7 = 200, b7 = 20, c7 = 128;
    wire signed [8:0] sa1, sb1, sc1, sa7, sb7, sc7;
    wire sv1, ready1, range1, stale1, sv7, ready7, range7, stale7;
    integer k;
    always #10 clk = !clk;

    measurement_frontend #(
        .ADC_BITS(8), .OFFSET_A(8'd240), .OFFSET_B(8'd15),
        .OFFSET_C(8'd128), .CODE_MIN(8'd0), .CODE_MAX(8'd255),
        .TIMEOUT_CYCLES(1)
    ) timeout_one (
        .clk(clk), .rst_n(rst_n), .frame_valid(valid_1),
        .adc_a(a1), .adc_b(b1), .adc_c(c1),
        .sample_a(sa1), .sample_b(sb1), .sample_c(sc1),
        .sample_valid(sv1), .measurement_ready(ready1),
        .range_fault(range1), .stale_fault(stale1)
    );

    measurement_frontend #(
        .ADC_BITS(8), .OFFSET_A(8'd200), .OFFSET_B(8'd20),
        .OFFSET_C(8'd128), .CODE_MIN(8'd10), .CODE_MAX(8'd240),
        .TIMEOUT_CYCLES(7)
    ) timeout_seven (
        .clk(clk), .rst_n(rst_n), .frame_valid(valid_7),
        .adc_a(a7), .adc_b(b7), .adc_c(c7),
        .sample_a(sa7), .sample_b(sb7), .sample_c(sc7),
        .sample_valid(sv7), .measurement_ready(ready7),
        .range_fault(range7), .stale_fault(stale7)
    );

    task automatic tick;
        @(posedge clk); #2;
    endtask

    task automatic check_one(input bit v, r, s, input integer a, b, c);
        if ({sv1, ready1, range1, stale1} !== {v, r, 1'b0, s} ||
            $signed(sa1) !== a || $signed(sb1) !== b || $signed(sc1) !== c)
            $fatal(1, "TIMEOUT=1: state=%b%b%b%b samples=%0d,%0d,%0d",
                   sv1, ready1, range1, stale1, sa1, sb1, sc1);
    endtask

    task automatic check_seven(input bit v, r, s, input integer a, b, c);
        if ({sv7, ready7, range7, stale7} !== {v, r, 1'b0, s} ||
            $signed(sa7) !== a || $signed(sb7) !== b || $signed(sc7) !== c)
            $fatal(1, "TIMEOUT=7: state=%b%b%b%b samples=%0d,%0d,%0d",
                   sv7, ready7, range7, stale7, sa7, sb7, sc7);
    endtask

    initial begin
        tick();
        check_one(0, 0, 0, 0, 0, 0);
        check_seven(0, 0, 0, 0, 0, 0);

        // Keep the seven-cycle instance fed while checking the one-cycle case.
        @(negedge clk); rst_n = 1; valid_1 = 1; valid_7 = 1;
        tick();
        check_one(1, 1, 0, 0, 0, 0);
        check_seven(1, 1, 0, 0, 0, 0);

        // Both unsigned full-scale endpoints are legal. The +/-240 results
        // require nine signed bits and expose premature signed conversion.
        @(negedge clk); a1 = 0; b1 = 255; c1 = 0;
        tick(); check_one(1, 1, 0, -240, 240, -128);
        @(negedge clk); a1 = 255; b1 = 0; c1 = 255;
        tick(); check_one(1, 1, 0, 15, -15, 127);

        // One missed edge is the exact expiry boundary; old values must hold.
        @(negedge clk); valid_1 = 0;
        tick(); check_one(0, 0, 1, 15, -15, 127);
        @(negedge clk); valid_1 = 1; a1 = 239; b1 = 16; c1 = 129;
        tick(); check_one(1, 1, 0, -1, 1, 1);
        // With TIMEOUT=1 every next edge is a deadline. Accepted data wins.
        @(negedge clk); a1 = 241; b1 = 14; c1 = 127;
        tick(); check_one(1, 1, 0, 1, -1, -1);

        // The other instance uses restricted, inclusive code bounds.
        @(negedge clk); valid_1 = 0; a7 = 10; b7 = 240; c7 = 10;
        tick(); check_seven(1, 1, 0, -190, 220, -118);
        @(negedge clk); a7 = 240; b7 = 10; c7 = 240;
        tick(); check_seven(1, 1, 0, 40, -10, 112);
        @(negedge clk); a7 = 200; b7 = 20; c7 = 128;
        tick(); check_seven(1, 1, 0, 0, 0, 0);

        for (k = 0; k < 6; k = k + 1) begin
            @(negedge clk); valid_7 = 0;
            tick(); check_seven(0, 1, 0, 0, 0, 0);
        end
        // This is the seventh edge since acceptance: it must accept, not trip.
        @(negedge clk); valid_7 = 1; a7 = 201; b7 = 19; c7 = 130;
        tick(); check_seven(1, 1, 0, 1, -1, 2);

        // Verify that deadline acceptance restarted the full seven-edge timer.
        for (k = 0; k < 6; k = k + 1) begin
            @(negedge clk); valid_7 = 0;
            tick(); check_seven(0, 1, 0, 1, -1, 2);
        end
        @(negedge clk); valid_7 = 0;
        tick(); check_seven(0, 0, 1, 1, -1, 2);
        repeat (3) begin
            @(negedge clk);
            tick(); check_seven(0, 0, 1, 1, -1, 2);
        end

        // Reset after accepted data clears samples/readiness, even off-clock.
        @(negedge clk); valid_1 = 1; valid_7 = 1;
        tick();
        check_one(1, 1, 0, 1, -1, -1);
        check_seven(1, 1, 0, 1, -1, 2);
        #3; rst_n = 0; #2;
        check_one(0, 0, 0, 0, 0, 0);
        check_seven(0, 0, 0, 0, 0, 0);
        @(negedge clk); valid_1 = 0; valid_7 = 0;
        tick();
        @(negedge clk); rst_n = 1;
        tick();
        check_one(0, 0, 1, 0, 0, 0);
        check_seven(0, 0, 0, 0, 0, 0);

        $display("ALL PASS: measurement parameter corner cases");
        $finish;
    end

    initial begin
        #20_000;
        $fatal(1, "Measurement parameter test timeout");
    end
endmodule
