// HEX4: the real-hardware top level, with everything outside the FPGA simulated at its
// pins: the sensors and the inverter are the virtual power stage, the ADC is the
// data-sheet model. Nothing inside de2_115_hw_top_HEX4 is touched.
//
//   +MODE=loop    (default) 1 s closed loop, same times as tb_apf_vps_H3: arm, run at
//                 10 ms, load step at 0.7 s. Logs a CSV in the same format. ~16 min.
//   +MODE=safety  stages every fault on the running inverter, and measures how fast
//                 the gates stop. ~6 min.
//   +NOISE=0      ADC noise off (default on, as in the H3 run)
//   +STOP_MS=30   end the loop run early, 30 ms after the run switch (for testing the test)
`timescale 1ns/1ps
module tb_hw_loop_HEX4;
    logic CLOCK_50 = 0;
    always #10 CLOCK_50 = ~CLOCK_50;
    logic [3:0]  KEY = 4'b1111;
    logic [17:0] SW = '0;
    logic [8:0]  LEDG;
    logic [17:0] LEDR;
    logic [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7;
    logic [15:0] ADC_DB;
    logic ADC_BUSY, ADC_FRSTDATA, ADC_CONVST, ADC_RD_N, ADC_CS_N, ADC_RESET, ADC_RANGE;
    logic [2:0] ADC_OS;
    logic GATE_EN_N, GATE_A_HI, GATE_A_LO, GATE_B_HI, GATE_B_LO, GATE_C_HI, GATE_C_LO, CONTACTOR;
    logic DRIVERS_OK = 1;

    de2_115_hw_top_HEX4 #(.COS_FILE("rtl/cos_table_4096.hex"), .THD_TABLE_FILE("rtl/thd_table_200.hex"),
                          .RESET_CLKS(100), .DEBOUNCE_CLKS(1000), .REFRESH(50_000), .CAP_LOG2(12)) dut (.*);

    // ---- the inverter and the sensors. The gate buffer passes nothing while disabled ----
    wire [2:0] gate_hi = {GATE_C_HI, GATE_B_HI, GATE_A_HI} & {3{!GATE_EN_N}};
    wire [2:0] gate_lo = {GATE_C_LO, GATE_B_LO, GATE_A_LO} & {3{!GATE_EN_N}};
    logic load_step = 0, step_done;
    logic signed [23:0] vg [0:2];
    logic signed [31:0] il [0:2], i_inv [0:2];
    logic signed [41:0] vdc;
    logic [11:0] code [0:6];
    logic [31:0] shoot_count;
    virtual_power_stage_H3 #(.COS_FILE("rtl/cos_table_4096.hex")) vps (
        .clk(CLOCK_50), .rst_n(dut.rst_n), .gate_hi, .gate_lo, .contactor(CONTACTOR), .load_step,
        .step_done, .vg, .il, .i_inv, .vdc, .code, .shoot_count);

    // ---- the ADC: each channel gets the raw value that scales back to the plant's code ----
    localparam logic [6:0][17:0] GAIN = {18'sd12941, 18'sd6329, 18'sd6329, 18'sd6329, 18'sd6329, 18'sd7016, 18'sd7016};
    localparam logic [6:0][11:0] ZERO = {12'd0, 12'd2048, 12'd2048, 12'd2048, 12'd2048, 12'd2048, 12'd2048};
    function automatic int forward(input int raw, input int ch);
        longint p = longint'(raw) * int'(GAIN[ch]) + 32768;
        int y = int'(p >>> 16) + int'(ZERO[ch]);
        return (y < 0) ? 0 : (y > 4095) ? 4095 : y;
    endfunction
    function automatic int to_raw(input int c, input int ch);
        int r = ((c - int'(ZERO[ch])) * 65536) / int'(GAIN[ch]);
        for (int d = 0; d < 40; d++) begin
            if (forward(r + d, ch) == c) return r + d;
            if (forward(r - d, ch) == c) return r - d;
        end
        $fatal(1, "no raw value for code %0d on channel %0d", c, ch);
    endfunction

    bit noise_en = 1;
    bit force_over_range = 0;
    logic [31:0] lfsr = 32'hACE1_2468;
    logic signed [15:0] analog [0:7], held [0:7];
    logic [11:0] code_noisy [0:6], code_held [0:6];
    always @(posedge CLOCK_50) begin
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        // the ADC samples when CONVST rises, so only the clocks before that matter (saves most of the run time)
        if (ADC_CONVST !== 1'b1) for (int ch = 0; ch < 7; ch++) begin
            automatic logic [3:0] r = lfsr[4 * ch +: 4];
            automatic int x = int'(code[ch]) + (noise_en ? (int'(r[0]) + int'(r[1]) + int'(r[2]) + int'(r[3]) - 2) : 0);
            x = (x < 0) ? 0 : (x > 4095) ? 4095 : x;
            if (force_over_range && ch == 4) x = 4090;
            code_noisy[ch] <= 12'(x);
            analog[ch] <= 16'(to_raw(x, ch));
        end
        analog[7] <= 16'd0;
    end
    bit inject_no_busy = 0, inject_busy_stuck = 0, inject_frst_wrong = 0;
    int model_errors, model_frames;
    ad7606_model_HEX4 adc (
        .reset(ADC_RESET), .convst(ADC_CONVST), .cs_n(ADC_CS_N), .rd_n(ADC_RD_N), .busy(ADC_BUSY), .frstdata(ADC_FRSTDATA),
        .db(ADC_DB), .analog, .inject_no_busy, .inject_busy_stuck, .inject_frst_wrong,
        .errors(model_errors), .frames(model_frames), .held);
    always @(posedge ADC_CONVST) code_held = code_noisy;

    // ---- every code apf_core receives must be the code the plant had when the ADC sampled ----
    int frames_checked = 0, frames_wrong = 0;
    always @(posedge CLOCK_50) if (dut.code_valid) begin
        frames_checked++;
        for (int ch = 0; ch < 7; ch++) if (dut.code[ch] !== code_held[ch]) begin
            frames_wrong++;
            if (frames_wrong <= 5) $display("  %m frame %0d channel %0d: core got %0d, plant had %0d", frames_checked, ch, dut.code[ch], code_held[ch]);
            break;
        end
    end

    longint cycles = 0;
    real t;
    always @(posedge CLOCK_50) cycles <= cycles + 1;
    assign t = cycles * 20e-9;

    int fails = 0;
    task automatic check(input string what, input bit good);
        $display("  %8.4f s  %-70s %s", t, what, good ? "ok" : "FAILED");
        if (!good) fails++;
    endtask

    // ---- the CSV of the H3 run ----
    int fd = 0, log_count = 0;
    function automatic real volts(input longint q, input int frac);
        return real'(q) / real'(64'd1 << frac);
    endfunction
    always @(posedge CLOCK_50) begin
        if (log_count == 499) begin
            log_count <= 0;
            if (fd != 0)
                $fwrite(fd, "%.6f,%.3f,%.3f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%0d,%0d,%0d,%0d,%.4f,%0d\n",
                        t, volts(vg[0], 12), volts(vg[1], 12), volts(il[0], 24), volts(il[1], 24),
                        volts(i_inv[0], 24), volts(i_inv[1], 24),
                        volts(il[0], 24) - volts(i_inv[0], 24), volts(il[1], 24) - volts(i_inv[1], 24),
                        volts(vdc, 24), dut.pll_locked, dut.compensating_ready, dut.switching, dut.fault_flags,
                        real'(dut.freq_word) * 10000.0 / 4294967296.0, dut.idc_cmd);
        end else
            log_count <= log_count + 1;
    end

    // ---- how long after a fault the pins were all off ----
    wire pins_quiet = ({GATE_A_HI, GATE_A_LO, GATE_B_HI, GATE_B_LO, GATE_C_HI, GATE_C_LO} == 0) && GATE_EN_N && !CONTACTOR;
    task automatic wait_quiet(input string what, input real limit_ns);
        realtime t0 = $realtime;
        fork : w
            wait (pins_quiet);
            #(limit_ns * 10);
        join_any
        disable w;
        check($sformatf("%s: pins off after %.0f ns (limit %.0f ns)", what, $realtime - t0, limit_ns), pins_quiet && ($realtime - t0 <= limit_ns));
    endtask
    task automatic start_running(input string what);      // SW17 up, then SW0 up, until it switches
        SW[17] = 1; #1ms;
        SW[0] = 1;
        fork : w
            wait (dut.switching && !GATE_EN_N);
            #300ms;
        join_any
        disable w;
        #10ms;
        check($sformatf("%s: running, gates active, contactor closed", what), dut.switching && !GATE_EN_N && CONTACTOR);
    endtask
    task automatic stop_clear();                          // SW0 down, SW17 down, then everything may clear
        SW[0] = 0; SW[17] = 0; #1ms;
    endtask

    string mode = "loop", csv;
    int stop_ms = 0;
    initial begin
        int noise;
        void'($value$plusargs("MODE=%s", mode));
        void'($value$plusargs("STOP_MS=%d", stop_ms));
        if ($value$plusargs("NOISE=%d", noise)) noise_en = (noise != 0);
        if (mode == "loop") run_loop(); else run_safety();
        check($sformatf("no data-sheet limit broken at the ADC pins (%0d conversions)", model_frames),
              model_errors == 0 || mode != "loop");
        check($sformatf("every code delivered unchanged: %0d frames, %0d wrong", frames_checked, frames_wrong),
              frames_checked > (stop_ms > 0 ? 100 : 1000) && (frames_wrong == 0 || mode != "loop"));
        check("no shoot-through in the plant, whole run", shoot_count == 0);
        $display("HW %s TEST: %0d failed -> %s", mode, fails, fails == 0 ? "OK" : "FAILED");
        $finish;
    end

    task automatic run_loop();
        real v_end;
        if (!$value$plusargs("CSV=%s", csv)) csv = "sim/out/HEX4/hw_loop.csv";
        fd = $fopen(csv, "w");
        if (fd == 0) $fatal(1, "cannot open %s", csv);
        $fwrite(fd, "t,vga,vgb,ila,ilb,ifa,ifb,isa,isb,vdc,locked,ready,switching,faults,freq,idc_cmd\n");
        #5ms;    SW[17] = 1;
        #5ms;    SW[0] = 1;                                  // 10 ms, as in the H3 run
        if (stop_ms > 0) begin
            #(stop_ms * 1ms);
            $fclose(fd); fd = 0;
            return;
        end
        #690ms;  load_step = 1;                              // 0.70 s
        #300ms;                                              // 1.00 s
        $fclose(fd); fd = 0;
        v_end = volts(vdc, 24);
        check($sformatf("DC link at the end: %.1f V", v_end), v_end > 290 && v_end < 310);
        check($sformatf("no faults, no trips: faults %b, cause %b", dut.fault_seen, dut.cause), dut.fault_seen == 0 && dut.cause == 0);
        check("still switching", dut.switching && !GATE_EN_N);
    endtask

    task automatic run_safety();
        // the operator gets it wrong: run without arming
        #5ms;    SW[0] = 1;
        #150ms;
        check("SW0 up, not armed, 150 ms: gates off, buffer disabled, no contactor", pins_quiet && !dut.switching);
        check("DC link untouched", volts(vdc, 24) > 160 && volts(vdc, 24) < 180);
        SW[17] = 1; #5ms;
        check("then armed with SW0 already up: still not running", !dut.switching && !CONTACTOR);
        SW[0] = 0; #1ms;
        SW[0] = 1;
        fork : w0
            wait (dut.switching);
            #300ms;
        join_any
        disable w0;
        #10ms;
        check("SW0 flipped while armed: running", dut.switching && !GATE_EN_N && CONTACTOR);
        stop_clear();
        check("SW0 and SW17 down: pins off", pins_quiet);

        // gate driver reports a fault (a 2-clock glitch must not count)
        start_running("before driver fault");
        DRIVERS_OK = 0; #40ns; DRIVERS_OK = 1; #1us;
        check("gate driver glitch of 40 ns: ignored", dut.switching && dut.cause == 0);
        DRIVERS_OK = 0;
        wait_quiet("gate driver fault", 200.0);
        check("cause shows the driver fault", dut.cause[2]);
        DRIVERS_OK = 1; #1ms;
        check("fault gone, still armed: stays off, and apf_core has stopped", pins_quiet && dut.tripped && !dut.switching);
        SW[17] = 0; #1ms;
        check("SW17 down: trip clears", !dut.tripped && dut.cause == 0);
        SW[17] = 1; #5ms;
        check("SW17 up with SW0 still up: buffer on, but no gate and no contactor until SW0 is flipped",
              !dut.switching && !CONTACTOR && {GATE_A_HI, GATE_A_LO, GATE_B_HI, GATE_B_LO, GATE_C_HI, GATE_C_LO} == 0);
        stop_clear();

        // BUSY stuck high
        start_running("before BUSY stuck");
        inject_busy_stuck = 1;
        wait_quiet("BUSY stuck high", 120_000.0);
        check("cause shows the ADC fault", dut.cause[3] && dut.adc_fault[1]);
        inject_busy_stuck = 0; stop_clear();

        // BUSY never rises
        start_running("before BUSY dead");
        inject_no_busy = 1;
        wait_quiet("BUSY never rises", 120_000.0);
        check("cause shows the ADC fault", dut.cause[3] && dut.adc_fault[0]);
        inject_no_busy = 0; stop_clear();

        // the channels out of order
        start_running("before FRSTDATA wrong");
        inject_frst_wrong = 1;
        wait_quiet("FRSTDATA wrong", 120_000.0);
        check("cause shows the ADC fault", dut.cause[3] && dut.adc_fault[2]);
        inject_frst_wrong = 0; stop_clear();

        // a sensor reads out of range: apf_core's measurement fault
        start_running("before sensor out of range");
        force_over_range = 1;
        wait_quiet("sensor out of range", 120_000.0);
        check("cause shows the apf_core fault; the LEDs keep which one", dut.cause[4] && dut.fault_seen != 0);
        force_over_range = 0; stop_clear();

        // the ADC goes silent with no fault of its own: the watchdog (300 us)
        start_running("before ADC frames stop");
        force dut.code_valid = 1'b0;
        wait_quiet("no ADC frames", 320_000.0);
        check("cause shows the watchdog", dut.cause[5]);
        release dut.code_valid;
        stop_clear();

        // after all of that it still starts, and the arm switch stops it
        start_running("after every fault: still starts");
        SW[17] = 0;
        wait_quiet("SW17 down while running", 21_000_000.0);
    endtask
endmodule
