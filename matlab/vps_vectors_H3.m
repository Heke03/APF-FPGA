function out = vps_vectors_H3(T)
% H3: test vectors for the bit-exact check of rtl/virtual_power_stage_H3.sv.
% Runs the fixed-point reference (blocks/vps_block_H3.m) step by step with a
% stimulus that exercises every branch, and writes one line per 200 ns step to
% sim/out/H3/vps_vectors.txt:
%   gates contactor load_step  vg_a vg_b vg_c  il_a il_b il_c  if_a if_b if_c  vdc  code0..code6  shoot
% (gates: bit 0 A hi, 1 A lo, 2 B hi, 3 B lo, 4 C hi, 5 C lo; values in the
% integer formats of vps_params_H3.m). sim/tb_vps_H3.sv compares the FPGA code
% with every line.
%
%   >> vps_vectors_H3          % 40 ms = 200 000 steps
%   >> out = vps_vectors_H3;   % also returns the table written to the file
%
% Stimulus (open-loop PWM, 10 kHz, 2 us dead time, modulation 0.95 in phase with the grid):
%   0-2 ms      disconnected, gates off          (plant alone)
%   2-2.5 ms    disconnected, PWM running        (counter: gates while disconnected)
%   3 ms on     connected, PWM
%   10 ms       leg A both switches on for 3 steps (shoot-through counter)
%   20 ms       load step 33 -> 22 ohm
%   25-25.5 ms  connected, all gates off         (diodes carry the current, both signs)
%   30-31 ms    disconnected again, then reconnected
if nargin < 1, T = 0.04; end
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, 'blocks'));
V = vps_params_H3(true);
clear vps_block_H3                              % start from the reset state
n = round(T / V.H);
out = zeros(n, 21);
dtc = 2e-6 / (1e-4 / 2) / 2;                   % as apf_params.m: 2 us dead time
for k = 1:n
    t = (k - 1) * V.H;
    pos = mod(k - 1, 500);                      % 10 kHz carrier, 500 steps
    carrier = min(pos, 500 - pos) / 250;
    g = zeros(1, 6);
    for p = 1:3
        d = 0.5 + 0.5 * 0.95 * cos(2 * pi * 50 * t - (p - 1) * 2 * pi / 3);
        g(2 * p - 1) = (d - dtc) > carrier;
        g(2 * p) = (d + dtc) < carrier;
    end
    con = t >= 3e-3 && ~(t >= 30e-3 && t < 31e-3);
    pwm = con || (t >= 2e-3 && t < 2.5e-3);
    if ~pwm || (t >= 25e-3 && t < 25.5e-3), g(:) = 0; end
    if k >= round(10e-3 / V.H) && k < round(10e-3 / V.H) + 3, g(1:2) = 1; end
    ls = t >= 20e-3;
    [vg, il, iff, ~, vdc, shoot] = vps_block_H3(g, con, ls, V);
    vgq = vg * 2^12; ilq = il * 2^24; ifq = iff * 2^24; vdcq = vdc * 2^24;
    out(k, :) = [sum(g .* 2.^(0:5)), con, ls, vgq.', ilq.', ifq.', vdcq, ...
        vps_adc_codes_H3(vgq, ilq, ifq, vdcq), shoot];
end
assert(all(out(:) == round(out(:))), 'vps_vectors_H3: non-integer value');
fprintf('%d steps: |inverter current| max %.1f A, load current max %.1f A, Vdc %.1f..%.1f V, shoot %d\n', ...
    n, max(abs(out(:, 10:12)), [], 'all') / 2^24, max(abs(out(:, 7:9)), [], 'all') / 2^24, ...
    min(out(:, 13)) / 2^24, max(out(:, 13)) / 2^24, out(end, 21));
odir = fullfile(here, '..', 'sim', 'out', 'H3');
if ~exist(odir, 'dir'), mkdir(odir); end
fid = fopen(fullfile(odir, 'vps_vectors.txt'), 'w');
fprintf(fid, [repmat('%d ', 1, 20) '%d\n'], out.');
fclose(fid);
fprintf('Wrote %s\n', fullfile(odir, 'vps_vectors.txt'));
end
