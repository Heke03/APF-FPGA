// HEX4: a simulation model of the AD7606's digital side, in parallel mode, with a
// checker for every limit in the data sheet (Rev. G, Table 3) that the driver has to
// keep. Data is only valid inside the data sheet's window (X outside it, Z with CS
// high), so a driver that reads too early or too late gets X and fails its compare.
// `errors` counts the broken limits; each one is also printed, up to MAX_PRINT.
`timescale 1ns/1ps
module ad7606_model_HEX4 #(
    parameter real T_CONV  = 4000.0,   // tCONV: 3450 .. 4200 ns
    parameter real T1      = 40.0,     // CONVST high to BUSY high, <= 45 ns
    parameter real T10_MIN = 24.0,     // RD low, VDRIVE 3.3 V
    parameter real T11_MIN = 15.0,     // RD high
    parameter real T14     = 24.0,     // data valid after RD falls, <= 24 ns at 3.3 V
    parameter real T15     = 6.0,      // old data held after RD falls
    parameter real WIRE    = 3.0,      // pins and wires, each way
    parameter integer MAX_PRINT = 8
) (
    input  logic        reset,
    input  logic        convst,
    input  logic        cs_n,
    input  logic        rd_n,
    output logic        busy,
    output logic        frstdata,
    output logic [15:0] db,
    input  logic signed [15:0] analog [0:7],    // what each channel converts to now
    // for the tests: make the part misbehave
    input  logic        inject_no_busy,
    input  logic        inject_busy_stuck,
    input  logic        inject_frst_wrong,
    output int          errors,
    output int          frames,
    output logic signed [15:0] held [0:7]       // the values of the last conversion
);
    initial begin errors = 0; frames = 0; busy = 0; frstdata = 1'bz; db = 'z; end
    int reads = 0;
    bit was_reset = 0;
    realtime t_reset_rise = -1e9, t_reset_fall = -1e9, t_cv_rise = -1e9, t_cv_fall = -1e9, t_rd_fall = -1e9, t_rd_rise = -1e9;
    int rd_gen = 0;

    task automatic bad(input string what);
        errors++;
        if (errors <= MAX_PRINT) $display("%m AD7606 limit broken at %0.1f ns: %s", $realtime, what);
    endtask

    always @(posedge reset) t_reset_rise = $realtime;
    always @(negedge reset) begin
        t_reset_fall = $realtime;
        if ($realtime - t_reset_rise < 50.0) bad("tRESET: RESET high under 50 ns");
        was_reset = 1;
    end

    always @(negedge convst) begin
        if ($time != 0) begin
            if ($realtime - t_cv_rise < 25.0) bad("t3: CONVST high under 25 ns");
            t_cv_fall = $realtime;
        end
    end
    always @(posedge convst) if ($time != 0) begin
        if ($realtime - t_cv_fall < 25.0) bad("t2: CONVST low under 25 ns");
        if (!was_reset) bad("CONVST before the part was reset");
        if (reset || $realtime - t_reset_fall < 25.0) bad("t7: CONVST under 25 ns after RESET");
        if (busy) bad("CONVST during a conversion");
        if ($realtime - t_cv_rise < 5000.0) bad("tCYCLE: conversions under 5 us apart");
        t_cv_rise = $realtime;
        held = analog;
        frames++;
        reads = 0;
        if (!inject_no_busy) begin
            busy <= #(T1 + WIRE) 1'b1;
            if (!inject_busy_stuck) busy <= #(T_CONV + WIRE) 1'b0;
        end
    end

    // reading
    always @(negedge cs_n) begin
        if (busy) bad("t4: CS low during a conversion");
        db <= #(T14 + WIRE - 1.0) 'x;             // leaves three-state just before the first data
        frstdata <= #(T14 + WIRE - 1.0) 1'b0;
    end
    always @(negedge inject_busy_stuck) busy = 1'b0;
    always @(posedge cs_n) begin
        if (reads != 0 && reads != 8) bad($sformatf("read %0d channels, not 8", reads));
        rd_gen++;
        db <= #(6.0 + WIRE) 'x;
        db <= #(22.0 + WIRE) 'z;
        frstdata <= #(22.0 + WIRE) 1'bz;
    end
    always @(negedge rd_n) begin
        if (cs_n) bad("RD low with CS high");
        else begin
            automatic int k = reads;
            automatic int gen = ++rd_gen;
            if ($realtime - t_rd_rise < T11_MIN) bad("t11: RD high too short");
            t_rd_fall = $realtime;
            if (k >= 8) bad("more than 8 reads");
            db <= #(T15 + WIRE) 'x;
            // frstdata: high from the first RD falling edge until the second
            frstdata <= #(T14 + WIRE) ((k == 0) ^ inject_frst_wrong);
            fork
                begin
                    #(T14 + WIRE);
                    if (gen == rd_gen && k < 8) db = held[k];
                end
            join_none
            reads++;
        end
    end
    always @(posedge rd_n) if ($time != 0) begin
        if (!cs_n || t_rd_fall > 0) begin
            if ($realtime - t_rd_fall < T10_MIN) bad("t10: RD low too short");
        end
        t_rd_rise = $realtime;
    end
endmodule
