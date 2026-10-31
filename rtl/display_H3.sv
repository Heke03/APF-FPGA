`timescale 1ns/1ps
// H3: the eight 7-segment displays of the DE2-115.
//   HEX7..HEX4  DC-link voltage, whole volts       " 301"
//   HEX3..HEX0  one reading, chosen by the top level:
//                 FMT_CENTI  value in 0.01 units   "4_40" (4.40); from 10 on one decimal, rounded:
//                                                  "26_1" (26.06), "50_0" (49.99)
//                 FMT_INT    whole number          "   0"
//                 FMT_NONE   no reading yet        "----"
// The DE2-115 displays have no decimal point (7 segment pins per digit), so the
// decimal point is shown as the bottom bar "_" in its own digit. Segments are
// active low, bit 0 = a (top) ... bit 6 = g (middle), as in the Terasic manual.
// The values are taken every REFRESH clocks so the last digit doesn't flicker.
module display_H3 #(
    parameter integer REFRESH = 10_000_000          // 0.2 s at 50 MHz
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [11:0] vdc_avg,                    // 10 counts/V
    input  logic [13:0] value,                      // 0..9999
    input  logic [1:0]  fmt,
    output logic [6:0]  hex [0:7]                   // hex[0] = HEX0 (rightmost)
);
    localparam logic [1:0] FMT_NONE = 2'd0, FMT_CENTI = 2'd1, FMT_INT = 2'd2;
    localparam logic [6:0] SEG_BLANK = 7'h7F, SEG_BAR = 7'h77, SEG_DASH = 7'h3F;

    function automatic logic [6:0] seg(input logic [3:0] d);
        case (d)
            4'd0: seg = 7'h40;  4'd1: seg = 7'h79;  4'd2: seg = 7'h24;  4'd3: seg = 7'h30;
            4'd4: seg = 7'h19;  4'd5: seg = 7'h12;  4'd6: seg = 7'h02;  4'd7: seg = 7'h78;
            4'd8: seg = 7'h00;  4'd9: seg = 7'h10;  default: seg = SEG_BLANK;
        endcase
    endfunction

    // ---- refresh tick: take a snapshot of the inputs ----
    logic [$clog2(REFRESH)-1:0] tick_cnt;
    logic        tick;
    logic [13:0] vdc_s, value_s;
    logic [1:0]  fmt_s;
    // from 10 on only one decimal is shown: add 5 hundredths so the shown digit is rounded
    wire [14:0] v_round = (fmt == FMT_CENTI && value >= 1000) ? 15'(value) + 15'd5 : 15'(value);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt <= '0; tick <= 1'b0; vdc_s <= '0; value_s <= '0; fmt_s <= FMT_NONE;
        end else begin
            tick <= (tick_cnt == REFRESH - 1);
            tick_cnt <= (tick_cnt == REFRESH - 1) ? '0 : tick_cnt + 1'b1;
            if (tick) begin
                vdc_s <= 14'(vdc_avg); value_s <= (v_round > 9999) ? 14'd9999 : 14'(v_round); fmt_s <= fmt;
            end
        end
    end

    // ---- binary to 4 decimal digits (double dabble, 14 clocks), both numbers ----
    logic [3:0]  bit_cnt;
    logic [13:0] sh_v, sh_x;
    logic [15:0] bcd_v, bcd_x, dig_v, dig_x;        // dig_v: Vdc, dig_x: the reading
    function automatic logic [15:0] add3(input logic [15:0] b);
        for (int i = 0; i < 4; i++)
            if (b[4*i +: 4] >= 5) b[4*i +: 4] = b[4*i +: 4] + 4'd3;
        return b;
    endfunction
    wire [15:0] adj_v = add3(bcd_v), adj_x = add3(bcd_x);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt <= '0; sh_v <= '0; sh_x <= '0; bcd_v <= '0; bcd_x <= '0; dig_v <= '0; dig_x <= '0;
        end else if (bit_cnt == 0) begin
            sh_v <= vdc_s; sh_x <= value_s; bcd_v <= '0; bcd_x <= '0;
            bit_cnt <= 4'd1;
        end else begin
            {bcd_v, sh_v} <= {adj_v[14:0], sh_v, 1'b0};
            {bcd_x, sh_x} <= {adj_x[14:0], sh_x, 1'b0};
            if (bit_cnt == 14) begin
                dig_v <= {adj_v[14:0], sh_v[13]};       // the 14th shift, as above
                dig_x <= {adj_x[14:0], sh_x[13]};
                bit_cnt <= '0;
            end else
                bit_cnt <= bit_cnt + 4'd1;
        end
    end

    // ---- digits to segments ----
    wire [3:0] v3 = dig_v[15:12], v2 = dig_v[11:8], v1 = dig_v[7:4];   // v0 = tenths, not shown
    wire [3:0] x3 = dig_x[15:12], x2 = dig_x[11:8], x1 = dig_x[7:4], x0 = dig_x[3:0];
    always_ff @(posedge clk) begin
        // left: whole volts, leading zeros blank
        hex[7] <= SEG_BLANK;
        hex[6] <= (v3 == 0) ? SEG_BLANK : seg(v3);
        hex[5] <= (v3 == 0 && v2 == 0) ? SEG_BLANK : seg(v2);
        hex[4] <= seg(v1);
        // right: the reading
        case (fmt_s)
            FMT_CENTI:
                if (x3 == 0) begin                      // below 10: d_dd
                    hex[3] <= seg(x2); hex[2] <= SEG_BAR; hex[1] <= seg(x1); hex[0] <= seg(x0);
                end else begin                          // 10 and above: dd_d
                    hex[3] <= seg(x3); hex[2] <= seg(x2); hex[1] <= SEG_BAR; hex[0] <= seg(x1);
                end
            FMT_INT: begin
                hex[3] <= (x3 == 0) ? SEG_BLANK : seg(x3);
                hex[2] <= (x3 == 0 && x2 == 0) ? SEG_BLANK : seg(x2);
                hex[1] <= (x3 == 0 && x2 == 0 && x1 == 0) ? SEG_BLANK : seg(x1);
                hex[0] <= seg(x0);
            end
            default: begin
                hex[3] <= SEG_DASH; hex[2] <= SEG_DASH; hex[1] <= SEG_DASH; hex[0] <= SEG_DASH;
            end
        endcase
    end
endmodule
