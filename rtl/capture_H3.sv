`timescale 1ns/1ps
// H3: waveform recorder for the board. Records 5 channels, one sample per
// controller frame (10 kHz), into on-chip memories that the PC reads over the
// USB-Blaster cable while the design runs (In-System Memory Content Editor,
// quartus/read_capture_H3.tcl; MATLAB: board_capture_H3).
//
// It records all the time into a ring of 2^DEPTH_LOG2 samples. A trigger (a
// switch flipped) lets it record 2^(DEPTH_LOG2-1) more samples and then stop,
// so the ring holds as much before the trigger as after it (0.82 s each at
// DEPTH_LOG2 = 14). Then `ready` is high until `arm` (KEY1) starts a new
// recording; triggers while stopped are ignored, so a recording stays until read.
//
// Memories (instance names for the PC):
//   IG, IL, II   grid, load, inverter current of phase a, 2^-10 A, signed 16 bit
//   VD           DC link, 2^-6 V, unsigned 16 bit
//   VG           grid voltage of phase a, 2^-7 V, signed 16 bit
//   INF          8 words of 32 bit: 0 magic A9F00003, 1 status {DEPTH_LOG2 in 15:8,
//                recording, triggered, ready}, 2 next write address, 3 address of the
//                first sample at or after the trigger, 4 samples recorded since arming
//                (at most the depth), 5 samples after the trigger, 6 THD meter window
//                position of the trigger sample (0..999), 7 switches {before 6:4, after 2:0}
module capture_H3 #(
    parameter integer DEPTH_LOG2 = 14
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sample_en,          // one clock per frame
    input  logic [15:0] ig, il, ii, vd, vg,
    input  logic        trig,               // one clock: a switch was flipped
    input  logic [2:0]  sw_before, sw_after,
    input  logic        arm,                // one clock: start a new recording
    input  logic [9:0]  meter_pos,          // THD meter window position of the sample taken now
    output logic        ready               // stopped, holding a recording
);
    localparam integer DEPTH = 1 << DEPTH_LOG2;
    localparam integer POST  = DEPTH / 2;

    logic [DEPTH_LOG2-1:0] wr_addr, trig_addr;
    logic [DEPTH_LOG2:0]   fresh, post_cnt;
    logic recording, triggered, pending;
    logic [9:0] k_trig;
    logic [6:0] sw_info, sw_pend;
    wire  we = sample_en && recording;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_addr <= '0; trig_addr <= '0; fresh <= '0; post_cnt <= '0;
            recording <= 1'b1; triggered <= 1'b0; pending <= 1'b0; ready <= 1'b0;
            k_trig <= '0; sw_info <= '0; sw_pend <= '0;
        end else begin
            if (arm) begin
                recording <= 1'b1; triggered <= 1'b0; pending <= 1'b0; ready <= 1'b0;
                fresh <= '0; post_cnt <= '0;
            end else begin
                if (trig && recording && !triggered) begin
                    triggered <= 1'b1; pending <= 1'b1;
                    sw_pend <= {sw_before, 1'b0, sw_after};
                end
                if (we) begin
                    wr_addr <= wr_addr + 1'b1;
                    if (fresh != DEPTH) fresh <= fresh + 1'b1;
                    if (pending) begin                       // first sample at or after the trigger
                        pending <= 1'b0; trig_addr <= wr_addr; k_trig <= meter_pos; sw_info <= sw_pend;
                        post_cnt <= 1;
                    end else if (triggered) begin
                        post_cnt <= post_cnt + 1'b1;
                    end
                    if (triggered && !pending && post_cnt == POST - 1) begin
                        recording <= 1'b0; ready <= 1'b1;
                    end
                end
            end
        end
    end

    // ---- the memories: single port written here, read by the PC over JTAG ----
    genvar c;
    generate for (c = 0; c < 5; c++) begin : g_mem
        localparam HINT = (c == 0) ? "ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=IG" :
                          (c == 1) ? "ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=IL" :
                          (c == 2) ? "ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=II" :
                          (c == 3) ? "ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=VD" :
                                     "ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=VG";
        wire [15:0] din = (c == 0) ? ig : (c == 1) ? il : (c == 2) ? ii : (c == 3) ? vd : vg;
        altsyncram #(
            .operation_mode("SINGLE_PORT"), .width_a(16), .widthad_a(DEPTH_LOG2), .numwords_a(DEPTH),
            .outdata_reg_a("UNREGISTERED"), .clock_enable_input_a("BYPASS"), .clock_enable_output_a("BYPASS"),
            .outdata_aclr_a("NONE"), .address_aclr_a("NONE"), .width_byteena_a(1),
            .power_up_uninitialized("FALSE"), .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
            .intended_device_family("Cyclone IV E"), .lpm_type("altsyncram"),
            .lpm_hint(HINT)
        ) mem (
            .clock0(clk), .address_a(wr_addr), .data_a(din), .wren_a(we), .q_a()
        );
    end endgenerate

    // status words, written in turn into the INF memory (one word per clock)
    logic [2:0]  info_addr;
    logic [31:0] info_word;
    always_comb begin
        case (info_addr)
            3'd0: info_word = 32'hA9F0_0003;
            3'd1: info_word = {16'd0, 8'(DEPTH_LOG2), 5'd0, recording, triggered, ready};
            3'd2: info_word = 32'(wr_addr);
            3'd3: info_word = 32'(trig_addr);
            3'd4: info_word = 32'(fresh);
            3'd5: info_word = 32'(post_cnt);
            3'd6: info_word = 32'(k_trig);
            default: info_word = 32'(sw_info);
        endcase
    end
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) info_addr <= '0; else info_addr <= info_addr + 3'd1;
    altsyncram #(
        .operation_mode("SINGLE_PORT"), .width_a(32), .widthad_a(3), .numwords_a(8),
        .outdata_reg_a("UNREGISTERED"), .clock_enable_input_a("BYPASS"), .clock_enable_output_a("BYPASS"),
        .outdata_aclr_a("NONE"), .address_aclr_a("NONE"), .width_byteena_a(1),
        .power_up_uninitialized("FALSE"), .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
        .intended_device_family("Cyclone IV E"), .lpm_type("altsyncram"),
        .lpm_hint("ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=INF")
    ) info_mem (
        .clock0(clk), .address_a(info_addr), .data_a(info_word), .wren_a(1'b1), .q_a()
    );
endmodule
