// HEX4: tests the gate guard. The rules are checked on every clock of the whole run,
// first with a planned sequence and then with 400,000 clocks of random inputs:
//   1. a leg never has both switches on at the pins
//   2. no gate is on unless the guard was armed and nothing had tripped one clock before
//   3. at the pins, a switch only turns on after the other one of its leg has been off MIN_DEAD clocks
//   4. a trip stays until the operator disarms
//   5. disarmed: the buffer is disabled
// sim/run_hw_HEX4.do then runs this same test on copies of the guard with each rule
// removed on purpose. Every copy must fail, or the test proves nothing.
//
//   vsim -c work.tb_gate_guard_HEX4 -do "run -all; quit -f"
`timescale 1ns/1ps
module tb_gate_guard_HEX4;
    localparam int MIN_DEAD = 50, WDOG = 2000;
    logic clk = 0, rst_n = 0;
    always #10 clk = ~clk;
    logic arm = 0, drivers_ok = 1, adc_fault = 0, core_fault = 0, core_switching = 0, frame_tick = 0;
    logic [2:0] hi_in = 0, lo_in = 0, hi_out, lo_out;
    logic gate_en_n, contactor, tripped, running;
    logic [5:0] cause;
    gate_guard_HEX4 #(.MIN_DEAD_CLKS(MIN_DEAD), .WDOG_CLKS(WDOG)) dut (.*);

    int broken [1:5] = '{default: 0};
    logic tripped_prev = 0, rst_prev = 0;
    logic [2:0] hi_o_prev = 0, lo_o_prev = 0;
    int hi_off [0:2] = '{default: 1000}, lo_off [0:2] = '{default: 1000};
    // what the guard saw at the last clock edge. Inputs change away from that edge, so no race
    logic arm_seen = 0, running_seen = 0;
    always @(posedge clk) begin arm_seen = arm; running_seen = running; end
    always @(negedge clk) begin       // outputs settled; the _prev values are from the falling edge before
        for (int k = 0; k < 3; k++) begin
            if (hi_out[k] && lo_out[k]) broken[1]++;
            if (hi_out[k] && !hi_o_prev[k] && lo_off[k] < MIN_DEAD) broken[3]++;
            if (lo_out[k] && !lo_o_prev[k] && hi_off[k] < MIN_DEAD) broken[3]++;
            hi_off[k] = hi_out[k] ? 0 : hi_off[k] + 1;
            lo_off[k] = lo_out[k] ? 0 : lo_off[k] + 1;
        end
        if ((hi_out | lo_out) != 0 && !running_seen) broken[2]++;
        if (rst_prev && tripped_prev && arm_seen && !tripped) broken[4]++;
        if (rst_prev && !arm_seen && !gate_en_n) broken[5]++;
        tripped_prev = tripped; rst_prev = rst_n;
        hi_o_prev = hi_out; lo_o_prev = lo_out;
    end

    int fails = 0;
    task automatic check(input string what, input bit good);
        $display("  %-64s %s", what, good ? "ok" : "FAILED");
        if (!good) fails++;
    endtask
    task automatic clocks(input int n); repeat (n) @(posedge clk); #1; endtask
    task automatic disarm(); arm = 0; clocks(3); endtask
    task automatic arm_stop();           // arm from a stop, as the top level does
        core_switching = 0; hi_in = 0; lo_in = 0; clocks(MIN_DEAD + 2);
        drivers_ok = 1; adc_fault = 0; core_fault = 0; disarm();
        arm = 1; clocks(3);
    endtask
    // a good leg A pattern: lo off, dead time, hi on, hi off, dead time, lo on
    task automatic pwm_cycle(input int dead);
        lo_in[0] = 0; clocks(dead); hi_in[0] = 1; clocks(200); hi_in[0] = 0; clocks(dead); lo_in[0] = 1; clocks(200);
    endtask
    always @(posedge clk) frame_tick <= ($urandom_range(0, 999) == 0);

    initial begin
        clocks(3);
        check("in reset: gates off, buffer disabled", hi_out == 0 && lo_out == 0 && gate_en_n);
        rst_n = 1; clocks(MIN_DEAD + 2);

        core_switching = 1; lo_in = 3'b111; clocks(5);
        check("not armed, apf_core switching: gates off, buffer disabled, no contactor", lo_out == 0 && gate_en_n && !contactor);
        check("not armed: nothing counts as a trip", !tripped);
        arm = 1; clocks(5);
        check("armed while apf_core is switching: still off", !running && lo_out == 0 && gate_en_n);

        arm_stop();
        check("armed from a stop: running, buffer enabled", running && !gate_en_n);
        lo_in = 3'b111; clocks(5);
        check("armed, apf_core not switching: gates off", lo_out == 0 && !contactor);
        lo_in = 0; clocks(MIN_DEAD + 2);
        core_switching = 1; lo_in[0] = 1; clocks(100);
        check("switching: gates follow, contactor closed", lo_out[0] && contactor);
        repeat (5) pwm_cycle(100);
        check("5 good PWM cycles with 2 us dead time: no trip", !tripped && running);

        hi_in[0] = 1; @(posedge clk); #1;
        check("shoot-through commanded: off at once, nothing reached the pins", hi_out[0] == 0 && lo_out[0] == 0);
        check("shoot-through: tripped, cause bit 0", tripped && cause[0]);
        hi_in[0] = 0; clocks(5);
        check("command gone, still armed: stays tripped", tripped && gate_en_n);
        disarm();
        check("disarmed: trip clears", !tripped && cause == 0);

        arm_stop(); core_switching = 1; lo_in[0] = 1; clocks(100);
        lo_in[0] = 0; clocks(MIN_DEAD / 2); hi_in[0] = 1; @(posedge clk); #1;
        check("dead time too short: trip, cause bit 1, gate stayed off", tripped && cause[1] && hi_out == 0);
        hi_in = 0; disarm();

        arm_stop(); core_switching = 1; lo_in[1] = 1; clocks(100);
        drivers_ok = 0; @(posedge clk); #1;
        check("gate driver fault: off on the next clock, cause bit 2", lo_out == 0 && tripped && cause[2]);
        arm = 0; clocks(5);
        check("disarmed while the driver fault is still there: stays tripped", tripped);
        drivers_ok = 1; clocks(3);
        check("driver fault gone: clears", !tripped);
        lo_in = 0;

        arm_stop(); core_switching = 1; lo_in[2] = 1; clocks(100);
        adc_fault = 1; @(posedge clk); #1;
        check("ADC fault: off, cause bit 3", lo_out == 0 && cause[3]);
        adc_fault = 0; disarm(); lo_in = 0;

        arm_stop(); core_switching = 1; lo_in[2] = 1; clocks(100);
        core_fault = 1; @(posedge clk); #1;
        check("apf_core fault: off, cause bit 4", lo_out == 0 && cause[4]);
        core_fault = 0; disarm(); lo_in = 0;

        // watchdog: frame_tick stops
        arm_stop(); core_switching = 1; lo_in[1] = 1;
        force frame_tick = 1'b0;
        clocks(WDOG + 5);
        check("no ADC frames for the watchdog time: off, cause bit 5", lo_out == 0 && cause[5]);
        release frame_tick;
        lo_in = 0; disarm();

        // random: everything changes all the time, only the rules above may not break
        repeat (400000) begin
            @(negedge clk);
            hi_in = ($urandom_range(0, 19) == 0) ? 3'($urandom) : hi_in;
            lo_in = ($urandom_range(0, 19) == 0) ? 3'($urandom) : lo_in;
            if ($urandom_range(0, 3000) == 0) arm = !arm;
            if ($urandom_range(0, 2000) == 0) core_switching = !core_switching;
            drivers_ok = ($urandom_range(0, 4000) != 0);
            adc_fault = ($urandom_range(0, 8000) == 0);
            core_fault = ($urandom_range(0, 8000) == 0);
        end
        // a careful random phase too, so gates really are on a lot of the time
        for (int n = 0; n < 2000; n++) begin
            arm_stop(); core_switching = 1; lo_in = 3'b101;
            clocks(MIN_DEAD + $urandom_range(0, 30));
            repeat ($urandom_range(1, 4)) pwm_cycle(MIN_DEAD + 2 + $urandom_range(0, 80));
            case ($urandom_range(0, 2))                                  // sometimes illegal
                0: hi_in[$urandom_range(0, 2)] = 1;
                1: lo_in[$urandom_range(0, 2)] = 0;
                2: begin hi_in[1] = 1; lo_in[1] = 1; end                 // both from idle, in the same clock
            endcase
            clocks($urandom_range(1, 60));
            hi_in = 0; lo_in = 0; disarm();
        end
        check($sformatf("rule 1, never both on: broken %0d times", broken[1]), broken[1] == 0);
        check($sformatf("rule 2, on only if armed and clear: broken %0d times", broken[2]), broken[2] == 0);
        check($sformatf("rule 3, dead time at the pins: broken %0d times", broken[3]), broken[3] == 0);
        check($sformatf("rule 4, a trip stays until disarmed: broken %0d times", broken[4]), broken[4] == 0);
        check($sformatf("rule 5, disarmed means buffer disabled: broken %0d times", broken[5]), broken[5] == 0);
        $display("GATE GUARD TEST: %0d failed -> %s", fails, fails == 0 ? "OK" : "FAILED");
        $finish;
    end
endmodule
