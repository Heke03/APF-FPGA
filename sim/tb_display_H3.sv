// H3: exhaustive check of rtl/display_H3.sv: every reading 0..9999 in every
// format and every DC-link code 0..4095, decoded back from the segments.
//
//   vsim -c work.tb_display_H3 -do "run -all; quit -f"
`timescale 1ns/1ps
module tb_display_H3;
    logic clk = 0, rst_n = 0;
    always #10 clk = ~clk;
    logic [11:0] vdc_avg = '0;
    logic [13:0] value = '0;
    logic [1:0]  fmt = '0;
    logic [6:0]  hex [0:7];
    localparam integer REFRESH = 20;
    display_H3 #(.REFRESH(REFRESH)) dut (.*);

    function automatic byte ch(input logic [6:0] s);
        case (s)
            7'h40: return "0"; 7'h79: return "1"; 7'h24: return "2"; 7'h30: return "3";
            7'h19: return "4"; 7'h12: return "5"; 7'h02: return "6"; 7'h78: return "7";
            7'h00: return "8"; 7'h10: return "9"; 7'h7F: return " "; 7'h77: return "_";
            7'h3F: return "-"; default: return "?";
        endcase
    endfunction
    function automatic string shown(input int lo, input int hi);
        string s = "";
        for (int i = hi; i >= lo; i--) s = {s, string'(ch(hex[i]))};
        return s;
    endfunction

    int errors = 0, checks = 0;
    task automatic settle();                      // next snapshot, 15 clocks of conversion, segments
        repeat (2 * REFRESH + 20) @(posedge clk);
    endtask
    task automatic expect_eq(input string what, input string got, input string want);
        checks++;
        if (got != want) begin
            errors++;
            if (errors <= 10) $display("%s: shows \"%s\", expected \"%s\"", what, got, want);
        end
    endtask

    initial begin
        string want;
        repeat (3) @(posedge clk);
        rst_n = 1;
        for (int f = 0; f < 3; f++)
            for (int v = 0; v <= 9999; v++) begin
                value = v; fmt = f; vdc_avg = v % 4096;
                settle();
                case (f)
                    1: begin
                        automatic int w = (v + 5 > 9999) ? 9999 : v + 5;  // from 10 on: one decimal, rounded
                        want = (v < 1000) ? $sformatf("%0d_%0d%0d", v / 100, v / 10 % 10, v % 10)
                                          : $sformatf("%0d%0d_%0d", w / 1000, w / 100 % 10, w / 10 % 10);
                    end
                    2: want = $sformatf("%4d", v);
                    default: want = "----";
                endcase
                expect_eq($sformatf("reading %0d fmt %0d", v, f), shown(0, 3), want);
                expect_eq($sformatf("vdc code %0d", v % 4096), shown(4, 7), $sformatf("%4d", (v % 4096) / 10));
            end
        $display("display_H3: %0d checks, %0d wrong -> %s", checks, errors, errors == 0 ? "PASS" : "FAIL");
        $finish;
    end
endmodule
