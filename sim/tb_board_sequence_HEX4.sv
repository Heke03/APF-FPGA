// HEX4: the board design exactly as it goes on the DE2-115 (every parameter at its
// board value: 20 ms reset, 10 ms debounce, 0.2 s display refresh, full recording of
// 16384 samples), driven with the sequence of the guided board test run_board_HEX4:
//
//   power-up   no KEY0 press: the reset comes from the power-up values, as on the board
//   1.0 s      SW0 up: filter on            -> recording 1, read at 1.87 s
//   2.0 s      KEY1 held 100 ms: new recording
//   2.5 s      SW1 up: load 33 -> 22 ohm    -> recording 2, read at 3.37 s
//   3.4 s      KEY1 held 100 ms: new recording
//   3.9 s      SW0 down: filter off         -> recording 3, read at 4.77 s
//
// The H3 test used a recording of 4096 samples, so the real 16384 samples and the
// wrap of the ring (more samples than fit before the stop) run here for the first time.
// Writes the recordings in the format of quartus/read_capture_HEX4.tcl, into
// sim/out/HEX4/rec1_sw0_up, rec2_sw1_up, rec3_sw0_down. About 50 minutes.
`timescale 1ns/1ps
module tb_board_sequence_HEX4;
    logic CLOCK_50 = 0;
    always #10 CLOCK_50 = ~CLOCK_50;
    logic [3:0]  KEY = 4'b1111;
    logic [17:0] SW = '0;
    logic [8:0]  LEDG;
    logic [17:0] LEDR;
    logic [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7;

    de2_115_top_H3 #(.COS_FILE("rtl/cos_table_4096.hex"), .THD_TABLE_FILE("rtl/thd_table_200.hex")) dut (.*);

    localparam int DEPTH = 16384;
    task automatic dump_capture(input string dir);
        int fd;
        fd = $fopen({dir, "/IG.txt"}, "w");
        if (fd == 0) $fatal(1, "cannot write %s (make the folder first)", dir);
        for (int i = 0; i < DEPTH; i++) $fwrite(fd, "%04X\n", dut.cap.g_mem[0].mem.m_default.altsyncram_inst.mem_data[i]);
        $fclose(fd);
        fd = $fopen({dir, "/IL.txt"}, "w"); for (int i = 0; i < DEPTH; i++) $fwrite(fd, "%04X\n", dut.cap.g_mem[1].mem.m_default.altsyncram_inst.mem_data[i]); $fclose(fd);
        fd = $fopen({dir, "/II.txt"}, "w"); for (int i = 0; i < DEPTH; i++) $fwrite(fd, "%04X\n", dut.cap.g_mem[2].mem.m_default.altsyncram_inst.mem_data[i]); $fclose(fd);
        fd = $fopen({dir, "/VD.txt"}, "w"); for (int i = 0; i < DEPTH; i++) $fwrite(fd, "%04X\n", dut.cap.g_mem[3].mem.m_default.altsyncram_inst.mem_data[i]); $fclose(fd);
        fd = $fopen({dir, "/VG.txt"}, "w"); for (int i = 0; i < DEPTH; i++) $fwrite(fd, "%04X\n", dut.cap.g_mem[4].mem.m_default.altsyncram_inst.mem_data[i]); $fclose(fd);
        fd = $fopen({dir, "/INF.txt"}, "w"); for (int i = 0; i < 8; i++) $fwrite(fd, "%08X\n", dut.cap.info_mem.m_default.altsyncram_inst.mem_data[i]); $fclose(fd);
    endtask

    longint cycles = 0;
    real t;
    always @(posedge CLOCK_50) cycles <= cycles + 1;
    assign t = cycles * 20e-9;

    function automatic byte ch(input logic [6:0] s);
        case (s)
            7'h40: return "0"; 7'h79: return "1"; 7'h24: return "2"; 7'h30: return "3";
            7'h19: return "4"; 7'h12: return "5"; 7'h02: return "6"; 7'h78: return "7";
            7'h00: return "8"; 7'h10: return "9"; 7'h7F: return " "; 7'h77: return "_";
            7'h3F: return "-"; default: return "?";
        endcase
    endfunction
    function automatic string board();
        return $sformatf("%s%s%s%s %s%s%s%s", ch(HEX7), ch(HEX6), ch(HEX5), ch(HEX4),
                         ch(HEX3), ch(HEX2), ch(HEX1), ch(HEX0));
    endfunction
    function automatic int num(input string s);       // digits of a display group, "_" and blanks skipped
        int v = 0;
        foreach (s[i]) if (s[i] >= "0" && s[i] <= "9") v = v * 10 + (s[i] - "0");
        return v;
    endfunction

    int fails = 0;
    task automatic check(input string what, input bit ok);
        $display("  %6.3f s  %-66s %s", t, what, ok ? "ok" : "FAILED");
        if (!ok) fails++;
    endtask

    // what the board shows, every 100 ms (the table in the board test README comes from this)
    initial forever begin
        #100ms;
        $display("%6.3f s  [%s]  LEDG8 %b  LEDG3..0 %b  faults %b  gates %b", t, board(), LEDG[8], LEDG[3:0], LEDR[3:0], LEDR[17:12]);
    end

    initial begin
        string s;
        #900ms; s = board();                                      // 0.90 s: filter off, before SW0
        check($sformatf("filter off: DC link 165..180 V               [%s]", s.substr(0, 3)),
              num(s.substr(0, 3)) >= 165 && num(s.substr(0, 3)) <= 180);
        check($sformatf("filter off: THD above 20 %%                   [%s]", s.substr(5, 8)),
              s[6] != "_" && num(s.substr(5, 8)) >= 200);
        check("filter off: PLL locked, not switching, no faults", LEDG[0] && !LEDG[2] && LEDR[3:0] == 0);
        check("LEDG8 off: no switch flipped yet", !LEDG[8]);
        #100ms;  SW[0] = 1;                                       // 1.00 s
        #810ms;  check("0.81 s after SW0: LEDG8 still off", !LEDG[8]);
        #60ms;   check("0.87 s after SW0: LEDG8 on: recording 1 ready", LEDG[8]);   // 1.87 s
        dump_capture("sim/out/HEX4/rec1_sw0_up");
        #130ms;                                                   // 2.00 s
        s = board();
        check($sformatf("filter on: DC link 285..310 V                [%s]", s.substr(0, 3)),
              num(s.substr(0, 3)) >= 285 && num(s.substr(0, 3)) <= 310);
        check("filter on: locked, ready, switching, no faults", LEDG[2:0] == 3'b111 && LEDR[3:0] == 0);
        KEY[1] = 0; #100ms; KEY[1] = 1;                           // 2.10 s, as long as a finger
        #50ms;   check("KEY1: LEDG8 off, recording again", !LEDG[8]);
        #150ms;  s = board();                                     // 2.30 s
        check($sformatf("steady 33 ohm: DC link 295..305 V            [%s]", s.substr(0, 3)),
              num(s.substr(0, 3)) >= 295 && num(s.substr(0, 3)) <= 305);
        check($sformatf("steady 33 ohm: THD 3..6 %%                    [%s]", s.substr(5, 8)),
              s[6] == "_" && num(s.substr(5, 8)) >= 300 && num(s.substr(5, 8)) <= 600);
        #200ms;  SW[1] = 1;                                       // 2.50 s
        #100ms;  check("SW1: LEDG3 (22 ohm) on, still switching", LEDG[3] && LEDG[2]);
        #770ms;  check("0.87 s after SW1: LEDG8 on: recording 2 ready", LEDG[8]);   // 3.37 s
        dump_capture("sim/out/HEX4/rec2_sw1_up");
        s = board();
        check($sformatf("steady 22 ohm: THD 2.5..5 %%                  [%s]", s.substr(5, 8)),
              s[6] == "_" && num(s.substr(5, 8)) >= 250 && num(s.substr(5, 8)) <= 500);
        #30ms;   KEY[1] = 0; #100ms; KEY[1] = 1;                  // 3.50 s
        #400ms;  SW[0] = 0;                                       // 3.90 s
        #50ms;   check("SW0 down: switching LED and gate LEDs off", !LEDG[2] && LEDR[17:12] == 0);
        #820ms;  check("0.87 s after SW0 down: LEDG8 on: recording 3 ready", LEDG[8]);  // 4.77 s
        dump_capture("sim/out/HEX4/rec3_sw0_down");
        s = board();
        check($sformatf("filter off again: THD above 20 %%             [%s]", s.substr(5, 8)),
              s[6] != "_" && num(s.substr(5, 8)) >= 200);
        check("whole run: no faults, no shoot-through", LEDR[3:0] == 0 && dut.shoot_count == 0);
        $display("tb_board_sequence_HEX4: %0d checks failed -> %s", fails, fails == 0 ? "BOARD SEQUENCE OK" : "BOARD SEQUENCE FAILED");
        $finish;
    end
endmodule
