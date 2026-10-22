// Self-checking testbench for srf_pll. Replays sim/pll_vectors.txt, written by
// model/pll_model.py (11,000 frames: harmonics, noise, a 50->51 Hz step, a 30 deg
// phase jump, a 30 ms voltage loss and a 1 ms measurement fault), and requires
// every published output to match the bit-accurate model exactly.
//   vsim -c work.tb_srf_pll +VECTORS=sim/pll_vectors.txt -do "run -all; quit -f"
`timescale 1ns/1ps
module tb_srf_pll;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic sample_valid = 1'b0;
    logic sample_ok = 1'b0;
    logic signed [15:0] v_a = '0, v_b = '0, v_c = '0;
    logic ready, result_valid, overrun, angle_valid, low_amplitude;
    logic signed [17:0] phase_error, cos_a, cos_b, cos_c, sin_a, sin_b, sin_c;
    logic [25:0] amplitude;
    logic [31:0] freq_word, theta;

    always #10 clk = ~clk;

    srf_pll #(.COS_FILE("rtl/cos_table_4096.hex")) dut (.*);

    int fd, n, frames, errors, overruns, lock_frame;
    int va, vb, vc, ok, e_err, e_mag, e_low, e_locked, e_ca, e_cb, e_cc;
    longint e_freq, e_theta;
    string path, line;

    task automatic check(string name, longint got, longint exp);
        if (got != exp) begin
            errors++;
            if (errors <= 20)
                $display("MISMATCH frame %0d %s: got %0d expected %0d", frames, name, got, exp);
        end
    endtask

    // Count overrun pulses as they happen.
    always @(posedge clk) if (overrun) overruns++;

    initial begin
        if (!$value$plusargs("VECTORS=%s", path)) path = "sim/pll_vectors.txt";
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "cannot open %s", path);
        errors = 0; frames = 0; overruns = 0; lock_frame = -1;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        wait (ready);
        @(posedge clk);
        // Initial angle is 0: cos a,b,c = 1, -0.5, -0.5. 120 deg is not on a
        // 4096-entry grid point, so the nearest table entry gives -0.49956.
        check("init cos_a", cos_a, 65536);
        check("init cos_b", cos_b, -32739);
        check("init cos_c", cos_c, -32739);
        if (angle_valid) begin errors++; $display("angle_valid set before any frame"); end

        while (!$feof(fd)) begin
            void'($fgets(line, fd));
            if (line.len() < 2 || line[0] == "#") continue;
            n = $sscanf(line, "%d %d %d %d %d %d %d %d %d %d %d %d %d",
                        va, vb, vc, ok, e_err, e_mag, e_low, e_freq, e_theta, e_locked, e_ca, e_cb, e_cc);
            if (n != 13) $fatal(1, "bad vector line: %s", line);

            @(negedge clk);
            v_a = va; v_b = vb; v_c = vc; sample_ok = ok;
            sample_valid = 1'b1;
            @(negedge clk);
            sample_valid = 1'b0;
            // One extra strobe while busy must be reported and ignored.
            if (frames == 1234) begin
                @(negedge clk); sample_valid = 1'b1; v_a = 16'sh7fff;
                @(negedge clk); sample_valid = 1'b0;
            end
            @(posedge clk iff result_valid);
            #1;
            check("phase_error", phase_error, e_err);
            check("amplitude", amplitude, e_mag);
            check("low_amplitude", low_amplitude, e_low);
            check("freq_word", freq_word, e_freq);
            check("theta", theta, e_theta);
            check("angle_valid", angle_valid, e_locked);
            check("cos_a", cos_a, e_ca);
            check("cos_b", cos_b, e_cb);
            check("cos_c", cos_c, e_cc);
            if (!ready) begin errors++; $display("not ready after publish, frame %0d", frames); end
            if (angle_valid && lock_frame < 0) lock_frame = frames;
            frames++;
            repeat (20) @(posedge clk);
        end
        $fclose(fd);

        if (overruns != 1) begin errors++; $display("expected 1 overrun pulse, saw %0d", overruns); end
        if (frames != 11000) begin errors++; $display("expected 11000 frames, ran %0d", frames); end
        $display("frames %0d, first lock at frame %0d (%.1f ms)", frames, lock_frame, lock_frame / 10.0);
        if (errors == 0) $display("ALL PASS: %0d frames bit-exact against model/pll_model.py", frames);
        else             $display("FAILED: %0d mismatches", errors);
        $finish;
    end

    // Latency guard: a frame must finish well inside the 5000-clock sample period.
    int busy_clocks;
    always @(posedge clk) begin
        if (ready || !rst_n) busy_clocks <= 0;
        else begin
            busy_clocks <= busy_clocks + 1;
            if (busy_clocks == 200) $display("ERROR: frame took more than 200 clocks");
        end
    end
endmodule
