function V = vps_params_H3(fx)
% H3: virtual power stage (VPS) - the grid, the diode-bridge load and the APF
% inverter computed inside the FPGA, so the controller can run in closed loop on
% the DE2-115 with nothing connected. This file is the specification: the
% Simulink block (blocks/vps_block_H3.m) and the FPGA code use exactly these
% integer constants and number formats.
%
%   V = vps_params_H3(true)    % fixed point: integer math, constants rounded (= FPGA)
%   V = vps_params_H3(false)   % same equations with exact real constants (reference)
%
% Plant (same assumed lab-scale values as apf_params.m and sim/tb_apf_system.sv):
%   grid      3-phase, 100 V phase peak, 50 Hz, stiff
%   load      6-pulse diode bridge, 20 mH + 33 ohm on the DC side (22 ohm after
%             the load step); commutation smoothed by a 0.2 ms first-order lag
%   inverter  3 legs, ideal switches + diodes (dead time from the real gates),
%             3 mH + 0.1 ohm per phase, 1000 uF DC link precharged to 173.2 V,
%             contactor closed while the controller is switching
% One plant step every H = 200 ns (10 clocks at 50 MHz), forward Euler.
%
% Number formats (all signed integers):
%   voltages (grid, leg, neutral)  LSB 2^-12 V
%   DC-link voltage state          LSB 2^-24 V   (40-bit in the FPGA)
%   currents (inverter, load, DC)  LSB 2^-24 A   (32-bit: +-128 A)
%   grid angle                     40-bit phase accumulator (1 turn = 2^40)
%   cosine                         rtl/cos_table_4096.hex (peak 2^16), linear interpolation
% Every product is rounded back with rsh(x, s) = floor((x + 2^(s-1)) / 2^s), which is
% (x + (1 << (s-1))) >>> s in the FPGA. All products stay below 2^53, so MATLAB's
% doubles hold them exactly and the FPGA code can match bit for bit.
if nargin < 1, fx = true; end

% ---- physical values ----
V.H      = 200e-9;      % plant step, s
V.f      = 50;          % grid frequency, Hz
V.Vm     = 100;         % phase peak, V
V.Lf     = 3e-3;  V.Rf = 0.1;
V.Cdc    = 1000e-6; V.Rleak = 20e3;
V.Ldc    = 20e-3;
V.R1     = 33;    V.R2 = 22;
V.tau_comm = 0.2e-3;
V.vdc0   = 173.2;       % DC-link precharge, V

% ---- integer constants: value = scale factor, rounded in fixed point ----
V.fx = logical(fx);
q = @(x) x;
if fx, q = @round; end
V.dth    = q(2^40 * V.f * V.H);              % angle step per plant step
V.th120  = q(2^40 / 3);                      % 120 degrees
V.Kvm    = V.Vm * 2^12;                      % cos (2^16) -> volts (2^-12): rsh(cos * Kvm, 16)
V.K3     = q(2^16 / 3);                      % neutral = rsh(sum * K3, 16)
V.Krf    = q(V.Rf * 2^16);                   % Rf * i: rsh(i * Krf, 28)
V.Kl     = q(V.H / V.Lf * 2^12 * 2^16);      % di = rsh(dv * Kl, 16)
V.Kc     = q(V.H / V.Cdc * 2^24);            % dvdc = rsh(i * Kc, 24)
V.Kleak  = q(V.H / (V.Rleak * V.Cdc) * 2^32);% leak = rsh(vdc * Kleak, 32)
V.Kd     = q(V.H / V.Ldc * 2^12 * 2^16);     % di_dc = rsh(dv * Kd, 16)
V.Kt     = q(V.H / V.tau_comm * 2^20);       % commutation lag: rsh(diff * Kt, 20)
V.vdc0_q = q(V.vdc0 * 2^24);

% ---- cosine table shared with the FPGA (rtl/cos_table_4096.hex) ----
here = fileparts(mfilename('fullpath'));
fid = fopen(fullfile(here, '..', 'rtl', 'cos_table_4096.hex'), 'r');
raw = textscan(fid, '%s'); fclose(fid);
c = mod(hex2dec(raw{1}), 2^18);              % $readmemh keeps the low 18 bits
c(c >= 2^17) = c(c >= 2^17) - 2^18;          % 18-bit two's complement
V.cos_table = c(:).';

% ---- what the rounding does to the plant (fixed point only) ----
if fx
    V.effective = struct( ...
        'f_Hz', V.dth / 2^40 / V.H, ...
        'Lf_H', V.H * 2^28 / V.Kl, ...
        'Cdc_F', V.H * 2^24 / V.Kc, ...
        'Rleak_ohm', V.H * 2^32 / (V.Kleak * V.Cdc), ...
        'Ldc_H', V.H * 2^28 / V.Kd, ...
        'tau_comm_s', V.H * 2^20 / V.Kt, ...
        'Rf_ohm', V.Krf / 2^16, ...
        'one_third', V.K3 / 2^16);
end
end
