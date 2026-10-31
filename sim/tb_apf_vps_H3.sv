// H3: the whole board design in closed loop - apf_core (real RTL) driving the
// virtual power stage (real RTL), with the ADC stand-in between them. This is
// what will run on the DE2-115; the testbench only provides the clock, the
// operator's run request (10 ms) and the load step (0.7 s), and logs a CSV in
// the same format as tb_apf_system.sv.
//
//   vsim -c work.tb_apf_vps_H3 +CSV=sim/out/H3/apf_vps.csv -do "run -all; quit -f"
//   options: +T_END=<s> (default 1.0), +NOISE=0 (ADC noise off; default on)
`timescale 1ns/1ps
module tb_apf_vps_H3;
    real T_END = 1.0;
    localparam real RUN_TIME  = 0.01;
    localparam real STEP_TIME = 0.7;
    localparam integer LOG_CYCLES = 500;    // 10 us

    logic clk = 0, rst_n = 0, run_request = 0, load_step = 0, noise_en = 1;
    always #10 clk = ~clk;

    // apf_core
    logic adc_valid, adc_start, switching, pll_locked, compensating_ready;
    logic [11:0] adc_code [0:6];
    logic [2:0] gate_hi, gate_lo;
    logic [3:0] fault_flags;
    logic [31:0] freq_word;
    logic [11:0] vdc_avg;
    logic signed [15:0] idc_cmd;
    apf_core #(.COS_FILE("rtl/cos_table_4096.hex")) dut (.*);

    // virtual power stage + ADC stand-in
    logic step_done;
    logic signed [23:0] vg [0:2];
    logic signed [31:0] il [0:2], i_inv [0:2];
    logic signed [41:0] vdc;
    logic [11:0] code [0:6];
    logic [31:0] shoot_count;
    virtual_power_stage_H3 #(.COS_FILE("rtl/cos_table_4096.hex")) vps (
        .clk, .rst_n, .gate_hi, .gate_lo, .contactor(switching), .load_step,
        .step_done, .vg, .il, .i_inv, .vdc, .code, .shoot_count);
    vps_adc_H3 adc (.clk, .rst_n, .adc_start, .noise_en, .code_now(code), .adc_valid, .adc_code);

    // ---- time, logging, summary ----
    longint cycles = 0;
    real t;
    always @(posedge clk) cycles <= cycles + 1;
    assign t = cycles * 20e-9;

    int fd, log_count = 0;
    string csv;
    real t_lock = -1, t_ready = -1, t_switch = -1;
    function automatic real volts(input longint q, input int frac);
        return real'(q) / real'(64'd1 << frac);
    endfunction
    always @(posedge clk) begin
        if (pll_locked && t_lock < 0) t_lock = t;
        if (compensating_ready && t_ready < 0) t_ready = t;
        if (switching && t_switch < 0) t_switch = t;
        load_step <= (t >= STEP_TIME);
        if (log_count == LOG_CYCLES - 1) begin
            log_count <= 0;
            if (fd != 0)
                $fwrite(fd, "%.6f,%.3f,%.3f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%0d,%0d,%0d,%0d,%.4f,%0d\n",
                        t, volts(vg[0], 12), volts(vg[1], 12), volts(il[0], 24), volts(il[1], 24),
                        volts(i_inv[0], 24), volts(i_inv[1], 24),
                        volts(il[0], 24) - volts(i_inv[0], 24), volts(il[1], 24) - volts(i_inv[1], 24),
                        volts(vdc, 24), pll_locked, compensating_ready, switching, fault_flags,
                        real'(freq_word) * 10000.0 / 4294967296.0, idc_cmd);
        end else
            log_count <= log_count + 1;
    end

    initial begin
        real v_end;
        int noise;
        if (!$value$plusargs("CSV=%s", csv)) csv = "sim/out/H3/apf_vps.csv";
        void'($value$plusargs("T_END=%f", T_END));
        if ($value$plusargs("NOISE=%d", noise)) noise_en = (noise != 0);
        fd = $fopen(csv, "w");
        if (fd == 0) $fatal(1, "cannot open %s", csv);
        $fwrite(fd, "t,vga,vgb,ila,ilb,ifa,ifb,isa,isb,vdc,locked,ready,switching,faults,freq,idc_cmd\n");
        repeat (5) @(posedge clk);
        rst_n = 1;
        wait (t >= RUN_TIME);
        run_request = 1;
        wait (t >= T_END);
        $fclose(fd);
        fd = 0;
        v_end = volts(vdc, 24);
        $display("PLL locked at %.1f ms, controller ready at %.1f ms, switching from %.1f ms",
                 t_lock * 1e3, t_ready * 1e3, t_switch * 1e3);
        $display("final: Vdc %.1f V, faults %b, switching %0d, shoot-through steps %0d, ADC noise %0d",
                 v_end, fault_flags, switching, shoot_count, noise_en);
        if (shoot_count == 0 && fault_flags == 0 && switching && v_end > 290.0 && v_end < 310.0)
            $display("BOARD DESIGN OK (closed loop on the virtual power stage)");
        else
            $display("BOARD DESIGN CHECK FAILED");
        $finish;
    end
endmodule
