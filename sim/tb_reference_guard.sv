`timescale 1ns/1ps
module tb_reference_guard;
    localparam integer FRAME_CYCLES = 32;
    localparam integer WINDOW = 3;
    logic clk = 1'b0;
    always #10 clk = !clk;
    logic rst_n = 1'b0;
    logic frame_valid = 1'b0;
    logic invalidate = 1'b0;
    logic angle_valid = 1'b1;
    logic signed [15:0] load_a = 16'sd1024;
    logic signed [15:0] load_b = -16'sd512;
    logic signed [15:0] load_c = -16'sd512;
    logic signed [17:0] cos_a = 18'sd65536;
    logic signed [17:0] cos_b = -18'sd32768;
    logic signed [17:0] cos_c = -18'sd32768;
    wire ready_for_frame, result_valid, reference_ready;
    wire input_error, cadence_error;
    wire signed [17:0] mean_d, source_a, source_b, source_c;
    wire signed [17:0] reference_a, reference_b, reference_c;
    integer cycle_number = 0;
    integer result_count = 0;
    integer input_error_count = 0;
    integer cadence_error_count = 0;
    integer checks = 0;
    integer anchor;
    integer before_results, before_input_errors, before_cadence_errors;
    logic short_rst_n = 1'b0;
    logic short_frame_valid = 1'b0;
    wire short_ready, short_result_valid, short_reference_ready;
    wire short_input_error, short_cadence_error;

    apf_reference_guard #(
        .FRAME_CYCLES(FRAME_CYCLES), .WINDOW(WINDOW)
    ) dut (.*);

    // Deliberately faster than the calculator can process: the guard must
    // preserve the core's busy-rejection error rather than masking that frame.
    apf_reference_guard #(.FRAME_CYCLES(2), .WINDOW(1)) short_period_dut (
        .clk(clk), .rst_n(short_rst_n), .frame_valid(short_frame_valid),
        .invalidate(1'b0), .angle_valid(1'b1),
        .load_a(load_a), .load_b(load_b), .load_c(load_c),
        .cos_a(cos_a), .cos_b(cos_b), .cos_c(cos_c),
        .ready_for_frame(short_ready), .result_valid(short_result_valid),
        .reference_ready(short_reference_ready), .input_error(short_input_error),
        .cadence_error(short_cadence_error),
        .mean_d(), .source_a(), .source_b(), .source_c(),
        .reference_a(), .reference_b(), .reference_c()
    );

    // Monitor after nonblocking assignments. Driver/check tasks finish at #3.
    always @(posedge clk) begin
        cycle_number = cycle_number + 1;
        #2;
        if (rst_n) begin
            if (result_valid) result_count = result_count + 1;
            if (input_error) input_error_count = input_error_count + 1;
            if (cadence_error) cadence_error_count = cadence_error_count + 1;
        end
    end

    task automatic require(input logic condition, input string message);
        if (condition !== 1'b1)
            $fatal(1, "Guard check failed at cycle %0d: %s", cycle_number, message);
    endtask

    task automatic pass(input string message);
        checks = checks + 1;
        $display("PASS guard: %s", message);
    endtask

    task automatic wait_through(input integer target);
        while (cycle_number < target) begin
            @(posedge clk); #3;
        end
    endtask

    task automatic send_at(input integer target, input logic bad_coefficient);
        // Always begin driving on the falling edge before the target clock.
        do begin
            @(negedge clk);
        end while (cycle_number + 1 < target);
        require(cycle_number + 1 == target, "frame scheduling target already passed");
        cos_a = bad_coefficient ? 18'sd65537 : 18'sd65536;
        frame_valid = 1'b1;
        @(posedge clk); #3;
        frame_valid = 1'b0;
        cos_a = 18'sd65536;
    endtask

    task automatic await_idle;
        integer waited;
        waited = 0;
        while (!ready_for_frame && waited < 16) begin
            @(posedge clk); #3;
            waited = waited + 1;
        end
        require(ready_for_frame, "calculator did not return idle within 16 clocks");
    endtask

    task automatic check_ready_values;
        require(reference_ready, "full fresh history did not become ready");
        require(mean_d == 18'sd1024, "incorrect active-current mean");
        require(source_a == 18'sd1024 && source_b == -18'sd512 &&
                source_c == -18'sd512, "incorrect source references");
        require(reference_a == 0 && reference_b == 0 && reference_c == 0,
                "balanced active load should need zero compensation");
    endtask

    task automatic clear_history;
        @(negedge clk); invalidate = 1'b1;
        @(posedge clk); #3;
        require(!reference_ready && !result_valid, "explicit invalidate retained output");
        require(!input_error && !cadence_error, "explicit invalidate reported a frame error");
        @(negedge clk); invalidate = 1'b0;
    endtask

    task automatic warm_three(input integer first_cycle);
        integer j;
        integer previous_results;
        for (j = 0; j < WINDOW; j = j + 1) begin
            previous_results = result_count;
            anchor = first_cycle + j*FRAME_CYCLES;
            send_at(anchor, 1'b0);
            await_idle();
            require(result_count == previous_results + 1,
                    "accepted frame must publish exactly one calculation result");
            if (j < WINDOW - 1)
                require(!reference_ready, "reference became ready before a full new window");
            else
                check_ready_values();
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        warm_three(cycle_number + 2);
        require(cadence_error_count == 0 && input_error_count == 0,
                "first/exactly spaced warmup frames were rejected");
        before_results = result_count;
        anchor = anchor + FRAME_CYCLES;
        send_at(anchor, 1'b0);
        await_idle();
        check_ready_values();
        require(result_count == before_results + 1, "deadline frame was not accepted");
        pass("first frame, complete warmup, and exact deadline frame acceptance");

        // No frame on the next deadline must immediately revoke readiness.
        before_cadence_errors = cadence_error_count;
        before_results = result_count;
        wait_through(anchor + FRAME_CYCLES);
        require(cadence_error && !reference_ready, "missing deadline did not flush history");
        require(cadence_error_count == before_cadence_errors + 1,
                "missing deadline did not produce one error pulse");
        wait_through(cycle_number + 2*FRAME_CYCLES);
        require(cadence_error_count == before_cadence_errors + 1 &&
                result_count == before_results, "idle produced repeated errors or stale results");
        warm_three(cycle_number + 2);
        pass("missing frame flushes once; first recovery frame establishes a fresh cadence");

        // Arriving one clock early is still illegal. It must not count toward
        // the new history, even though the calculator is already idle.
        before_cadence_errors = cadence_error_count;
        before_results = result_count;
        send_at(anchor + FRAME_CYCLES - 1, 1'b0);
        require(cadence_error && !reference_ready, "early frame was not rejected");
        wait_through(cycle_number + 8);
        require(cadence_error_count == before_cadence_errors + 1 &&
                result_count == before_results, "early frame reached the calculator");
        warm_three(cycle_number + 2);
        pass("early frame is dropped and recovery needs the entire fresh window");

        clear_history();
        before_input_errors = input_error_count;
        before_cadence_errors = cadence_error_count;
        before_results = result_count;
        send_at(cycle_number + 2, 1'b0);
        require(!ready_for_frame, "expected in-flight reference calculation");
        @(negedge clk); angle_valid = 1'b0;
        @(posedge clk); #3;
        require(!reference_ready && !result_valid && !input_error && !cadence_error,
                "angle loss did not cancel cleanly");
        wait_through(cycle_number + 2*FRAME_CYCLES);
        require(result_count == before_results && input_error_count == before_input_errors &&
                cadence_error_count == before_cadence_errors,
                "angle loss published a stale result or produced a frame error");
        @(negedge clk); angle_valid = 1'b1;
        warm_three(cycle_number + 2);
        pass("lost angle cancels an in-flight frame and disarms the cadence");

        // Reset while a new transaction is in flight must invalidate both
        // that transaction and the earlier full moving-average history.
        anchor = anchor + FRAME_CYCLES;
        send_at(anchor, 1'b0);
        require(!ready_for_frame, "expected busy calculation before reset");
        @(negedge clk); rst_n = 1'b0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        before_results = result_count;
        wait_through(cycle_number + 10);
        require(!reference_ready && !result_valid && result_count == before_results,
                "reset allowed an old calculation/history to survive");
        warm_three(cycle_number + 2);
        pass("reset cancels pending work and forces complete history refill");

        clear_history();
        anchor = cycle_number + 2;
        send_at(anchor, 1'b0);
        await_idle();
        before_results = result_count;
        before_input_errors = input_error_count;
        before_cadence_errors = cadence_error_count;
        anchor = anchor + FRAME_CYCLES;
        send_at(anchor, 1'b1);
        await_idle();
        require(input_error_count == before_input_errors + 1 && !reference_ready,
                "core coefficient error was masked by the cadence guard");
        require(result_count == before_results && cadence_error_count == before_cadence_errors,
                "coefficient rejection was confused with a cadence error");
        warm_three(anchor + FRAME_CYCLES);
        pass("core coefficient rejection remains visible and requires complete rewarm");

        clear_history();
        before_cadence_errors = cadence_error_count;
        wait_through(cycle_number + 2*FRAME_CYCLES);
        require(cadence_error_count == before_cadence_errors,
                "explicit invalidate failed to disarm cadence watchdog");
        require(!reference_ready && source_a == 0 && source_b == 0 && source_c == 0 &&
                reference_a == 0 && reference_b == 0 && reference_c == 0,
                "invalid output contract requires zero values and ready low");
        pass("explicit invalidation clears outputs and does not create idle cadence faults");

        @(negedge clk);
        short_rst_n = 1'b1;
        short_frame_valid = 1'b1;
        @(posedge clk); #3;
        short_frame_valid = 1'b0;
        require(!short_ready, "short-period calculator did not capture its first frame");
        repeat (2) @(negedge clk);
        short_frame_valid = 1'b1;
        @(posedge clk); #3;
        short_frame_valid = 1'b0;
        require(short_input_error && !short_cadence_error && !short_reference_ready &&
                !short_result_valid, "legal cadence frame while busy did not preserve core error");
        short_rst_n = 1'b0;
        pass("impossibly fast legal cadence exposes the core busy error");

        $display("ALL PASS guard: %0d scenario groups", checks);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "Guard test timeout");
    end
endmodule
