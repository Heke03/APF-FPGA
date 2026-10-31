// H3: bit-exact check of rtl/thd_meter_H3.sv against matlab/thd_meter_H3.m.
// matlab/thd_vectors_H3.m writes the samples (one per line, 2^-24 A) and the
// expected readings (thd valid, one per 1000 samples); this testbench feeds the
// samples 400 clocks apart and compares every reading.
//
//   vsim -c work.tb_thd_meter_H3 -do "run -all; quit -f"
`timescale 1ns/1ps
module tb_thd_meter_H3;
    logic clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    logic sample_en = 0;
    logic signed [31:0] sample = '0;
    logic [13:0] thd;
    logic thd_valid, reading_done;

    thd_meter_H3 #(.TABLE_FILE("rtl/thd_table_200.hex")) dut (.*);

    int fs, fe, readings = 0, errors = 0;
    always @(posedge clk) if (reading_done) begin
        int e_thd, e_valid;
        if ($fscanf(fe, "%d %d\n", e_thd, e_valid) != 2) $fatal(1, "more readings than expected");
        if (thd !== e_thd || thd_valid !== e_valid[0]) begin
            errors++;
            $display("reading %0d: FPGA %0d valid %0d, MATLAB %0d valid %0d", readings + 1, thd, thd_valid, e_thd, e_valid);
        end else
            $display("reading %0d: %0d.%0d%0d %%  valid %0d  ok", readings + 1, thd / 100, thd / 10 % 10, thd % 10, thd_valid);
        readings++;
    end

    initial begin
        automatic int v, n = 0;
        fs = $fopen("sim/out/H3/thd_samples.txt", "r");
        fe = $fopen("sim/out/H3/thd_expected.txt", "r");
        if (fs == 0 || fe == 0) $fatal(1, "run matlab/thd_vectors_H3.m first");
        repeat (5) @(posedge clk);
        rst_n = 1;
        while ($fscanf(fs, "%d\n", v) == 1) begin
            @(posedge clk);
            sample <= v; sample_en <= 1;
            @(posedge clk);
            sample_en <= 0;
            repeat (398) @(posedge clk);
            n++;
        end
        repeat (1000) @(posedge clk);
        $display("thd_meter_H3: %0d samples, %0d readings, %0d mismatches -> %s",
                 n, readings, errors, (errors == 0 && readings == n / 1000) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
