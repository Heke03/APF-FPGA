// Closed-loop system simulation: the real FPGA RTL (apf_core and everything
// under it) drives a virtual power stage modelled here with real numbers.
//
// Virtual hardware (assumed lab-scale values; replace with the team's design):
//   grid      3-phase, 100 V phase peak (122 V line-line rms), 50 Hz, stiff
//   load      6-pulse diode bridge, 20 mH + 33 ohm on the DC side
//             (22 ohm from STEP_TIME: load step); commutation smoothed (0.2 ms)
//   inverter  3-leg VSI, ideal switches + diodes, dead time from the RTL gates,
//             3 mH + 0.1 ohm per phase, 1000 uF DC link precharged to 173 V,
//             connected through a contactor that closes while the gates run
//   ADC       7 channels sampled at the PWM carrier boundary, 20 us conversion,
//             12-bit, small Gaussian noise
// The plant is integrated every 10 clocks (200 ns).
//
//   vsim -c work.tb_apf_system +CSV=sim/out/apf_system.csv -do "run -all; quit -f"
`timescale 1ns/1ps
module tb_apf_system;
    // ---- simulation control ----
    real T_END = 1.0;                      // s (override with +T_END=<s>)
    localparam real RUN_TIME   = 0.01;     // operator presses "run"
    localparam real STEP_TIME  = 0.7;      // load step
    localparam real LOG_EVERY  = 10e-6;    // CSV row interval

    // ---- virtual power stage ----
    localparam real PI     = 3.14159265358979;
    localparam real VM     = 100.0;
    localparam real FGRID  = 50.0;
    localparam real LF     = 3e-3,  RF = 0.1;
    localparam real CDC    = 1000e-6, RLEAK = 20e3;
    localparam real LDC    = 20e-3;
    localparam real R1     = 33.0, R2 = 22.0;
    localparam real TAU_COMM = 0.2e-3;
    localparam real H      = 200e-9;
    localparam integer SUB = 10;           // clocks per plant step

    // ---- sensors / ADC scaling (must match apf_core) ----
    localparam real KV = 16.0, KI = 100.0, KDC = 10.0;
    localparam integer CONV_CYCLES = 1000; // 20 us

    logic clk = 0, rst_n = 0, run_request = 0;
    logic adc_valid = 0;
    logic [11:0] adc_code [0:6];
    logic adc_start, switching, pll_locked, compensating_ready;
    logic [2:0] gate_hi, gate_lo;
    logic [3:0] fault_flags;
    logic [31:0] freq_word;
    logic [11:0] vdc_avg;
    logic signed [15:0] idc_cmd;

    always #10 clk = ~clk;

    apf_core #(.COS_FILE("rtl/cos_table_4096.hex")) dut (.*);

    // ---- plant state ----
    real t = 0.0;
    real vg [0:2];
    real i_f [0:2];     // inverter -> grid
    real i_l [0:2];     // grid -> load
    real vdc = 173.2;
    real i_dcl = 0.0;   // load DC current
    real rload = R1;
    real is_a = 0.0, is_b = 0.0;   // grid currents (load - inverter), for the wave window
    real f_pll = 50.0;             // PLL frequency in Hz, for the wave window
    int shoot_through = 0;
    int seed = 12345;

    initial begin
        for (int p = 0; p < 3; p++) begin i_f[p] = 0; i_l[p] = 0; vg[p] = 0; end
        for (int ch = 0; ch < 7; ch++) adc_code[ch] = 12'd2048;
    end

    function automatic real leg_voltage(input logic hi, input logic lo, input real i_out, input real v_dc);
        if (hi) return v_dc;
        if (lo) return 0.0;
        return (i_out > 0.0) ? 0.0 : v_dc;   // dead time: a diode carries the current
    endfunction

    int sub = 0;
    always @(posedge clk) begin
        if (sub == SUB - 1) begin
            real vx [0:2];
            real vn, top_current, vmax, vmin, target;
            sub <= 0;
            t = t + H;
            for (int p = 0; p < 3; p++)
                vg[p] = VM * $cos(2.0 * PI * FGRID * t - 2.0 * PI * p / 3.0);
            rload = (t >= STEP_TIME) ? R2 : R1;

            // Inverter and filter
            if (switching) begin
                top_current = 0.0;
                for (int p = 0; p < 3; p++) begin
                    if (gate_hi[p] && gate_lo[p]) shoot_through++;
                    vx[p] = leg_voltage(gate_hi[p], gate_lo[p], i_f[p], vdc);
                    if (vx[p] > 0.0) top_current += i_f[p];
                end
                vn = (vx[0] + vx[1] + vx[2]) / 3.0;
                for (int p = 0; p < 2; p++)
                    i_f[p] = i_f[p] + H * (vx[p] - vn - vg[p] - RF * i_f[p]) / LF;
                i_f[2] = -(i_f[0] + i_f[1]);
                vdc = vdc + H * (-top_current - vdc / RLEAK) / CDC;
            end else begin
                for (int p = 0; p < 3; p++) begin
                    i_f[p] = 0.0;
                    if (gate_hi[p] || gate_lo[p]) shoot_through++;   // gates must be off
                end
                vdc = vdc - H * vdc / RLEAK / CDC;
            end

            // Diode-bridge load
            vmax = vg[0]; vmin = vg[0];
            for (int p = 1; p < 3; p++) begin
                if (vg[p] > vmax) vmax = vg[p];
                if (vg[p] < vmin) vmin = vg[p];
            end
            i_dcl = i_dcl + H * (vmax - vmin - rload * i_dcl) / LDC;
            if (i_dcl < 0.0) i_dcl = 0.0;
            for (int p = 0; p < 3; p++) begin
                target = (vg[p] == vmax) ? i_dcl : ((vg[p] == vmin) ? -i_dcl : 0.0);
                i_l[p] = i_l[p] + H * (target - i_l[p]) / TAU_COMM;
            end
            is_a = i_l[0] - i_f[0];
            is_b = i_l[1] - i_f[1];
            f_pll = real'(freq_word) * 10000.0 / 4294967296.0;
        end else
            sub <= sub + 1;
    end

    // ---- display copies for the Questa wave window, refreshed every 5 us ----
    real grid_voltage_a = 0.0, load_current_a = 0.0, inverter_current_a = 0.0;
    real grid_current_a = 0.0, dc_link_voltage = 0.0, pll_frequency = 50.0;
    int view_count = 0;
    always @(posedge clk) begin
        if (view_count == 249) begin
            view_count <= 0;
            grid_voltage_a     = vg[0];
            load_current_a     = i_l[0];
            inverter_current_a = i_f[0];
            grid_current_a     = is_a;
            dc_link_voltage    = vdc;
            pll_frequency      = f_pll;
        end else
            view_count <= view_count + 1;
    end
    // ---- ADC: sample at the carrier boundary, deliver after the conversion time ----
    function automatic logic [11:0] quantize(input real x, input real offset, input real gain);
        real c;
        c = offset + gain * x + $dist_normal(seed, 0, 1000) / 1000.0;
        if (c < 0.0) c = 0.0;
        if (c > 4095.0) c = 4095.0;
        return 12'($rtoi(c + 0.5));
    endfunction

    logic [11:0] held [0:6];
    int conv = -1;
    always @(posedge clk) begin
        adc_valid <= 1'b0;
        if (adc_start) begin
            held[0] <= quantize(vg[0], 2048.0, KV);
            held[1] <= quantize(vg[1], 2048.0, KV);
            held[2] <= quantize(i_l[0], 2048.0, KI);
            held[3] <= quantize(i_l[1], 2048.0, KI);
            held[4] <= quantize(i_f[0], 2048.0, KI);
            held[5] <= quantize(i_f[1], 2048.0, KI);
            held[6] <= quantize(vdc, 0.0, KDC);
            conv <= CONV_CYCLES;
        end else if (conv > 0)
            conv <= conv - 1;
        else if (conv == 0) begin
            for (int ch = 0; ch < 7; ch++) adc_code[ch] <= held[ch];
            adc_valid <= 1'b1;
            conv <= -1;
        end
    end

    // ---- optional per-frame controller trace (+DEBUG=<file>) ----
    int dbg = 0;
    string dbg_name;
    always @(posedge clk)
        if (dbg != 0 && dut.ctrl.state == dut.ctrl.FINISH)
            $fwrite(dbg, "%.6f,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n", t,
                    dut.ctrl.if_q[0], dut.ctrl.i_pred[0], dut.ctrl.u_prev[0], dut.ctrl.vg_q[0], dut.ctrl.dv[0],
                    dut.ctrl.rp[0], dut.ctrl.u[0], dut.ctrl.raw_n[0], dut.ctrl.scale, dut.ctrl.vdc16,
                    dut.ctrl.ref_a_q, dut.idc_cmd, dut.ctrl.u[1], dut.ctrl.u[2],
                    dut.ctrl.raw_n[1], dut.ctrl.raw_n[2], dut.ctrl.duty_a, dut.ctrl.vdc_target);

    // ---- logging and run control ----
    int fd;
    string csv;
    real next_log = 0.0;
    int lock_seen = 0, run_seen = 0;
    real t_lock = -1, t_ready = -1, t_switch = -1;

    always @(posedge clk) begin
        if (pll_locked && t_lock < 0) t_lock = t;
        if (compensating_ready && t_ready < 0) t_ready = t;
        if (switching && t_switch < 0) t_switch = t;
        if (fd != 0 && t >= next_log) begin
            next_log = next_log + LOG_EVERY;
            $fwrite(fd, "%.6f,%.3f,%.3f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%0d,%0d,%0d,%0d,%.4f,%0d\n",
                    t, vg[0], vg[1], i_l[0], i_l[1], i_f[0], i_f[1],
                    i_l[0] - i_f[0], i_l[1] - i_f[1], vdc,
                    pll_locked, compensating_ready, switching, fault_flags,
                    real'(freq_word) * 10000.0 / 4294967296.0, idc_cmd);
        end
    end

    initial begin
        if (!$value$plusargs("CSV=%s", csv)) csv = "sim/out/apf_system.csv";
        void'($value$plusargs("T_END=%f", T_END));
        if ($value$plusargs("DEBUG=%s", dbg_name)) begin
            dbg = $fopen(dbg_name, "w");
            $fwrite(dbg, "t,if_meas,i_pred,u_prev,vg,dv,rp,u,raw,scale,vdc16,ref,idc,u_b,u_c,raw_b,raw_c,duty_a,vdc_target\n");
        end
        fd = $fopen(csv, "w");
        if (fd == 0) $fatal(1, "cannot open %s", csv);
        $fwrite(fd, "t,vga,vgb,ila,ilb,ifa,ifb,isa,isb,vdc,locked,ready,switching,faults,freq,idc_cmd\n");
        repeat (5) @(posedge clk);
        rst_n = 1;
        wait (t >= RUN_TIME);
        run_request = 1;
        wait (t >= T_END);
        $fclose(fd);
        $display("PLL locked at %.1f ms, controller ready at %.1f ms, switching from %.1f ms",
                 t_lock * 1e3, t_ready * 1e3, t_switch * 1e3);
        $display("final: Vdc %.1f V (cycle average %0d counts), faults %b, switching %0d, shoot-through samples %0d",
                 vdc, vdc_avg, fault_flags, switching, shoot_through);
        if (shoot_through == 0 && fault_flags == 0 && switching && vdc > 290.0 && vdc < 310.0)
            $display("SYSTEM OK (run model/analyze_system.py for THD and plots)");
        else
            $display("SYSTEM CHECK FAILED");
        $finish;
    end
endmodule
