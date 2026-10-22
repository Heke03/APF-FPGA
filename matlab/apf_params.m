% Parameters for the Simulink model of the three-phase shunt APF (apf_system.slx).
%
% The power stage is the same assumed lab-scale design used by
% sim/tb_apf_system.sv and model/closed_loop_design.py. Replace these
% placeholders with the team's real values; the controller gains below are
% the floating-point equivalents of the constants in rtl/*.sv.
%
% The model's InitFcn runs this script, so editing it and pressing Run in
% Simulink is enough.

% ---- simulation ----
T_end   = 1.0;          % s
Tps     = 0.5e-6;       % power-stage (powergui) step, s
T_log   = 10e-6;        % logging interval for waveforms, s
t_run   = 0.01;         % operator "run" request, s
t_step  = 0.7;          % load step 33 -> 22 ohm, s

% ---- grid (stiff) ----
f       = 50;                       % Hz
Vm      = 100;                      % phase voltage peak, V
Vll_rms = Vm * sqrt(3) / sqrt(2);   % 122.5 V line-line rms
Rgrid   = 1e-3;                     % ohm
Lgrid   = 10e-6;                    % H

% ---- nonlinear load: 6-pulse diode bridge ----
Lac_load = 0.5e-3;      % AC-side line reactor, H (gives the commutation overlap
                        % that the RTL testbench approximates with a 0.2 ms lag)
Rac_load = 0.01;        % ohm
Ldc_load = 20e-3;       % DC choke, H
R_load1  = 33;          % ohm
R_load2  = 22;          % ohm after the step
R_step   = R_load1 * R_load2 / (R_load1 - R_load2);   % 66 ohm switched in parallel

% ---- APF inverter ----
Lf      = 3e-3;         % filter inductor per phase, H
Rf      = 0.1;          % ohm
Cdc     = 1000e-6;      % DC-link capacitor, F
Rleak   = 20e3;         % DC-link bleed resistor, ohm
Vdc0    = sqrt(3) * Vm; % precharge through the inverter diodes, V
Ron_sw  = 1e-3;         % IGBT/diode on-resistance, ohm
Td      = 2e-6;         % dead time, s

% ---- controller (FPGA) ----
P = struct();
P.Ts        = 1e-4;         % control / PWM period (10 kHz), s
P.f         = f;
P.N         = round(1 / (f * P.Ts));   % samples per grid cycle (WINDOW = 200)
% SRF-PLL (rtl/srf_pll.sv): 20 Hz bandwidth, zeta 0.707, 45-55 Hz clamp
P.pll_bw    = 20;
P.pll_zeta  = 0.707;
P.pll_fmin  = 45;
P.pll_fmax  = 55;
P.pll_vmin  = 25;           % V; MIN_AMPLITUDE (400 counts / 16 counts/V)
P.lock_deg  = 2;            % lock: LOCK_N samples under this error
P.unlock_deg = 15;          % unlock: UNLOCK_N samples over this error
P.lock_n    = 400;
P.unlock_n  = 50;
% Current controller (rtl/current_controller.sv)
P.Lf        = Lf;           % inductance assumed by the controller
P.G         = 0.5;          % deadbeat gain (K_CTRL)
P.pred_lead = 3;            % reference prediction: slot k+3-N (PRED_LEAD)
P.Td        = Td;           % dead-time compensation
P.vdc_min_div = 50;         % divider floor (VDC16_MIN), V
% DC-link loop (runs once per grid cycle on the cycle average)
P.vdc_ref   = 300;          % V
P.vdc_ramp  = 500;          % V/s
P.kp_dc     = 0.1;          % A/V
P.ki_dc     = 1.0;          % A/(V s)
P.idc_max   = 10;           % A
% Protection (rtl/apf_core.sv)
P.i_trip    = 15;           % inverter over-current, A
P.vdc_trip  = 380;          % DC-link over-voltage, V
P.v_range   = 127;          % ADC range of the grid voltage channels, V
P.i_range   = 20.3;         % ADC range of the current channels, A

Ts = P.Ts;                  % used by block sample times
dtc = Td / (Ts / 2) / 2;    % PWM comparator offset that gives Td per transition
