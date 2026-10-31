// H3: bit-exact check of rtl/virtual_power_stage_H3.sv against the MATLAB
// fixed-point reference. matlab/vps_vectors_H3.m writes one line per plant step
// (inputs, then every expected output); this testbench applies the inputs and
// compares all outputs after every step.
//
//   vsim -c work.tb_vps_H3 +VEC=sim/out/H3/vps_vectors.txt -do "run -all; quit -f"
`timescale 1ns/1ps
module tb_vps_H3;
    logic clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    logic [2:0] gate_hi = '0, gate_lo = '0;
    logic contactor = 0, load_step = 0;
    logic step_done;
    logic signed [23:0] vg [0:2];
    logic signed [31:0] il [0:2], i_inv [0:2];
    logic signed [41:0] vdc;
    logic [11:0] code [0:6];
    logic [31:0] shoot_count;

    virtual_power_stage_H3 #(.COS_FILE("rtl/cos_table_4096.hex")) dut (.*);

    int fd;
    string vec;
    longint e [0:20];          // one vector line
    int steps = 0, errors = 0;

    function automatic bit read_line();
        int n;
        n = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                    e[0], e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8], e[9], e[10],
                    e[11], e[12], e[13], e[14], e[15], e[16], e[17], e[18], e[19], e[20]);
        return n == 21;
    endfunction

    task automatic apply();
        gate_hi = {e[0][4], e[0][2], e[0][0]};
        gate_lo = {e[0][5], e[0][3], e[0][1]};
        contactor = e[1][0];
        load_step = e[2][0];
    endtask

    task automatic check(input string name, input longint got, input longint want);
        if (got != want) begin
            errors++;
            if (errors <= 10)
                $display("MISMATCH step %0d (t = %.4f ms) %s: FPGA %0d, MATLAB %0d", steps,
                         steps * 200e-6, name, got, want);
        end
    endtask

    always @(negedge clk) begin
        if (rst_n && step_done) begin
            steps++;
            for (int p = 0; p < 3; p++) begin
                check($sformatf("vg[%0d]", p), vg[p], e[3 + p]);
                check($sformatf("il[%0d]", p), il[p], e[6 + p]);
                check($sformatf("i_inv[%0d]", p), i_inv[p], e[9 + p]);
            end
            check("vdc", vdc, e[12]);
            for (int ch = 0; ch < 7; ch++) check($sformatf("code[%0d]", ch), code[ch], e[13 + ch]);
            check("shoot_count", shoot_count, e[20]);
            if (!read_line()) begin
                $display("VPS BIT-EXACT CHECK: %0d steps, %0d mismatches -> %s", steps, errors,
                         (errors == 0 && steps > 0) ? "PASS" : "FAIL");
                $fclose(fd);
                $finish;
            end
            apply();
        end
    end

    initial begin
        if (!$value$plusargs("VEC=%s", vec)) vec = "sim/out/H3/vps_vectors.txt";
        fd = $fopen(vec, "r");
        if (fd == 0) $fatal(1, "cannot open %s (run matlab/vps_vectors_H3.m first)", vec);
        if (!read_line()) $fatal(1, "empty vector file");
        apply();
        repeat (3) @(negedge clk);
        rst_n = 1;
    end
endmodule
