%% H3: the board design (real FPGA code) against the Simulink models
% Reads the closed-loop run of sim/tb_apf_vps_H3.sv - apf_core + the virtual
% power stage + the ADC stand-in, exactly what will run on the DE2-115 - and
% compares it with the Simulink runs saved by vps_check_H3.m.
%
%   >> vps_rtl_check_H3        % needs sim/out/H3/apf_vps.csv (sim/run_vps_H3.do)

here = fileparts(mfilename('fullpath'));
if isempty(here), here = pwd; end
outdir = fullfile(here, 'results', 'H3');
csv = fullfile(here, '..', 'sim', 'out', 'H3', 'apf_vps.csv');
if ~isfile(csv), error('Run the Questa closed loop first: vsim -c -do sim/run_vps_H3.do'); end
if ~isfile(fullfile(outdir, 'vps_runs.mat')), vps_check_H3; end
S = load(fullfile(outdir, 'vps_runs.mat'));
runs = S.runs;

T = readtable(csv);
d.t = T.t; d.vga = T.vga; d.ila = T.ila; d.ifa = T.ifa; d.isa = T.isa; d.vdc = T.vdc;
d.tc = T.t;
d.ctrl = [T.locked, T.ready, T.switching, bitget(T.faults, 1), bitget(T.faults, 2), ...
          bitget(T.faults, 3), bitget(T.faults, 4)];
runs(end + 1) = struct('name', 'FPGA code (apf_core + VPS, Questa)', 'secs', NaN, 'd', d, 'shoot', NaN);

fprintf('\n%-36s %16s %16s %7s %8s %9s %9s %7s\n', 'plant', 'grid THD 33 ohm', 'grid THD 22 ohm', 'angle', 'Vdc dip', 'lock ms', 'switch ms', 'faults');
for k = 1:numel(runs)
    m = metrics(runs(k).d);
    runs(k).m = m;
    fprintf('%-36s %8.2f%% +-%4.2f %8.2f%% +-%4.2f %+7.1f %8.1f %9.1f %9.1f %7s\n', runs(k).name, ...
        100 * m.thd(1), 100 * m.std(1), 100 * m.thd(2), 100 * m.std(2), m.angle, m.dip, ...
        1e3 * m.t_lock, 1e3 * m.t_switch, m.faults);
end
fprintf('final Vdc on the FPGA: %.1f V\n', d.vdc(end));

fig = figure('Position', [100 100 1000 650], 'Visible', 'off');
try, theme(fig, 'light'); catch, end
tl = tiledlayout(fig, 2, 1, 'TileSpacing', 'compact');
pick = [1 2 numel(runs)];                    % Simscape, VPS Simulink fixed point, FPGA
cols = {[0.6 0.6 0.6], [0 0.447 0.741], [0.85 0.325 0.098]};
sty = {'-', '-', '--'};
for j = 1:3
    r = runs(pick(j)); w = r.d.t >= 0.60 & r.d.t < 0.64;
    nexttile(1); hold on; plot(1e3 * (r.d.t(w) - 0.6), r.d.isa(w), sty{j}, 'Color', cols{j});
    nexttile(2); hold on; plot(r.d.t, r.d.vdc, sty{j}, 'Color', cols{j});
end
nexttile(1); grid on; ylabel('grid current a (A)'); xlabel('ms after t = 0.6 s');
legend(arrayfun(@(r) sprintf('%s: THD %.1f %%', r.name, 100 * r.m.thd(1)), runs(pick), 'UniformOutput', false), ...
    'Location', 'southeast', 'Interpreter', 'none');
title('Steady state, 33 \Omega load');
nexttile(2); grid on; ylabel('DC link (V)'); xlabel('time (s)');
title('Start-up, DC-link charge to 300 V, load step at 0.7 s');
exportgraphics(fig, fullfile(outdir, 'H3_fpga_closed_loop.png'), 'Resolution', 120);
copyfile(fullfile(outdir, 'H3_fpga_closed_loop.png'), fullfile(here, '..', 'docs', 'figures', 'H3_fpga_closed_loop.png'));
fprintf('Figure: docs/figures/H3_fpga_closed_loop.png\n');
close all


function m = metrics(d)
t = d.t; dt = median(diff(t)); c = d.ctrl;
m.t_lock = min([d.tc(find(c(:, 1) > 0.5, 1)); NaN]);
m.t_switch = min([d.tc(find(c(:, 3) > 0.5, 1)); NaN]);
m.faults = char('0' + fliplr(max(c(:, 4:7), [], 1) > 0.5));
spans = [0.40 0.60; 0.80 0.90];
for k = 1:2
    th = arrayfun(@(t0) thd(d.isa(window(t, t0, dt))), spans(k, 1):0.02:spans(k, 2) + 1e-9);
    m.thd(k) = mean(th); m.std(k) = std(th);
end
w = window(t, 0.40, dt);
Fv = fft(d.vga(w)); Fi = fft(d.isa(w));
m.angle = mod(rad2deg(angle(Fi(6)) - angle(Fv(6))) + 180, 360) - 180;
m.dip = 300 - min(d.vdc(t >= 0.7 & t < 0.8));
end

function w = window(t, t0, dt)
k0 = find(t >= t0 - dt / 2, 1);
w = (k0:k0 + round(0.1 / dt) - 1)';
end

function r = thd(x)
n = numel(x);
F = fft(x(:)) * 2 / n;
a = abs(F((1:40) * 5 + 1));
r = sqrt(sum(a(2:end).^2)) / a(1);
end
