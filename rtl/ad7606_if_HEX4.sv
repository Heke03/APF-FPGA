`timescale 1ns/1ps
// HEX4: driver for the AD7606 ADC in parallel mode with no oversampling. One `start`
// pulse: CONVST, wait for BUSY, then read the 8 channels. About 5 us in total.
//
// Times come from the AD7606 data sheet, Rev. G, Table 3 (VDRIVE 3.3 V), at 50 MHz:
//   CONVST low   60 ns   t2 >= 25 ns
//   RESET high  100 ns   tRESET >= 50 ns, and 100 ns more before the first CONVST (t7 >= 25 ns)
//   RD low       60 ns   t10 >= 24 ns; data is read at the end, t14 <= 24 ns after RD falls
//                        (30 ns if VDRIVE is only 2.7 V), which leaves about 25 ns for pins and wires
//   RD high      40 ns   t11 >= 15 ns
//   CS falls after BUSY has fallen (t4 >= 0), and FRSTDATA must be high on channel 1 only.
//
// Anything unexpected sets a fault bit that stays until clear_faults. A frame with a
// FRSTDATA error is not delivered, because its channels may be in the wrong order.
module ad7606_if_HEX4 #(
    parameter integer RD_LOW_CLKS      = 3,
    parameter integer RD_HIGH_CLKS     = 2,
    parameter integer CONVST_LOW_CLKS  = 3,
    parameter integer RESET_CLKS       = 5,
    parameter integer AFTER_RESET_CLKS = 5,
    parameter integer BUSY_RISE_CLKS   = 6,      // 120 ns: t1 <= 45 ns, plus the 2-clock synchronizer
    parameter integer BUSY_MAX_CLKS    = 250     // 5 us: tCONV <= 4.2 us
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,                   // one clock: sample now
    input  logic        clear_faults,
    // pins
    output logic        ad_reset,
    output logic        ad_convst,               // to CONVST A and CONVST B
    output logic        ad_cs_n,
    output logic        ad_rd_n,
    input  logic        ad_busy,
    input  logic        ad_frstdata,
    input  logic [15:0] ad_db,
    // result
    output logic signed [15:0] raw [0:7],        // two's complement, as the ADC gives it
    output logic        raw_valid,               // one clock; raw stays until the next frame
    output logic        ready,                   // the ADC has been reset
    output logic [3:0]  fault                    // {start while busy, FRSTDATA wrong, BUSY stuck high, BUSY never rose}
);
    typedef enum logic [2:0] {S_RESET, S_AFTER_RESET, S_IDLE, S_CONVST, S_BUSY_RISE, S_BUSY_FALL, S_RD_LOW, S_RD_HIGH} state_t;
    state_t state;
    logic [11:0] cnt;
    logic [2:0]  chan;
    logic        frame_bad;
    logic [1:0]  busy_s;
    wire         busy = busy_s[1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_RESET; cnt <= 12'(RESET_CLKS - 1); chan <= '0; frame_bad <= 1'b0;
            busy_s <= '0; ad_reset <= 1'b1; ad_convst <= 1'b1; ad_cs_n <= 1'b1; ad_rd_n <= 1'b1;
            raw_valid <= 1'b0; ready <= 1'b0; fault <= '0;
            for (int i = 0; i < 8; i++) raw[i] <= '0;
        end else begin
            busy_s <= {busy_s[0], ad_busy};
            raw_valid <= 1'b0;
            if (clear_faults) fault <= '0;
            if (start && state != S_IDLE && state != S_RESET && state != S_AFTER_RESET) fault[3] <= 1'b1;
            case (state)
                S_RESET:
                    if (cnt == 0) begin ad_reset <= 1'b0; cnt <= 12'(AFTER_RESET_CLKS - 1); state <= S_AFTER_RESET; end
                    else cnt <= cnt - 1'b1;
                S_AFTER_RESET:
                    if (cnt == 0) begin ready <= 1'b1; state <= S_IDLE; end
                    else cnt <= cnt - 1'b1;
                S_IDLE:
                    if (start) begin ad_convst <= 1'b0; cnt <= 12'(CONVST_LOW_CLKS - 1); state <= S_CONVST; end
                S_CONVST:
                    if (cnt == 0) begin                 // the rising edge samples all channels
                        ad_convst <= 1'b1; cnt <= 12'(BUSY_RISE_CLKS - 1); state <= S_BUSY_RISE;
                    end else cnt <= cnt - 1'b1;
                S_BUSY_RISE:
                    if (busy) begin cnt <= 12'(BUSY_MAX_CLKS - 1); state <= S_BUSY_FALL; end
                    else if (cnt == 0) begin fault[0] <= 1'b1; state <= S_IDLE; end
                    else cnt <= cnt - 1'b1;
                S_BUSY_FALL:
                    if (!busy) begin
                        ad_cs_n <= 1'b0; ad_rd_n <= 1'b0; chan <= '0; frame_bad <= 1'b0;
                        cnt <= 12'(RD_LOW_CLKS - 1); state <= S_RD_LOW;
                    end else if (cnt == 0) begin fault[1] <= 1'b1; state <= S_IDLE; end
                    else cnt <= cnt - 1'b1;
                S_RD_LOW:
                    if (cnt == 0) begin                 // the end of RD low: data is valid
                        raw[chan] <= $signed(ad_db);
                        if (ad_frstdata !== (chan == 0)) begin frame_bad <= 1'b1; fault[2] <= 1'b1; end
                        ad_rd_n <= 1'b1; cnt <= 12'(RD_HIGH_CLKS - 1); state <= S_RD_HIGH;
                    end else cnt <= cnt - 1'b1;
                S_RD_HIGH:
                    if (cnt == 0) begin
                        if (chan == 7) begin
                            ad_cs_n <= 1'b1; raw_valid <= !frame_bad; state <= S_IDLE;
                        end else begin
                            ad_rd_n <= 1'b0; chan <= chan + 1'b1; cnt <= 12'(RD_LOW_CLKS - 1); state <= S_RD_LOW;
                        end
                    end else cnt <= cnt - 1'b1;
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
