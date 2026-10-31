// H3: the DE2-115 top level (de2_115_top_H3) in Questa, driven like the board:
// KEY0 and the switches in, the LEDs and the 7-segment displays read back.
// Demo sequence:
//   0        KEY0 pressed and released (reset)
//   10 ms    SW0 up: run, the filter starts
//   0.60 s   SW4..SW3 = 01, 10, 11 (frequency, peak current, shoot-through), then 00 (THD) at 0.63 s
//   0.70 s   SW1 up: load 33 -> 22 ohm
//   0.85 s   SW0 down: filter off (the THD reading of 0.9-1.0 s is all filter off)
//   1.10 s   KEY0 pressed for 1 ms: reset
// Prints what the board shows every 50 ms and checks it. Writes the samples the
// THD meter takes and its readings for matlab/board_check_H3.m (bit-exact check).
// Shorter reset, debounce and refresh times than on the board, so the 1.12 s run
// stays about 12 minutes (1.13 s of board time).
//
//   vsim -c work.tb_de2_115_H3 -do "run -all; quit -f"
`timescale 1ns/1ps
module tb_de2_115_H3;
    logic CLOCK_50 = 0;
    always #10 CLOCK_50 = ~CLOCK_50;
    logic [3:0]  KEY = 4'b1111;
    logic [17:0] SW = '0;
    logic [8:0]  LEDG;
    logic [17:0] LEDR;
    logic [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7;

    de2_115_top_H3 #(.COS_FILE("rtl/cos_table_4096.hex"), .THD_TABLE_FILE("rtl/thd_table_200.hex"),
                     .RESET_CLKS(100), .DEBOUNCE_CLKS(1000), .REFRESH(50_000)) dut (.*);

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

    // ---- the meter's samples and readings, until the reset at 1.10 s ----
    int fs, fr;
    bit logging = 1;
    always @(posedge CLOCK_50) if (logging && fs != 0 && dut.rst_n) begin    // in reset, adc_start is high every clock
        if (dut.sys.meter.sample_en) $fwrite(fs, "%0d\n", dut.sys.meter.sample);
        if (dut.sys.thd_done) $fwrite(fr, "%.4f %0d %0d %0d\n", t, dut.sys.thd, dut.sys.thd_valid, dut.sys.peak_run);   // peak_run: the peak being published
    end

    // ---- checks ----
    int fails = 0;
    task automatic check(input string what, input bit ok);
        $display("  %-62s %s", what, ok ? "ok" : "FAILED");
        if (!ok) fails++;
    endtask
    function automatic int num(input string s);       // digits of a display group, "_" and blanks skipped
        int v = 0;
        foreach (s[i]) if (s[i] >= "0" && s[i] <= "9") v = v * 10 + (s[i] - "0");
        return v;
    endfunction

    // ---- what the board shows, every 50 ms ----
    initial begin
        forever begin
            #50ms;
            $display("%6.3f s  [%s]  LEDG %b  faults %b  gates %b", t, board(), LEDG[3:0], LEDR[3:0], LEDR[17:12]);
        end
    end

    initial begin
        string s;
        fs = $fopen("sim/out/H3/board_samples.txt", "w");
        fr = $fopen("sim/out/H3/board_readings.txt", "w");
        if (fs == 0 || fr == 0) $fatal(1, "cannot write sim/out/H3");
        $display("  time     HEX7..0       LEDG3..0 = 22ohm, switching, ready, locked");
        KEY[0] = 0; #1us; KEY[0] = 1;
        #10ms;   SW[0] = 1;
        #590ms;  s = board();
        check($sformatf("0.60 s: DC link on the left, 295..305 V        [%s]", s.substr(0, 3)),
              num(s.substr(0, 3)) >= 295 && num(s.substr(0, 3)) <= 305);
        check($sformatf("0.60 s: THD on the right, 3..6 %%             [%s]", s.substr(5, 8)),
              s[6] == "_" && num(s.substr(5, 8)) >= 300 && num(s.substr(5, 8)) <= 600);
        check("0.60 s: LEDG locked, ready, switching on; 22 ohm off", LEDG[3:0] == 4'b0111);
        check("0.60 s: no faults, gate LEDs active", LEDR[3:0] == 0 && LEDR[17:12] != 0);
        SW[4:3] = 2'b01; #10ms; s = board();
        check($sformatf("SW4..3 = 01: PLL frequency 50.0 Hz            [%s]", s.substr(5, 8)), s.substr(5, 8) == "50_0");
        SW[4:3] = 2'b10; #10ms; s = board();
        check($sformatf("SW4..3 = 10: peak grid current 5..9 A         [%s]", s.substr(5, 8)),
              s[6] == "_" && num(s.substr(5, 8)) >= 500 && num(s.substr(5, 8)) <= 900);
        SW[4:3] = 2'b11; #10ms; s = board();
        check($sformatf("SW4..3 = 11: shoot-through count 0            [%s]", s.substr(5, 8)), s.substr(5, 8) == "   0");
        SW[4:3] = 2'b00;
        #70ms;   SW[1] = 1;                                         // 0.70 s
        #100ms;  s = board();
        check("0.80 s: LEDG3 (22 ohm) on, still switching", LEDG[3:0] == 4'b1111);
        #50ms;   SW[0] = 0;                                         // 0.85 s
        #20ms;
        check("0.87 s: filter off: switching LED and gate LEDs off", LEDG[2] == 0 && LEDR[17:12] == 0);
        #225ms;  s = board();                                       // 1.095 s
        check($sformatf("1.095 s: THD with the filter off above 15 %%   [%s]", s.substr(5, 8)),
              s[6] != "_" && num(s.substr(5, 8)) >= 150);
        check("1.095 s: no faults, no shoot-through", LEDR[3:0] == 0 && dut.shoot_count == 0);
        #5ms;    logging = 0; KEY[0] = 0; #1ms; KEY[0] = 1;         // 1.10 s: reset
        #29ms;   s = board();                                       // 1.13 s
        check($sformatf("after reset: LEDG %b (only 22 ohm, SW1 up), DC link 173 V [%s]", LEDG[3:0], s.substr(0, 3)),
              LEDG[3:0] == 4'b1000 && num(s.substr(0, 3)) >= 170 && num(s.substr(0, 3)) <= 176);
        check($sformatf("after reset: no THD reading yet               [%s]", s.substr(5, 8)), s.substr(5, 8) == "----");
        $fclose(fs); $fclose(fr); fs = 0;
        $display("de2_115_top_H3: %0d checks failed -> %s", fails, fails == 0 ? "BOARD TOP OK" : "BOARD TOP CHECK FAILED");
        $finish;
    end
endmodule
