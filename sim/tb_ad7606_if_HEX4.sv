// HEX4: tests the AD7606 driver against the data-sheet model.
// The good cases run at the corners of the data sheet and must keep every limit and
// deliver every frame bit for bit. The other cases are meant to go wrong: a part that
// misbehaves must set the right fault, and a driver made too fast (a parameter only,
// same code) must be caught by the model, or the checker proves nothing.
//
//   vsim -c work.tb_ad7606_if_HEX4 -do "run -all; quit -f"       about 20 s
`timescale 1ns/1ps

module ad7606_cell_HEX4 #(
    parameter real T_CONV = 4000.0, T14 = 24.0, T10_MIN = 24.0,
    parameter integer RD_LOW_CLKS = 3, CONVST_LOW_CLKS = 3, BUSY_MAX_CLKS = 250,
    parameter bit NO_BUSY = 0, BUSY_STUCK = 0, FRST_WRONG = 0, LATE_START = 0
) (
    input  logic clk, rst_n, frame,
    output int   frames_ok, frames_bad, errors,
    output logic [3:0] fault
);
    logic start = 0, reset, convst, cs_n, rd_n, busy, frstdata, raw_valid, ready;
    logic [15:0] db;
    logic signed [15:0] analog [0:7], held [0:7], raw [0:7];
    int model_frames;
    initial begin frames_ok = 0; frames_bad = 0; end

    ad7606_if_HEX4 #(.RD_LOW_CLKS(RD_LOW_CLKS), .CONVST_LOW_CLKS(CONVST_LOW_CLKS), .BUSY_MAX_CLKS(BUSY_MAX_CLKS)) dut (
        .clk, .rst_n, .start, .clear_faults(1'b0), .ad_reset(reset), .ad_convst(convst), .ad_cs_n(cs_n), .ad_rd_n(rd_n),
        .ad_busy(busy), .ad_frstdata(frstdata), .ad_db(db), .raw, .raw_valid, .ready, .fault);
    ad7606_model_HEX4 #(.T_CONV(T_CONV), .T14(T14), .T10_MIN(T10_MIN), .MAX_PRINT(1)) model (
        .reset, .convst, .cs_n, .rd_n, .busy, .frstdata, .db, .analog,
        .inject_no_busy(NO_BUSY), .inject_busy_stuck(BUSY_STUCK), .inject_frst_wrong(FRST_WRONG),
        .errors, .frames(model_frames), .held);

    // new random values on every channel before each frame
    always @(posedge clk) begin
        start <= frame && ready;
        if (frame) for (int i = 0; i < 8; i++) analog[i] <= 16'($urandom);
    end
    if (LATE_START) begin : g_late
        initial forever begin            // a second start 2 us after each frame
            @(posedge frame); repeat (100) @(posedge clk);
            force start = 1'b1; @(posedge clk); release start;
        end
    end
    always @(posedge clk) if (raw_valid) begin
        automatic bit same = 1;
        for (int i = 0; i < 8; i++) if (raw[i] !== held[i]) same = 0;
        if (same) frames_ok++; else frames_bad++;
    end
endmodule

module tb_ad7606_if_HEX4;
    logic clk = 0, rst_n = 0, frame = 0;
    always #10 clk = ~clk;
    localparam int FRAMES = 20;
    int  ok [0:10], bad [0:10], err [0:10];
    logic [3:0] f [0:10];

    ad7606_cell_HEX4                             c0  (.clk, .rst_n, .frame, .frames_ok(ok[0]),  .frames_bad(bad[0]),  .errors(err[0]),  .fault(f[0]));
    ad7606_cell_HEX4 #(.T_CONV(3450.0))          c1  (.clk, .rst_n, .frame, .frames_ok(ok[1]),  .frames_bad(bad[1]),  .errors(err[1]),  .fault(f[1]));
    ad7606_cell_HEX4 #(.T_CONV(4200.0))          c2  (.clk, .rst_n, .frame, .frames_ok(ok[2]),  .frames_bad(bad[2]),  .errors(err[2]),  .fault(f[2]));
    ad7606_cell_HEX4 #(.T14(30.0), .T10_MIN(30.0)) c3 (.clk, .rst_n, .frame, .frames_ok(ok[3]), .frames_bad(bad[3]),  .errors(err[3]),  .fault(f[3]));
    ad7606_cell_HEX4 #(.RD_LOW_CLKS(1))          c4  (.clk, .rst_n, .frame, .frames_ok(ok[4]),  .frames_bad(bad[4]),  .errors(err[4]),  .fault(f[4]));
    ad7606_cell_HEX4 #(.CONVST_LOW_CLKS(1))      c5  (.clk, .rst_n, .frame, .frames_ok(ok[5]),  .frames_bad(bad[5]),  .errors(err[5]),  .fault(f[5]));
    ad7606_cell_HEX4 #(.BUSY_MAX_CLKS(150))      c6  (.clk, .rst_n, .frame, .frames_ok(ok[6]),  .frames_bad(bad[6]),  .errors(err[6]),  .fault(f[6]));
    ad7606_cell_HEX4 #(.NO_BUSY(1))              c7  (.clk, .rst_n, .frame, .frames_ok(ok[7]),  .frames_bad(bad[7]),  .errors(err[7]),  .fault(f[7]));
    ad7606_cell_HEX4 #(.BUSY_STUCK(1))           c8  (.clk, .rst_n, .frame, .frames_ok(ok[8]),  .frames_bad(bad[8]),  .errors(err[8]),  .fault(f[8]));
    ad7606_cell_HEX4 #(.FRST_WRONG(1))           c9  (.clk, .rst_n, .frame, .frames_ok(ok[9]),  .frames_bad(bad[9]),  .errors(err[9]),  .fault(f[9]));
    ad7606_cell_HEX4 #(.LATE_START(1))           c10 (.clk, .rst_n, .frame, .frames_ok(ok[10]), .frames_bad(bad[10]), .errors(err[10]), .fault(f[10]));

    int fails = 0;
    task automatic check(input string what, input bit good, input int k);
        $display("  %-58s ok %0d  wrong %0d  limits broken %0d  fault %b  %s", what, ok[k], bad[k], err[k], f[k], good ? "PASS" : "FAILED");
        if (!good) fails++;
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (20) @(posedge clk);
        repeat (FRAMES) begin
            @(posedge clk) frame <= 1;
            @(posedge clk) frame <= 0;
            repeat (4998) @(posedge clk);          // 100 us per frame
        end
        // good cases: every frame delivered, right, inside the limits, no fault
        check("typical part",                         ok[0] == FRAMES && bad[0] == 0 && err[0] == 0 && f[0] == 0, 0);
        check("fastest conversion, 3.45 us",          ok[1] == FRAMES && bad[1] == 0 && err[1] == 0 && f[1] == 0, 1);
        check("slowest conversion, 4.2 us",           ok[2] == FRAMES && bad[2] == 0 && err[2] == 0 && f[2] == 0, 2);
        check("slower data, VDRIVE 2.7 V limits",     ok[3] == FRAMES && bad[3] == 0 && err[3] == 0 && f[3] == 0, 3);
        // the checker must catch a driver that breaks the data sheet
        check("driver made too fast: RD low 20 ns, must be caught",  err[4] > 0 || bad[4] > 0, 4);
        check("driver made too fast: CONVST low 20 ns, must be caught", err[5] > 0, 5);
        check("timeout too short for the ADC: BUSY fault",           f[6][1] && ok[6] == 0, 6);
        // a misbehaving part
        check("BUSY never rises: fault, nothing delivered",  f[7][0] && ok[7] == 0, 7);
        check("BUSY stuck high: fault, nothing delivered",   f[8][1] && ok[8] == 0, 8);
        check("FRSTDATA wrong: fault, nothing delivered",    f[9][2] && ok[9] == 0, 9);
        check("start during a conversion: fault",            f[10][3], 10);
        $display("AD7606 DRIVER TEST: %0d failed -> %s", fails, fails == 0 ? "OK" : "FAILED");
        $finish;
    end
endmodule
