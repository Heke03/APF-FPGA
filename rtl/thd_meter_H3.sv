`timescale 1ns/1ps
// H3: THD meter for the board display - the THD of one current, measured from
// one sample per controller frame (10 kHz). Bit-exact with matlab/thd_meter_H3.m.
//
// Every 1000 samples (5 cycles of the virtual 50 Hz grid) it measures harmonics
// h = 1..40 with a DFT and publishes
//   THD = sqrt(sum |I_h|^2, h = 2..40) / |I_1|      in 0.01 % (440 = 4.40 %)
// The grid is exactly 50 Hz and a frame exactly 1/200 of a cycle, so the cosine
// and sine of h*2*pi*k/200 come from a 200-point table (rtl/thd_table_200.hex,
// written by matlab/thd_vectors_H3.m), index (h*k) mod 200.
//
// Whole-number steps, as in the MATLAB code:
//   is = (sample + 2^13) >>> 14                      2^-10 A
//   re_h, im_h = (sum is*C, sum is*S + 2^15) >>> 16  C, S scaled 2^15
//   f1 = re_1^2 + im_1^2,  hs = sum (re_h^2 + im_h^2), h = 2..40
//   no reading if f1 < 2^28 (fundamental below ~0.1 A); 9999 if hs >= f1
//   q = floor(hs / f1 * 2^24) (24-step division), thd = floor(sqrt(floor(q * 10^8 / 2^24)))
//
// Timing: 3 clocks per harmonic per sample (120), and about 210 more after the
// last sample of a window, so samples must be at least 340 clocks apart
// (5000 at 10 kHz).
module thd_meter_H3 #(
    parameter TABLE_FILE = "thd_table_200.hex"
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sample_en,           // one clock per sample
    input  logic signed [31:0] sample,       // 2^-24 A
    output logic [13:0] thd,                 // 0.01 %, 0..9999
    output logic        thd_valid,           // the last reading had current to measure
    output logic        reading_done         // one clock when a reading is published
);
    localparam integer N = 1000, M = 200, H = 40;
    localparam logic [52:0] MIN_F1 = 53'd1 << 28;

    // ---- cos/sin table: {cos, sin}, 17-bit two's complement each (9 hex digits a line) ----
    logic [35:0] tab [0:M-1];
    initial $readmemh(TABLE_FILE, tab);
    logic [7:0]  m;                          // (h * kk) mod 200
    logic [35:0] tab_q;
    always_ff @(posedge clk) tab_q <= tab[m];

    // ---- the 40 harmonic sums: one RAM word {re, im} per harmonic ----
    logic [5:0]  hi;                         // harmonic index, h - 1
    logic [87:0] acc [0:H-1];
    logic [87:0] acc_q, acc_d;
    logic        acc_we;
    always_ff @(posedge clk) begin
        if (acc_we) acc[hi] <= acc_d;
        acc_q <= acc[hi];
    end
    wire signed [43:0] acc_re = acc_q[87:44];
    wire signed [43:0] acc_im = acc_q[43:0];

    typedef enum logic [3:0] {IDLE, A_READ, A_MUL, A_ADD, F_READ, F_ROUND, F_SQUARE, F_SUM,
                              CHECK, DIVIDE, SCALE, ROOT, PUBLISH} state_t;
    state_t state;

    logic signed [18:0] is_r;                // 2^-10 A
    logic [7:0]  kk;                         // sample index within the grid cycle, 0..199
    logic [9:0]  k;                          // sample index within the window, 0..999
    logic signed [35:0] prod_c, prod_s;
    logic signed [26:0] re, im;
    logic [52:0] sq_re, sq_im;
    logic [52:0] f1;
    logic [58:0] hs;
    logic [54:0] n_div;
    logic [23:0] q;
    logic [26:0] r;                          // q * 10^8 / 2^24, below 10^8
    logic [26:0] root_x, root_res, root_bit;
    logic [4:0]  step;

    wire [7:0] m_next = (m + kk >= M) ? 8'(m + kk - M) : 8'(m + kk);
    wire signed [16:0] tab_c = tab_q[33:17];
    wire signed [16:0] tab_s = tab_q[16:0];
    wire [52:0] p_h = sq_re + sq_im;

    always_comb begin
        acc_d = '0;
        if (k == 0) acc_d = {44'(prod_c), 44'(prod_s)};
        else        acc_d = {acc_re + 44'(prod_c), acc_im + 44'(prod_s)};
    end
    assign acc_we = (state == A_ADD);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; kk <= '0; k <= '0; hi <= '0; m <= '0; step <= '0;
            is_r <= '0; prod_c <= '0; prod_s <= '0; re <= '0; im <= '0; sq_re <= '0; sq_im <= '0;
            f1 <= '0; hs <= '0; n_div <= '0; q <= '0; r <= '0;
            root_x <= '0; root_res <= '0; root_bit <= '0;
            thd <= '0; thd_valid <= 1'b0; reading_done <= 1'b0;
        end else begin
            reading_done <= 1'b0;
            case (state)
                IDLE: if (sample_en) begin
                    is_r <= 19'((33'(sample) + 33'(8192)) >>> 14);
                    hi <= '0; m <= kk;
                    state <= A_READ;
                end
                // ---- add this sample to every harmonic: is * cos, is * sin ----
                A_READ: state <= A_MUL;                     // table word and sums for hi
                A_MUL: begin
                    prod_c <= is_r * tab_c;
                    prod_s <= is_r * tab_s;
                    state <= A_ADD;
                end
                A_ADD: begin                                // acc[hi] written here
                    if (hi == H - 1) begin
                        hi <= '0;
                        kk <= (kk == M - 1) ? '0 : kk + 8'd1;
                        if (k == N - 1) begin
                            k <= '0; hs <= '0;
                            state <= F_READ;
                        end else begin
                            k <= k + 10'd1;
                            state <= IDLE;
                        end
                    end else begin
                        hi <= hi + 6'd1; m <= m_next;
                        state <= A_READ;
                    end
                end
                // ---- end of the window: harmonic powers ----
                F_READ: state <= F_ROUND;
                F_ROUND: begin
                    re <= 27'((acc_re + 44'sd32768) >>> 16);
                    im <= 27'((acc_im + 44'sd32768) >>> 16);
                    state <= F_SQUARE;
                end
                F_SQUARE: begin
                    sq_re <= 53'(54'(re) * 54'(re));
                    sq_im <= 53'(54'(im) * 54'(im));
                    state <= F_SUM;
                end
                F_SUM: begin
                    if (hi == 0) f1 <= p_h;
                    else hs <= hs + 59'(p_h);
                    if (hi == H - 1) begin hi <= '0; state <= CHECK; end
                    else begin hi <= hi + 6'd1; state <= F_READ; end
                end
                CHECK: begin
                    if (f1 < MIN_F1) begin
                        thd <= '0; thd_valid <= 1'b0; state <= PUBLISH;
                    end else if (hs >= 59'(f1)) begin
                        thd <= 14'd9999; thd_valid <= 1'b1; state <= PUBLISH;
                    end else begin
                        n_div <= 55'(hs); q <= '0; step <= '0; state <= DIVIDE;
                    end
                end
                // ---- q = floor(hs / f1 * 2^24), one bit per clock ----
                DIVIDE: begin
                    if ({n_div[53:0], 1'b0} >= 55'(f1)) begin
                        n_div <= {n_div[53:0], 1'b0} - 55'(f1); q <= {q[22:0], 1'b1};
                    end else begin
                        n_div <= {n_div[53:0], 1'b0}; q <= {q[22:0], 1'b0};
                    end
                    if (step == 23) state <= SCALE;
                    step <= step + 5'd1;
                end
                SCALE: begin
                    r <= 27'((51'(q) * 51'd100000000) >> 24);
                    root_res <= '0; root_bit <= 27'd1 << 26; step <= '0;
                    state <= ROOT;
                end
                // ---- floor(sqrt(r)), two bits of r per clock ----
                ROOT: begin
                    if (step == 0) root_x <= r;
                    else if (step <= 14) begin
                        if (28'(root_x) >= 28'(root_res) + 28'(root_bit)) begin
                            root_x <= root_x - (root_res + root_bit);
                            root_res <= (root_res >> 1) + root_bit;
                        end else
                            root_res <= root_res >> 1;
                        root_bit <= root_bit >> 2;
                    end else begin
                        thd <= (root_res > 9999) ? 14'd9999 : 14'(root_res);
                        thd_valid <= 1'b1;
                        state <= PUBLISH;
                    end
                    step <= step + 5'd1;
                end
                PUBLISH: begin
                    reading_done <= 1'b1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
