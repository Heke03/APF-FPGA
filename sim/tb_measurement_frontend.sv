`timescale 1ns/1ps
module tb_measurement_frontend;
    localparam integer CLK_HZ = 50_000_000;
    localparam integer PWM_HZ = 10_000;
    localparam integer DEAD_CYCLES = 100;
    localparam integer TIMEOUT_CYCLES = 5000; // 100 us at the example clock
    localparam integer OFFSET_A = 2048, OFFSET_B = 2056, OFFSET_C = 2040;
    localparam integer CODE_MIN = 16, CODE_MAX = 4079;
    localparam integer SAMPLE_CYCLES = 1000; // 50 kframes/s for this demo
    reg clk = 0, rst_n = 0;
    reg frame_valid = 0;
    reg [11:0] adc_a = 2048, adc_b = 2056, adc_c = 2040;
    wire signed [12:0] sample_a, sample_b, sample_c;
    wire sample_valid, measurement_ready, range_fault, stale_fault;
    reg enable = 0, external_fault = 0, fault_ack = 0, duty_valid = 0;
    reg [15:0] duty_a = 500, duty_b = 1250, duty_c = 2000;
    wire [2:0] gate_hi, gate_lo;
    wire pwm_fault_latched, frame_start;
    wire measurement_inhibit = !measurement_ready;
    integer groups = 0;
    integer expected_a, expected_b, expected_c;
    integer keep_a, keep_b, keep_c, n, j;
    integer hi_a_seen = 0, hi_b_seen = 0, hi_c_seen = 0;
    integer lo_a_seen = 0, lo_b_seen = 0, lo_c_seen = 0;
    integer hi_before, lo_before;
    real theta;
    always #10 clk = !clk;

    measurement_frontend #(.OFFSET_A(OFFSET_A), .OFFSET_B(OFFSET_B),
        .OFFSET_C(OFFSET_C), .CODE_MIN(CODE_MIN), .CODE_MAX(CODE_MAX),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES)) measurements (
        .clk(clk), .rst_n(rst_n), .frame_valid(frame_valid),
        .adc_a(adc_a), .adc_b(adc_b), .adc_c(adc_c),
        .sample_a(sample_a), .sample_b(sample_b), .sample_c(sample_c),
        .sample_valid(sample_valid), .measurement_ready(measurement_ready),
        .range_fault(range_fault), .stale_fault(stale_fault)
    );
    // Demonstrates measurement-loss inhibition only. Fixed duties are test
    // commands and are NOT calculated from these simulated phase currents.
    three_phase_pwm #(.CLK_HZ(CLK_HZ), .PWM_HZ(PWM_HZ),
        .DEAD_CYCLES(DEAD_CYCLES)) pwm (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .fault_active(external_fault | measurement_inhibit), .fault_ack(fault_ack),
        .duty_valid(duty_valid), .duty_a(duty_a), .duty_b(duty_b), .duty_c(duty_c),
        .gate_hi(gate_hi), .gate_lo(gate_lo),
        .fault_latched(pwm_fault_latched), .frame_start(frame_start)
    );

    // Independent continuous integration invariants.
    always @(posedge clk) begin
        #2;
        if (rst_n) begin
            if ($isunknown({sample_a, sample_b, sample_c, sample_valid,
                measurement_ready, range_fault, stale_fault, gate_hi, gate_lo,
                pwm_fault_latched}))
                $fatal(1, "Unknown measurement or gate state after reset");
            if ((gate_hi & gate_lo) !== 3'b000)
                $fatal(1, "Complementary outputs overlap");
            if ((!measurement_ready || pwm_fault_latched || !enable ||
                 external_fault) && {gate_hi, gate_lo} !== 6'b000000)
                $fatal(1, "PWM active while inhibited");
            if (sample_valid && !measurement_ready)
                $fatal(1, "Accepted sample without readiness");
            hi_a_seen = hi_a_seen + gate_hi[0];
            hi_b_seen = hi_b_seen + gate_hi[1];
            hi_c_seen = hi_c_seen + gate_hi[2];
            lo_a_seen = lo_a_seen + gate_lo[0];
            lo_b_seen = lo_b_seen + gate_lo[1];
            lo_c_seen = lo_c_seen + gate_lo[2];
        end
    end

    genvar p;
    generate for (p=0; p<3; p=p+1) begin : check_deadtime
        time hi_fell = 0, lo_fell = 0;
        always @(negedge gate_hi[p]) hi_fell = $time;
        always @(negedge gate_lo[p]) lo_fell = $time;
        always @(posedge gate_hi[p])
            if ($time > 0 && $time-lo_fell < DEAD_CYCLES*20)
                $fatal(1, "High-side dead time violation on phase %0d", p);
        always @(posedge gate_lo[p])
            if ($time > 0 && $time-hi_fell < DEAD_CYCLES*20)
                $fatal(1, "Low-side dead time violation on phase %0d", p);
    end endgenerate

    task automatic passed(input string message);
        groups = groups + 1;
        $display("PASS %0d: %s", groups, message);
    endtask
    task automatic idle_cycles(input integer cycles);
        integer k;
        for (k=0; k<cycles; k=k+1) begin
            @(negedge clk); frame_valid = 0;
            @(posedge clk); #3;
        end
    endtask
    task automatic send_frame(input integer a, b, c);
        @(negedge clk);
        frame_valid = 1; adc_a = a; adc_b = b; adc_c = c;
        @(posedge clk); #3;
    endtask
    task automatic check_frame(input integer a, b, c);
        if (!sample_valid || !measurement_ready || range_fault || stale_fault ||
            $signed(sample_a) != a-OFFSET_A ||
            $signed(sample_b) != b-OFFSET_B ||
            $signed(sample_c) != c-OFFSET_C)
            $fatal(1, "Wrong accepted sample: raw=%0d,%0d,%0d got=%0d,%0d,%0d",
                   a,b,c,$signed(sample_a),$signed(sample_b),$signed(sample_c));
    endtask
    task automatic healthy_frames(input integer frames);
        integer k;
        for (k=0; k<frames; k=k+1) begin
            send_frame(OFFSET_A+100, OFFSET_B-75, OFFSET_C-25);
            check_frame(OFFSET_A+100, OFFSET_B-75, OFFSET_C-25);
            idle_cycles(SAMPLE_CYCLES-1);
        end
    endtask
    task automatic ack_pwm;
        @(negedge clk); frame_valid = 0; fault_ack = 1;
        @(posedge clk); #3;
        @(negedge clk); fault_ack = 0;
        @(posedge clk); #3;
    endtask

    initial begin
        $dumpfile("measurement_demo.vcd");
        // Omit the 50 MHz clock from the VCD to keep the saved trace small.
        $dumpvars(0, adc_a, adc_b, adc_c, sample_a, sample_b, sample_c,
            frame_valid, sample_valid, measurement_ready, range_fault,
            stale_fault, measurement_inhibit, enable, fault_ack,
            pwm_fault_latched, gate_hi, gate_lo);
        idle_cycles(4);
        if (measurement_ready || sample_valid || {gate_hi,gate_lo} !== 0 ||
            !pwm_fault_latched) $fatal(1, "Reset/startup inhibition failed");
        @(negedge clk); rst_n = 1;
        idle_cycles(2);
        if (measurement_ready || sample_valid)
            $fatal(1, "Readiness set before receiving a frame");
        passed("reset and startup inhibit PWM until data and acknowledgement");

        send_frame(OFFSET_A, OFFSET_B, OFFSET_C);
        check_frame(OFFSET_A, OFFSET_B, OFFSET_C);
        passed("individual zero offsets produce three signed zeros");

        send_frame(2248, 1756, 2090); check_frame(2248,1756,2090);
        send_frame(CODE_MIN, CODE_MAX, CODE_MIN);
        check_frame(CODE_MIN, CODE_MAX, CODE_MIN);
        send_frame(CODE_MAX, CODE_MIN, CODE_MAX);
        check_frame(CODE_MAX, CODE_MIN, CODE_MAX);
        passed("signed positive/negative conversion and inclusive range boundaries");

        keep_a = $signed(sample_a); keep_b = $signed(sample_b);
        keep_c = $signed(sample_c);
        for (n=0; n<6; n=n+1) begin
            case (n)
              0: send_frame(CODE_MIN-1, OFFSET_B, OFFSET_C);
              1: send_frame(CODE_MAX+1, OFFSET_B, OFFSET_C);
              2: send_frame(OFFSET_A, 0, OFFSET_C);
              3: send_frame(OFFSET_A, 4095, OFFSET_C);
              4: send_frame(OFFSET_A, OFFSET_B, CODE_MIN-1);
              5: send_frame(OFFSET_A, OFFSET_B, CODE_MAX+1);
            endcase
            if (sample_valid || measurement_ready || !range_fault ||
                $signed(sample_a) != keep_a || $signed(sample_b) != keep_b ||
                $signed(sample_c) != keep_c)
                $fatal(1, "Rejected frame changed accepted values or readiness");
        end
        passed("one bad channel rejects the entire frame and holds prior values");

        for (n=0; n<64; n=n+1) begin
            expected_a = CODE_MIN + (n*137) % (CODE_MAX-CODE_MIN+1);
            expected_b = CODE_MIN + (n*251+777) % (CODE_MAX-CODE_MIN+1);
            expected_c = CODE_MIN + (n*389+1800) % (CODE_MAX-CODE_MIN+1);
            send_frame(expected_a, expected_b, expected_c);
            check_frame(expected_a, expected_b, expected_c);
        end
        idle_cycles(1);
        if (sample_valid) $fatal(1, "sample_valid persisted without an input frame");
        passed("64 back-to-back frames preserve channel identity and signed arithmetic");

        send_frame(OFFSET_A, OFFSET_B, OFFSET_C);
        idle_cycles(TIMEOUT_CYCLES-1);
        if (stale_fault || !measurement_ready)
            $fatal(1, "Watchdog expired early");
        idle_cycles(1);
        if (!stale_fault || measurement_ready)
            $fatal(1, "Watchdog missed exact expiry boundary");
        passed("missing-data watchdog expires at exactly 5000 missed clock cycles");

        send_frame(OFFSET_A, OFFSET_B, OFFSET_C);
        for (n=0; n<TIMEOUT_CYCLES; n=n+1)
            send_frame(0, OFFSET_B, OFFSET_C);
        if (!stale_fault || !range_fault || measurement_ready)
            $fatal(1, "Invalid frames refreshed watchdog");
        passed("continuous rejected frames cannot hide missing valid data");

        send_frame(OFFSET_A, OFFSET_B, OFFSET_C);
        idle_cycles(TIMEOUT_CYCLES-1);
        send_frame(OFFSET_A+1, OFFSET_B-1, OFFSET_C+2);
        check_frame(OFFSET_A+1, OFFSET_B-1, OFFSET_C+2);
        idle_cycles(TIMEOUT_CYCLES-1);
        if (stale_fault || !measurement_ready)
            $fatal(1, "Deadline frame did not restart watchdog");
        passed("accepted frame on the deadline wins and restarts the watchdog");

        // Start a fresh, readable integration section after the unit scenarios.
        @(negedge clk); rst_n=0; frame_valid=0; enable=0; fault_ack=0;
        idle_cycles(4);
        @(negedge clk); rst_n=1;
        send_frame(OFFSET_A, OFFSET_B, OFFSET_C);
        ack_pwm();
        if (pwm_fault_latched) $fatal(1, "Disabled acknowledgement did not clear PWM");
        @(negedge clk); duty_valid=1;
        @(posedge clk); #3;
        @(negedge clk); duty_valid=0; enable=1;
        // One 50 Hz cycle, 50 kframes/s; all values are arbitrary ADC COUNTS.
        // The 5th harmonic makes these simulated measurements visibly distorted.
        // No reference extraction or current-loop calculation is performed here.
        for (n=0; n<1000; n=n+1) begin
            theta = 6.283185307179586*n/1000.0;
            expected_a = OFFSET_A + $rtoi(600*$sin(theta) + 90*$sin(5*theta));
            expected_b = OFFSET_B + $rtoi(600*$sin(theta-2.094395102393195) +
                                           90*$sin(5*(theta-2.094395102393195)));
            expected_c = OFFSET_C + $rtoi(600*$sin(theta+2.094395102393195) +
                                           90*$sin(5*(theta+2.094395102393195)));
            send_frame(expected_a,expected_b,expected_c);
            check_frame(expected_a,expected_b,expected_c);
            idle_cycles(SAMPLE_CYCLES-1);
        end
        if (hi_a_seen==0 || hi_b_seen==0 || hi_c_seen==0 ||
            lo_a_seen==0 || lo_b_seen==0 || lo_c_seen==0 || pwm_fault_latched)
            $fatal(1, "PWM did not switch with healthy measurement stream");
        passed("1000 three-phase distorted measurement frames and all six PWM outputs active");

        idle_cycles(TIMEOUT_CYCLES+2);
        if (!stale_fault || measurement_ready || !pwm_fault_latched ||
            {gate_hi,gate_lo} !== 0)
            $fatal(1, "Missing data did not shut PWM down");
        @(negedge clk); enable=0;
        ack_pwm();
        if (!pwm_fault_latched || {gate_hi,gate_lo} !== 0)
            $fatal(1, "PWM acknowledged while measurements were still invalid");
        @(negedge clk); enable=1;
        passed("missing data latches PWM shutdown and blocks acknowledgement while invalid");

        send_frame(OFFSET_A,OFFSET_B,OFFSET_C);
        check_frame(OFFSET_A,OFFSET_B,OFFSET_C);
        if (!pwm_fault_latched || {gate_hi,gate_lo} !== 0)
            $fatal(1, "Returning measurements restarted PWM without acknowledgement");
        ack_pwm(); // enable is still high: acknowledgement MUST be refused.
        if (!pwm_fault_latched || {gate_hi,gate_lo} !== 0)
            $fatal(1, "Acknowledgement accepted while run request was high");
        passed("data recovery alone and enabled acknowledgement cannot restart PWM");

        @(negedge clk); enable=0;
        ack_pwm();
        if (pwm_fault_latched) $fatal(1, "Disabled recovery acknowledgement failed");
        hi_before = hi_a_seen + hi_b_seen + hi_c_seen;
        lo_before = lo_a_seen + lo_b_seen + lo_c_seen;
        @(negedge clk); enable=1;
        healthy_frames(20);
        if (pwm_fault_latched || hi_a_seen+hi_b_seen+hi_c_seen <= hi_before ||
            lo_a_seen+lo_b_seen+lo_c_seen <= lo_before)
            $fatal(1, "PWM switching did not restart after the recovery sequence");
        passed("disabled acknowledgement and healthy frames explicitly restore PWM switching");

        send_frame(OFFSET_A,4095,OFFSET_C);
        if (!range_fault || measurement_ready || !pwm_fault_latched ||
            {gate_hi,gate_lo} !== 0)
            $fatal(1, "Out-of-range phase did not inhibit PWM");
        passed("out-of-range measurement shuts down all three inverter legs");
        if (groups != 13) $fatal(1, "Incorrect scenario count");
        $display("ALL PASS: %0d measurement and PWM-inhibition scenario groups", groups);
        $finish;
    end
    initial begin
        #30_000_000;
        $fatal(1,"Measurement simulation timeout");
    end
endmodule
