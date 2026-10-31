%% H3: check the virtual power stage against the Simscape model
% Runs apf_vps_H3.slx (controller + virtual power stage) twice, in fixed point
% (integer math, exactly as the FPGA will compute it) and with real numbers, and
% compares both with apf_system.slx (controller + Simscape power stage):
%   fixed vs real numbers  -> how much the FPGA's integer math changes the result
%   VPS vs Simscape        -> how well the simple plant equations match the full circuit
%
%   >> vps_check_H3            % about 2 min; figures in results/H3, copied to docs/figures

here = fileparts(mfilename('fullpath'));
if isempty(here), here = pwd; end
outdir = fullfile(here, 'results', 'H3');
docdir = fullfile(here, '..', 'docs');
if ~exist(outdir, 'dir'), mkdir(outdir); end
addpath(here);
run(fullfile(here, 'apf_params.m'));
if ~exist(fullfile(here, 'apf_vps_H3.slx'), 'file'), build_apf_vps_H3; end
load_system(fullfile(here, 'apf_vps_H3.slx'));

%% 1. Run the virtual power stage (fixed point and real numbers)
runs = struct([]);
for fx = [true false]
    V = vps_params_H3(fx); %#ok<NASGU>  (read by the model)
    tic;
    o = sim('apf_vps_H3', 'StopTime', '1.0');
    r = struct('name', '', 'secs', toc, 'd', unpack(o.sim_power, o.sim_ctrl), 'shoot', o.sim_shoot(end));
    if fx, r.name = 'VPS fixed point (FPGA)'; else, r.name = 'VPS real numbers'; end
    fprintf('%-24s simulated 1 s in %.0f s, shoot-through steps %d\n', r.name, r.secs, r.shoot);
    runs = [runs, r]; %#ok<AGROW>
end

%% 2. Simscape reference (apf_system.slx): saved H2 run if available, else run it
ref = fullfile(here, 'results', 'H2', 'R0_no_ADC.mat');
if isfile(ref)
    d = load(ref);
else
    load_system(fullfile(here, 'apf_system.slx'));
    o = sim('apf_system', 'StopTime', '1.0');
    d = unpack(o.sim_power, o.sim_ctrl);
end
runs = [struct('name', 'Simscape (apf_system.slx)', 'secs', NaN, 'd', d, 'shoot', NaN), runs];
save(fullfile(outdir, 'vps_runs.mat'), 'runs');   % reused by vps_rtl_check_H3.m

%% 3. Compare
fprintf('\n%-26s %16s %16s %7s %8s %9s %9s %9s\n', 'plant', 'grid THD 33 ohm', 'grid THD 22 ohm', 'angle', 'Vdc dip', 'lock ms', 'switch ms', 'faults');
for k = 1:numel(runs)
    m = metrics(runs(k).d);
    runs(k).m = m;
    fprintf('%-26s %8.2f%% +-%4.2f %8.2f%% +-%4.2f %+7.1f %8.1f %9.1f %9.1f %9s\n', runs(k).name, ...
        100 * m.thd(1), 100 * m.std(1), 100 * m.thd(2), 100 * m.std(2), m.angle, m.dip, ...
        1e3 * m.t_lock, 1e3 * m.t_switch, m.faults);
end
fprintf('load current THD (no APF): Simscape %.1f %%, VPS %.1f %%\n', 100 * runs(1).m.thd_load, 100 * runs(2).m.thd_load);
a = runs(2).d; b = runs(3).d;
fprintf('fixed vs real numbers: max |grid current a| difference %.4f A, max |Vdc| difference %.3f V\n', ...
    max(abs(a.isa - b.isa)), max(abs(a.vdc - b.vdc)));
w = a.t < a.t_first_switch;
fprintf('   before switching starts (plant alone, no feedback): %.2e A, %.2e V\n', ...
    max(abs(a.isa(w) - b.isa(w))), max(abs(a.vdc(w) - b.vdc(w))));

%% 4. Figures
fig = figure('Position', [100 100 1000 700], 'Visible', 'off');
lightTheme(fig);
tl = tiledlayout(fig, 3, 1, 'TileSpacing', 'compact');
cols = {[0.5 0.5 0.5], [0 0.447 0.741], [0.85 0.325 0.098]};
sty = {'-', '-', '--'};
for k = 1:numel(runs)
    d = runs(k).d; w = d.t >= 0.60 & d.t < 0.64;
    nexttile(1); hold on; plot(1e3 * (d.t(w) - 0.6), d.isa(w), sty{k}, 'Color', cols{k});
    nexttile(2); hold on; plot(1e3 * (d.t(w) - 0.6), d.ila(w), sty{k}, 'Color', cols{k});
    nexttile(3); hold on; plot(d.t, d.vdc, sty{k}, 'Color', cols{k});
end
nexttile(1); ylabel('grid current a (A)'); grid on
legend(arrayfun(@(r) sprintf('%s: THD %.1f %%', r.name, 100 * r.m.thd(1)), runs, 'UniformOutput', false), ...
    'Location', 'southeast', 'Interpreter', 'none');
title('Steady state, 33 \Omega load (t = 0.60-0.64 s)');
nexttile(2); ylabel('load current a (A)'); xlabel('ms'); grid on
nexttile(3); ylabel('DC link (V)'); xlabel('time (s)'); grid on
title('Whole run: start-up, DC-link charge to 300 V, load step at 0.7 s');
exportgraphics(fig, fullfile(outdir, 'H3_vps_vs_simscape.png'), 'Resolution', 120);
copyfile(fullfile(outdir, 'H3_vps_vs_simscape.png'), fullfile(docdir, 'figures', 'H3_vps_vs_simscape.png'));
fprintf('Figure: docs/figures/H3_vps_vs_simscape.png\n');
close all


%% ---- helpers ----
function d = unpack(p, c)
x = p.signals.values;
d.t = p.time; d.vga = x(:, 1); d.ila = x(:, 4); d.ifa = x(:, 7); d.isa = x(:, 10); d.vdc = x(:, 13);
d.tc = c.time;
d.ctrl = reshape(c.signals.values, [], numel(c.time)).';
d.t_first_switch = min([d.tc(find(d.ctrl(:, 3) > 0.5, 1)); Inf]);
end

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
m.thd_load = thd(d.ila(w));
m.dip = 300 - min(d.vdc(t >= 0.7 & t < 0.8));
end

function w = window(t, t0, dt)
k0 = find(t >= t0 - dt / 2, 1);
w = (k0:k0 + round(0.1 / dt) - 1)';          % 5 grid cycles
end

function r = thd(x)
n = numel(x);
F = fft(x(:)) * 2 / n;
a = abs(F((1:40) * 5 + 1));
r = sqrt(sum(a(2:end).^2)) / a(1);
end

function lightTheme(fig)
try
    theme(fig, 'light');
catch
end
end
