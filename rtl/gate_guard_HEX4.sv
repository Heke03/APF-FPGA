`timescale 1ns/1ps
// HEX4: the last block before the gate pins. It trusts nothing that comes before it,
// including apf_core and three_phase_pwm, and it can only turn gates off.
//
// A gate can be on only while the operator has armed the power stage, nothing has
// tripped, and apf_core says it is switching. A trip turns all gates off on the next
// clock and stays until the operator disarms and the cause has gone:
//   bit 0  both switches of one leg commanded on (shoot-through)
//   bit 1  a switch turned on less than MIN_DEAD_CLKS after the other one of its leg turned off
//   bit 2  the gate drivers report a problem (drivers_ok low)
//   bit 3  the ADC driver reports a problem
//   bit 4  apf_core has a fault
//   bit 5  no ADC frame for WDOG_CLKS while armed (apf_core would run on old values)
//
// Arming while apf_core is already switching does nothing until it has stopped, so a
// repaired fault cannot restart the inverter by itself.
module gate_guard_HEX4 #(
    parameter integer MIN_DEAD_CLKS = 50,        // 1 us; three_phase_pwm uses 2 us
    parameter integer WDOG_CLKS     = 15000      // 300 us: 3 missed frames
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        arm,                     // the operator's switch, debounced
    input  logic        drivers_ok,              // synchronized
    input  logic        adc_fault,
    input  logic        core_fault,
    input  logic        core_switching,
    input  logic        frame_tick,              // one clock per ADC frame
    input  logic [2:0]  hi_in,
    input  logic [2:0]  lo_in,
    output logic [2:0]  hi_out,
    output logic [2:0]  lo_out,
    output logic        gate_en_n,               // high: the gate driver buffer is disabled
    output logic        contactor,               // connect the inverter
    output logic        tripped,
    output logic [5:0]  cause,
    output logic        running                  // armed, nothing tripped: gates may follow apf_core
);
    logic [2:0] hi_prev, lo_prev;
    logic [$clog2(MIN_DEAD_CLKS+1)-1:0] hi_off [0:2], lo_off [0:2];   // clocks since it turned off, saturating
    logic [$clog2(WDOG_CLKS+1)-1:0] wdog;
    logic armed;
    logic [5:0] now;

    always_comb begin
        now = '0;
        for (int k = 0; k < 3; k++) begin
            if (hi_in[k] && lo_in[k]) now[0] = 1'b1;
            if (hi_in[k] && !hi_prev[k] && (lo_prev[k] || lo_off[k] != MIN_DEAD_CLKS)) now[1] = 1'b1;
            if (lo_in[k] && !lo_prev[k] && (hi_prev[k] || hi_off[k] != MIN_DEAD_CLKS)) now[1] = 1'b1;
        end
        now[2] = !drivers_ok;
        now[3] = adc_fault;
        now[4] = core_fault;
        now[5] = armed && (wdog == WDOG_CLKS);
        // nothing is a trip until the operator has armed
        if (!arm) now = '0;
    end
    wire trip_any = tripped || (now != 0);
    assign running = armed && arm && !trip_any;         // disarming acts on the very next clock

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hi_prev <= '0; lo_prev <= '0; wdog <= '0; armed <= 1'b0; tripped <= 1'b0; cause <= '0;
            hi_out <= '0; lo_out <= '0; gate_en_n <= 1'b1; contactor <= 1'b0;
            for (int k = 0; k < 3; k++) begin hi_off[k] <= '0; lo_off[k] <= '0; end
        end else begin
            hi_prev <= hi_in; lo_prev <= lo_in;
            for (int k = 0; k < 3; k++) begin
                if (hi_in[k]) hi_off[k] <= '0;
                else if (hi_off[k] != MIN_DEAD_CLKS) hi_off[k] <= hi_off[k] + 1'b1;
                if (lo_in[k]) lo_off[k] <= '0;
                else if (lo_off[k] != MIN_DEAD_CLKS) lo_off[k] <= lo_off[k] + 1'b1;
            end
            if (frame_tick || !arm) wdog <= '0;
            else if (wdog != WDOG_CLKS) wdog <= wdog + 1'b1;

            if (!arm) begin
                armed <= 1'b0;
                // disarmed: the trip clears once its causes are gone
                if (drivers_ok && !adc_fault && !core_fault) begin tripped <= 1'b0; cause <= '0; end
            end else begin
                if (now != 0) begin tripped <= 1'b1; cause <= cause | now; end
                if (!core_switching && !trip_any) armed <= 1'b1;   // armed only from a stop
                if (trip_any) armed <= 1'b0;
            end

            hi_out <= (running && core_switching) ? hi_in : 3'b000;
            lo_out <= (running && core_switching) ? lo_in : 3'b000;
            gate_en_n <= !running;
            contactor <= running && core_switching;
        end
    end
endmodule
