`timescale 1ns/1ps
// Simulation-first PWM building block for a three-phase, three-leg VSI.
// Active-HIGH logical gate outputs. No board pins or driver polarity assumed.
// A closed-loop APF controller must supply duty commands; this module does not
// perform harmonic extraction, current control, PLL, ADC acquisition or Vdc control.
module three_phase_pwm #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer PWM_HZ = 10_000,
    // EXAMPLE ONLY: 100 cycles = 2 us at 50 MHz. Set from driver/switch data.
    parameter integer DEAD_CYCLES = 100
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,       // synchronous; must be LOW to acknowledge a fault
    input  wire        fault_active, // asynchronous assertion; also use driver HW shutdown
    input  wire        fault_ack,    // synchronous pulse, only accepted with enable LOW
    input  wire        duty_valid,  // synchronous; all three commands sampled together
    input  wire [15:0] duty_a,      // 0..HALF_TICKS inclusive (not a percentage)
    input  wire [15:0] duty_b,
    input  wire [15:0] duty_c,
    output wire [2:0]  gate_hi,     // bit 0: phase A; bit 1: B; bit 2: C
    output wire [2:0]  gate_lo,
    output reg         fault_latched,
    output wire        frame_start
);
    localparam integer HALF_TICKS = CLK_HZ / (2 * PWM_HZ);
    localparam integer PERIOD_TICKS = 2 * HALF_TICKS;
    reg [31:0] phase_count;
    reg [15:0] pending_a, pending_b, pending_c;
    reg [15:0] active_a, active_b, active_c;
    reg pending_valid;

    wire commands_ok = (duty_a <= HALF_TICKS) &&
                       (duty_b <= HALF_TICKS) &&
                       (duty_c <= HALF_TICKS);
    wire bad_command = duty_valid && !commands_ok;
    wire permit = rst_n && enable && !fault_active && !fault_latched;
    wire [31:0] carrier = phase_count < HALF_TICKS ?
                         phase_count : PERIOD_TICKS - phase_count;
    wire [2:0] requested_hi = {
        (active_c == HALF_TICKS) || (carrier < active_c),
        (active_b == HALF_TICKS) || (carrier < active_b),
        (active_a == HALF_TICKS) || (carrier < active_a)
    };
    wire [2:0] hi_internal, lo_internal;
    assign frame_start = (phase_count == 0);

    // Faults latch through loss/recovery of the external fault input.
    // Reset starts inhibited. Clear with enable=0, fault_active=0, fault_ack=1.
    wire inhibit_async = !rst_n || fault_active;
    always @(posedge clk or posedge inhibit_async) begin
        if (inhibit_async)
            fault_latched <= 1'b1;
        else if (bad_command)
            fault_latched <= 1'b1;
        else if (fault_ack && !enable)
            fault_latched <= 1'b0;
    end

    // The latest complete command is applied at the next carrier boundary.
    // A command coincident with that boundary takes precedence over pending data.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_count <= 0;
            pending_a <= 0; pending_b <= 0; pending_c <= 0;
            active_a <= 0; active_b <= 0; active_c <= 0;
            pending_valid <= 0;
        end else begin
            if (phase_count == PERIOD_TICKS - 1)
                phase_count <= 0;
            else
                phase_count <= phase_count + 1;

            if (duty_valid && commands_ok) begin
                pending_a <= duty_a;
                pending_b <= duty_b;
                pending_c <= duty_c;
                pending_valid <= 1;
            end
            if (phase_count == 0) begin
                if (duty_valid && commands_ok) begin
                    active_a <= duty_a;
                    active_b <= duty_b;
                    active_c <= duty_c;
                    pending_valid <= 0;
                end else if (pending_valid) begin
                    active_a <= pending_a;
                    active_b <= pending_b;
                    active_c <= pending_c;
                    pending_valid <= 0;
                end
            end
        end
    end

    genvar p;
    generate for (p = 0; p < 3; p = p + 1) begin : legs
        pwm_deadtime #(.DEAD_CYCLES(DEAD_CYCLES)) leg (
            .clk(clk), .rst_n(rst_n), .enable(permit),
            .requested_hi(requested_hi[p]),
            .gate_hi(hi_internal[p]), .gate_lo(lo_internal[p])
        );
    end endgenerate

    // Asynchronous logical OFF path; external gate-driver hardware shutdown
    // remains necessary during FPGA configuration, clock loss and power faults.
    assign gate_hi = permit ? hi_internal : 3'b000;
    assign gate_lo = permit ? lo_internal : 3'b000;

    // Simulation parameter checks, excluded from synthesis.
    // synthesis translate_off
    initial begin
        if (CLK_HZ < 1 || PWM_HZ < 1 || HALF_TICKS < 2 || HALF_TICKS > 65535)
            $fatal(1, "Unsupported clock/PWM parameters");
        if (CLK_HZ % (2 * PWM_HZ) != 0)
            $fatal(1, "CLK_HZ must be divisible by 2*PWM_HZ");
        if (DEAD_CYCLES < 1 || DEAD_CYCLES >= HALF_TICKS)
            $fatal(1, "DEAD_CYCLES must be 1..HALF_TICKS-1");
    end
    // synthesis translate_on
endmodule

module pwm_deadtime #(
    parameter integer DEAD_CYCLES = 100
) (
    input wire clk, rst_n, enable, requested_hi,
    output reg gate_hi, gate_lo
);
    localparam integer TIMER_W = (DEAD_CYCLES < 2) ? 1 : $clog2(DEAD_CYCLES + 1);
    reg [TIMER_W-1:0] remaining;
    reg previous_request;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gate_hi <= 0; gate_lo <= 0;
            remaining <= DEAD_CYCLES;
            previous_request <= 0;
        end else if (!enable) begin
            gate_hi <= 0; gate_lo <= 0;
            remaining <= DEAD_CYCLES;
            previous_request <= requested_hi;
        end else if (requested_hi != previous_request) begin
            gate_hi <= 0; gate_lo <= 0;
            remaining <= DEAD_CYCLES - 1;
            previous_request <= requested_hi;
        end else if (remaining != 0) begin
            gate_hi <= 0; gate_lo <= 0;
            remaining <= remaining - 1'b1;
        end else begin
            gate_hi <= requested_hi;
            gate_lo <= !requested_hi;
        end
    end
endmodule
