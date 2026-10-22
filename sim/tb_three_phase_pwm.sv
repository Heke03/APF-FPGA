`timescale 1ns/1ps
module tb_three_phase_pwm;
    parameter integer CLK_HZ = 50_000_000;
    parameter integer PWM_HZ = 10_000;
    parameter integer DEAD_CYCLES = 100;
    localparam integer CLK_NS = 1_000_000_000 / CLK_HZ;
    localparam integer HALF_TICKS = CLK_HZ / (2 * PWM_HZ);
    localparam integer PERIOD_TICKS = 2 * HALF_TICKS;
    reg clk = 0, rst_n = 0, enable = 0, fault_active = 0, fault_ack = 0;
    reg duty_valid = 0;
    reg [15:0] duty_a = 0, duty_b = 0, duty_c = 0;
    wire [2:0] gate_hi, gate_lo;
    wire fault_latched, frame_start;
    integer checks = 0;
    integer ca, cb, cc, la, lb, lc, k, n;
    integer prior_frame;
    reg [47:0] prior_duties;
    real angle;
    three_phase_pwm #(.CLK_HZ(CLK_HZ), .PWM_HZ(PWM_HZ),
                     .DEAD_CYCLES(DEAD_CYCLES)) dut (.*);
    always #(CLK_NS/2) clk = !clk;

    // Continuous checks cover every clock, including dynamic duty commands.
    always @(posedge clk) begin
        prior_frame = dut.phase_count;
        prior_duties = {dut.active_a, dut.active_b, dut.active_c};
        #1;
        if (rst_n) begin
            if ((gate_hi & gate_lo) !== 3'b000)
                $fatal(1, "Upper/lower overlap at %0t", $time);
            if ((!enable || fault_active || fault_latched) &&
                ({gate_hi, gate_lo} !== 6'b000000))
                $fatal(1, "Outputs not disabled at %0t", $time);
            if (prior_frame != 0 && prior_duties !==
                {dut.active_a, dut.active_b, dut.active_c})
                $fatal(1, "Duty update outside carrier boundary");
        end
    end

    genvar p;
    generate for (p=0; p<3; p=p+1) begin : monitor_deadtime
        time last_hi_fall = 0, last_lo_fall = 0;
        always @(negedge gate_hi[p]) last_hi_fall = $time;
        always @(negedge gate_lo[p]) last_lo_fall = $time;
        always @(posedge gate_hi[p]) begin
            if ($time > 0 && ($time-last_lo_fall) < DEAD_CYCLES*CLK_NS)
                $fatal(1, "High-side deadtime too short, phase %0d", p);
        end
        always @(posedge gate_lo[p]) begin
            if ($time > 0 && ($time-last_hi_fall) < DEAD_CYCLES*CLK_NS)
                $fatal(1, "Low-side deadtime too short, phase %0d", p);
        end
    end endgenerate

    task wait_cycles(input integer count);
        repeat(count) @(negedge clk);
    endtask
    task send_duties(input integer a, b, c);
        @(negedge clk);
        duty_a = a; duty_b = b; duty_c = c; duty_valid = 1;
        @(negedge clk); duty_valid = 0;
    endtask
    task acknowledge;
        @(negedge clk); enable = 0; fault_ack = 1;
        @(negedge clk); fault_ack = 0;
        #1;
        if (fault_latched) $fatal(1, "Fault acknowledgement failed");
    endtask
    task count_frame;
        ca=0; cb=0; cc=0; la=0; lb=0; lc=0;
        for(k=0;k<PERIOD_TICKS;k=k+1) begin
            @(negedge clk);
            ca=ca+gate_hi[0]; cb=cb+gate_hi[1]; cc=cc+gate_hi[2];
            la=la+gate_lo[0]; lb=lb+gate_lo[1]; lc=lc+gate_lo[2];
        end
    endtask

    initial begin
        $dumpfile("waveforms.vcd"); $dumpvars(0,tb_three_phase_pwm);
        wait_cycles(5); rst_n = 1;
        wait_cycles(2);
        if (!fault_latched || {gate_hi,gate_lo} !== 0)
            $fatal(1, "Reset must leave outputs inhibited");
        checks=checks+1;
        acknowledge();
        send_duties(HALF_TICKS/5, HALF_TICKS/2, 4*HALF_TICKS/5);
        wait_cycles(2*PERIOD_TICKS);
        @(negedge clk); enable = 1;
        wait_cycles(3*PERIOD_TICKS);
        count_frame();
        // Triangle has one zero sample and two samples of each level 1..H-1.
        if (ca != 2*(HALF_TICKS/5)-1-DEAD_CYCLES ||
            cb != 2*(HALF_TICKS/2)-1-DEAD_CYCLES ||
            cc != 2*(4*HALF_TICKS/5)-1-DEAD_CYCLES)
            $fatal(1,"Unexpected duty counts: %0d %0d %0d",ca,cb,cc);
        if (ca+la != PERIOD_TICKS-2*DEAD_CYCLES ||
            cb+lb != PERIOD_TICKS-2*DEAD_CYCLES ||
            cc+lc != PERIOD_TICKS-2*DEAD_CYCLES)
            $fatal(1,"Wrong accumulated deadtime");
        checks=checks+1;
        $display("PASS: A/B/C pulse widths, PWM period, accumulated deadtime");

        // Update all three phases between carrier boundaries.
        send_duties(HALF_TICKS/3, 2*HALF_TICKS/3, HALF_TICKS/2);
        wait_cycles(2*PERIOD_TICKS);
        if (dut.active_a != HALF_TICKS/3 || dut.active_b != 2*HALF_TICKS/3 ||
            dut.active_c != HALF_TICKS/2) $fatal(1,"Atomic duty update failed");
        checks=checks+1;

        // 120-degree sinusoidal commands are TEST STIMULUS, not APF control.
        for(n=0;n<24;n=n+1) begin
            angle = 6.283185307179586*n/24.0;
            send_duties($rtoi(HALF_TICKS*(0.5+0.3*$sin(angle))),
                        $rtoi(HALF_TICKS*(0.5+0.3*$sin(angle-2.094395102393195))),
                        $rtoi(HALF_TICKS*(0.5+0.3*$sin(angle+2.094395102393195))));
            wait_cycles(PERIOD_TICKS-2);
        end
        checks=checks+1;
        $display("PASS: three-phase dynamic commands and boundary updates");

        send_duties(0, HALF_TICKS, HALF_TICKS/2);
        wait_cycles(3*PERIOD_TICKS); count_frame();
        if(ca!=0 || la!=PERIOD_TICKS || cb!=PERIOD_TICKS || lb!=0)
            $fatal(1,"0/100 percent endpoints failed");
        checks=checks+1;

        // Fault is deliberately asserted away from a clock edge.
        #(CLK_NS/3); fault_active=1; #1;
        if({gate_hi,gate_lo} !== 0 || !fault_latched)
            $fatal(1,"Asynchronous fault did not inhibit outputs");
        wait_cycles(3); fault_active=0; wait_cycles(3);
        if(!fault_latched || {gate_hi,gate_lo} !== 0)
            $fatal(1,"Fault did not latch");
        fault_ack=1; wait_cycles(2); fault_ack=0;
        if(!fault_latched) $fatal(1,"Acknowledgement accepted while enabled");
        checks=checks+1;
        acknowledge(); enable=1; wait_cycles(2*PERIOD_TICKS);
        checks=checks+1;
        $display("PASS: async fault, latching, inhibited ack, recovery");

        // Above-range duty must latch a fault.
        send_duties(HALF_TICKS+1, HALF_TICKS/2, HALF_TICKS/2);
        if(!fault_latched || {gate_hi,gate_lo} !== 0)
            $fatal(1,"Invalid duty did not latch a fault");
        checks=checks+1;
        acknowledge();
        send_duties(HALF_TICKS/2, HALF_TICKS/2, HALF_TICKS/2);
        wait_cycles(2*PERIOD_TICKS); enable=1; wait_cycles(PERIOD_TICKS);
        @(negedge clk); enable=0; #1;
        if({gate_hi,gate_lo} !== 0) $fatal(1,"Disable failed");
        checks=checks+1;
        $display("PASS: reset, endpoints, invalid command, disable");
        $display("ALL PASS: %0d scenario groups; clk=%0d Hz pwm=%0d Hz dead=%0d cycles",
                 checks,CLK_HZ,PWM_HZ,DEAD_CYCLES);
        $finish;
    end
    initial begin
        #(200*PERIOD_TICKS*CLK_NS);
        $fatal(1,"Simulation timeout");
    end
endmodule
