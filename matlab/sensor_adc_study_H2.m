%% H2: sensor and ADC study for the DE2-115 board, in Simulink
% Same 16 measurement chains as H1 (docs/sensor_adc_study_H1.md), now run in the
% switching Simulink model apf_system_H2.slx (= apf_system.slx + the block
% "Sensors + ADC (H2)"), plus a fine sweep of the delay before the ADC sample.
%
%   >> sensor_adc_study_H2          % runs what is missing, then table + figures
%   >> rerun = true; sensor_adc_study_H2    % run every simulation again
%
% Each 1 s run takes about 30 s; the runs go in parallel (Parallel Computing
% Toolbox). Results are saved in matlab/results/H2/*.mat, so the analysis
% sections can be rerun on their own. Figures and the results table are also
% copied to docs/ so they are kept in git.

here = fileparts(mfilename('fullpath'));
if isempty(here), here = pwd; end
outdir = fullfile(here, 'results', 'H2');
docdir = fullfile(here, '..', 'docs');
if ~exist(outdir, 'dir'), mkdir(outdir); end
if ~exist('rerun', 'var'), rerun = false; end
addpath(here);
run(fullfile(here, 'apf_params.m'));
mdl = 'apf_system_H2';
if ~exist(fullfile(here, [mdl '.slx']), 'file'), build_apf_model_H2; end

%% 1. Measurement chains
% Sensor time constants from datasheet step-response times (tau = t90 / 2.3):
%   LEM LV 25-P voltage transducer, 40 us to 90 % (at R1 = 25 kOhm)   -> 17.4 us
%   LEM LA 25-NP current transducer, 1 us to 90 %                      -> 0.43 us
% LV 25-P with the H1 resistor values (frontend_sizing_H1.m): its t90 is an L/R
% time of the primary (~0.44 H), so grid channel R1 = 10 kOhm -> 42.8 us,
% DC link R1 = 30 kOhm -> 14.5 us.
% ADC: AD7606 4 us conversion + serial read -> codes at 8-10 us; on-chip filter
% group delay 15 us (+-5 V range) or 11 us (+-10 V); AD7606B 7.5 us (+-10 V).
% LTC2308 multiplexed, 2 us per channel. NI 9244/9246 delta-sigma: 0.80 ms.
lem = {'tauV', 17.4e-6, 'tauI', 0.43e-6, 'tauDC', 17.4e-6};
real_lags = {'tauV', 42.8e-6, 'tauI', 0.43e-6, 'tauDC', 14.5e-6};
scen = {
  % name                   description                                      settings
  'S0_ideal',            'Ideal sensors, 12-bit ADC',                       {}
  'S1_LEM_AD7606',       'LEM LV 25-P + LA 25-NP, AD7606 (simultaneous)',   [lem, {'conv', 8e-6}]
  'S2_LEM_LTC2308',      'LEM sensors, LTC2308 (multiplexed, 2 us/ch)',     [lem, {'skew', 2e-6, 'conv', 15e-6}]
  'S3_isoamp_AD7606',    'Isolated-amp voltage + LA 25-NP, AD7606',         {'tauV', 1e-6, 'tauI', 0.43e-6, 'tauDC', 1e-6, 'conv', 8e-6}
  'S4_cRIO_NI9215',      'LEM sensors, cRIO NI 9215 + link to DE2-115',     [lem, {'conv', 35e-6}]
  'S5_cRIO_NI9244',      'cRIO NI 9244/9246 delta-sigma (0.8 ms delay)',    {'delay', 802e-6, 'conv', 35e-6}
  'S6_LEM_AD7606_noisy', 'As S1 with 3 counts rms noise',                   [lem, {'conv', 8e-6, 'noise', 3}]
  'S7_delay100us',       'As S1 + 100 us extra delay',                      [lem, {'conv', 8e-6, 'delay', 100e-6}]
  'S8_delay200us',       'As S1 + 200 us extra delay',                      [lem, {'conv', 8e-6, 'delay', 200e-6}]
  'S9_delay400us',       'As S1 + 400 us extra delay',                      [lem, {'conv', 8e-6, 'delay', 400e-6}]
  'S10_LEM_AD7606_real', 'LEM + AD7606 +-5 V, all real lags',               [real_lags, {'delay', 15e-6, 'conv', 10e-6}]
  'S11_AD7606_10V',      'As S10 on the AD7606 +-10 V range',               [real_lags, {'delay', 11e-6, 'conv', 10e-6}]
  'S12_AD7606B_10V',     'As S10 with AD7606B, +-10 V range',               [real_lags, {'delay', 7.5e-6, 'conv', 10e-6}]
  'S13_fastV_AD7606',    'As S10 with a fast grid-voltage sensor',          {'tauV', 1e-6, 'tauI', 0.43e-6, 'tauDC', 14.5e-6, 'delay', 15e-6, 'conv', 10e-6}
  'S14_delay30us',       'As S1 + 30 us extra delay',                       [lem, {'conv', 8e-6, 'delay', 30e-6}]
  'S15_delay50us',       'As S1 + 50 us extra delay',                       [lem, {'conv', 8e-6, 'delay', 50e-6}]
  'R0_no_ADC',           'Reference: ideal sensors and ideal ADC (= apf_system.slx)', {'adc', false}
  };
% Repeatability: the same chains with another noise seed.
for s = {'S0_ideal', 'S10_LEM_AD7606_real', 'S11_AD7606_10V'}
    k = find(strcmp(scen(:, 1), s{1}));
    scen(end + 1, :) = {['seed777_' s{1}], [scen{k, 2} ', seed 777'], [scen{k, 3}, {'seed', 777}]}; %#ok<SAGROW>
end
% Delay sweep: S1 (LEM + AD7606 timing) plus 0..200 us before the sample, two seeds.
sweep_us = 0:5:200;
for d = sweep_us
    for seed = [12345 777]
        scen(end + 1, :) = {sprintf('D%03d_seed%d', d, seed), sprintf('S1 + %d us delay', d), ...
            [lem, {'conv', 8e-6, 'delay', d * 1e-6, 'seed', seed}]}; %#ok<SAGROW>
    end
end

%% 2. Run the simulations (only the ones without a saved result, unless rerun)
todo = [];
for k = 1:size(scen, 1)
    if rerun || ~isfile(fullfile(outdir, [scen{k, 1} '.mat'])), todo(end + 1) = k; end %#ok<SAGROW>
end
if ~isempty(todo)
    load_system(fullfile(here, [mdl '.slx']));
    in = Simulink.SimulationInput.empty;
    for k = todo
        in(end + 1) = Simulink.SimulationInput(mdl) ...
            .setVariable('S', sensor_params_H2(scen{k, 3}{:})) ...
            .setModelParameter('StopTime', '1.0') ...
            .setPostSimFcn(@keepSignals); %#ok<SAGROW>
    end
    if isempty(gcp('nocreate')), parpool('Processes', min(5, feature('numcores'))); end
    fprintf('Running %d simulations ...\n', numel(in));
    tic;
    out = parsim(in, 'ShowProgress', 'on', 'TransferBaseWorkspaceVariables', 'on', ...
        'SetupFcn', @() addpath(here));
    fprintf('Simulations took %.1f min\n', toc / 60);
    for j = 1:numel(out)
        k = todo(j);
        if ~isempty(out(j).ErrorMessage)
            fprintf('%s FAILED: %s\n', scen{k, 1}, out(j).ErrorMessage); continue;
        end
        r = out(j).r; %#ok<NASGU>
        save(fullfile(outdir, [scen{k, 1} '.mat']), '-struct', 'r');
    end
    clear out in
end

%% 3. Grid current THD per chain
% Same method as H1: THD of grid current a over every 5-cycle window that starts
% on a cycle boundary in the steady state of each load, mean +- std:
%   33 ohm: windows starting 0.40 .. 0.60 s;  22 ohm: 0.80 .. 0.90 s (step at 0.7 s)
res = struct([]);
for k = 1:size(scen, 1)
    f = fullfile(outdir, [scen{k, 1} '.mat']);
    if ~isfile(f), continue; end
    r = analyzeRun(load(f));
    r.name = scen{k, 1}; r.desc = scen{k, 2};
    res = [res, r]; %#ok<AGROW>
end
names = {res.name};
main = ~startsWith(names, {'D', 'seed777_'});

% H1 results (Questa, real apf_core RTL with the testbench's plant model), mean
% grid THD 33 / 22 ohm, from docs/sensor_adc_study_H1.md
H1 = struct('S0_ideal', [4.40 3.50], 'S1_LEM_AD7606', [4.43 3.53], 'S2_LEM_LTC2308', [4.48 3.51], ...
    'S3_isoamp_AD7606', [4.39 3.50], 'S4_cRIO_NI9215', [4.43 3.53], 'S5_cRIO_NI9244', [26.1 26.1], ...
    'S6_LEM_AD7606_noisy', [4.41 3.49], 'S7_delay100us', [7.32 6.20], 'S8_delay200us', [14.14 14.90], ...
    'S9_delay400us', [27.08 43.99], 'S10_LEM_AD7606_real', [4.72 3.51], 'S11_AD7606_10V', [4.10 3.42], ...
    'S12_AD7606B_10V', [4.08 3.45], 'S13_fastV_AD7606', [4.62 3.48], 'S14_delay30us', [5.26 3.85], ...
    'S15_delay50us', [5.14 3.45]);

fprintf('\n%-22s %16s %16s %13s %7s %8s %6s\n', 'chain', 'grid THD 33 ohm', 'grid THD 22 ohm', 'H1 (RTL)', 'angle', 'Vdc dip', 'faults');
fprintf('%-22s %16s %16s %13s %7s %8s\n', '', '(mean +- std)', '(mean +- std)', '33 / 22 ohm', '(deg)', '(V)');
for r = res(main | startsWith(names, 'seed777_'))
    h1 = '';
    if isfield(H1, r.name), h1 = sprintf('%5.2f / %5.2f', H1.(r.name)); end
    fprintf('%-22s %8.2f%% +-%4.2f %8.2f%% +-%4.2f %13s %+7.1f %8.1f %6s  %s\n', r.name, ...
        100 * r.thd_grid(1), 100 * r.thd_std(1), 100 * r.thd_grid(2), 100 * r.thd_std(2), h1, ...
        r.angle(1), r.vdc_dip, r.faults, r.desc);
end
fprintf('(load current THD without the APF: %.1f %% at 33 ohm)\n', 100 * res(1).thd_load);

% table for the report (kept in git)
T = table(string({res(main).name}).', string({res(main).desc}).', ...
    round(100 * arrayfun(@(r) r.thd_grid(1), res(main)).', 2), round(100 * arrayfun(@(r) r.thd_std(1), res(main)).', 2), ...
    round(100 * arrayfun(@(r) r.thd_grid(2), res(main)).', 2), round(100 * arrayfun(@(r) r.thd_std(2), res(main)).', 2), ...
    round(arrayfun(@(r) r.vdc_dip, res(main)).', 1), string({res(main).faults}).', ...
    'VariableNames', {'chain', 'description', 'thd33_pct', 'std33', 'thd22_pct', 'std22', 'vdc_dip_V', 'faults'});
writetable(T, fullfile(docdir, 'sensor_adc_study_H2_results.csv'));

%% 4. Delay sweep: how much delay before the sample the controller tolerates
sw = res(startsWith(names, 'D'));
d_us = cellfun(@(n) sscanf(n, 'D%d'), {sw.name});
seed = cellfun(@(n) sscanf(n(strfind(n, 'seed') + 4:end), '%d'), {sw.name});
m33 = arrayfun(@(r) r.thd_grid(1), sw) * 100;  m22 = arrayfun(@(r) r.thd_grid(2), sw) * 100;
s33 = arrayfun(@(r) r.thd_std(1), sw) * 100;   s22 = arrayfun(@(r) r.thd_std(2), sw) * 100;
fprintf('\nDelay sweep (S1 + delay before the sample), grid THD %% 33 / 22 ohm:\n');
fprintf('%6s %16s %16s\n', 'delay', 'seed 12345', 'seed 777');
for d = sweep_us
    a = find(d_us == d & seed == 12345); b = find(d_us == d & seed == 777);
    if isempty(a) || isempty(b), continue; end
    fprintf('%4d us %7.2f / %5.2f %7.2f / %5.2f\n', d, m33(a), m22(a), m33(b), m22(b));
end
% first delay at which the 33 ohm mean (both seeds) passes 5 %
avg33 = arrayfun(@(d) mean(m33(d_us == d)), sweep_us);
k5 = find(avg33 > 5, 1);
if ~isempty(k5), fprintf('5 %% limit (33 ohm, mean of both seeds) first passed at %d us\n', sweep_us(k5)); end

%% 5. Figures
ok = main & arrayfun(@(r) ~isnan(r.thd_grid(1)), res);
rm = res(ok);
fig = figure('Name', 'H2 grid THD', 'Position', [100 100 1100 480], 'Visible', 'off');
lightTheme(fig);
m = 100 * reshape([rm.thd_grid], 2, []).';
s = 100 * reshape([rm.thd_std], 2, []).';
b = bar(m); hold on
for c = 1:2
    errorbar(b(c).XEndPoints, m(:, c), s(:, c), 'k', 'LineStyle', 'none', 'HandleVisibility', 'off');
end
h1x = []; h1y = [];
for k = 1:numel(rm)
    if isfield(H1, rm(k).name), h1x(end + 1) = b(1).XEndPoints(k); h1y(end + 1) = H1.(rm(k).name)(1); end %#ok<SAGROW>
end
plot(h1x, h1y, 'kd', 'MarkerFaceColor', 'w', 'MarkerSize', 6);
ycap = 10;
ylim([0 ycap]);
for k = find(m(:, 1) > ycap).'
    text(k, ycap - 0.4, sprintf('%.0f %%', m(k, 1)), 'HorizontalAlignment', 'center', 'FontWeight', 'bold', ...
        'Color', 'w', 'BackgroundColor', [0.2 0.2 0.2], 'Margin', 1);
end
set(gca, 'XTick', 1:numel(rm), 'XTickLabel', strrep({rm.name}, '_', '\_'), 'XTickLabelRotation', 30);
ylabel('grid current THD (%), mean \pm std over windows');
legend({'33 \Omega load (Simulink, H2)', '22 \Omega load (Simulink, H2)', '33 \Omega, H1 RTL result'}, 'Location', 'northwest');
yline(5, ':', 'IEEE 519 5 %', 'HandleVisibility', 'off', 'LabelHorizontalAlignment', 'left'); grid on
title('Grid current THD with each sensor / ADC chain (bars above 10 % are clipped)');
exportgraphics(fig, fullfile(outdir, 'H2_thd_bar.png'), 'Resolution', 120);

fig = figure('Name', 'H2 delay sweep', 'Position', [100 100 900 480], 'Visible', 'off');
lightTheme(fig);
hold on
mk = {'o', 's'};
cols = [0 0.447 0.741; 0.85 0.325 0.098];
for c = 1:2
    for j = 1:2
        sd = [12345 777]; sel = seed == sd(j);
        [dd, o] = sort(d_us(sel));
        if c == 1, mm = m33(sel); ss = s33(sel); else, mm = m22(sel); ss = s22(sel); end
        errorbar(dd, mm(o), ss(o), ['-' mk{j}], 'Color', cols(c, :), 'MarkerSize', 4, ...
            'MarkerFaceColor', cols(c, :) * (j == 1) + [1 1 1] * (j == 2));
    end
end
yline(5, ':', 'IEEE 519 5 %', 'HandleVisibility', 'off', 'LabelHorizontalAlignment', 'right');
yl = ylim;
patch([7.5 15 15 7.5], yl([1 1 2 2]), [0.5 0.5 0.5], 'FaceAlpha', 0.15, 'EdgeColor', 'none', 'HandleVisibility', 'off');
text(16, yl(2) - 0.05 * diff(yl), {'AD7606 filter delay', '7.5 / 11 / 15 \mus'}, 'Color', [0.3 0.3 0.3]);
ylim(yl);
grid on; xlabel('extra delay before the ADC sample (\mus), on top of the LEM sensor lags');
ylabel('grid current THD (%)');
legend({'33 \Omega, seed 12345', '33 \Omega, seed 777', '22 \Omega, seed 12345', '22 \Omega, seed 777'}, 'Location', 'southeast');
title('How much measurement delay the controller tolerates (cRIO NI 9244 = 800 \mus, off the chart)');
exportgraphics(fig, fullfile(outdir, 'H2_delay_sweep.png'), 'Resolution', 120);

fig = figure('Name', 'H2 waveforms', 'Position', [100 100 900 650], 'Visible', 'off');
lightTheme(fig);
show = {'S0_ideal', 'S12_AD7606B_10V', 'S9_delay400us', 'S5_cRIO_NI9244'};
show = show(ismember(show, names));
tl = tiledlayout(fig, numel(show), 1, 'TileSpacing', 'compact');
for k = 1:numel(show)
    nexttile;
    d = load(fullfile(outdir, [show{k} '.mat']));
    w = d.t >= 0.60 & d.t < 0.64;
    plot(1e3 * (d.t(w) - 0.6), d.ila(w), 'Color', [0.85 0.4 0.4]); hold on
    plot(1e3 * (d.t(w) - 0.6), d.isa(w), 'b'); grid on; ylabel('A');
    r = res(strcmp(names, show{k}));
    title(sprintf('%s: grid THD %.1f %%', strrep(show{k}, '_', '\_'), 100 * r.thd_grid(1)));
end
xlabel(tl, 'ms after t = 0.6 s (33 \Omega load)');
legend('load current a', 'grid current a', 'Location', 'southeast');
exportgraphics(fig, fullfile(outdir, 'H2_waveforms.png'), 'Resolution', 120);

figs = {'H2_thd_bar.png', 'H2_delay_sweep.png', 'H2_waveforms.png'};
for k = 1:numel(figs)
    copyfile(fullfile(outdir, figs{k}), fullfile(docdir, 'figures', figs{k}));
end
fprintf('\nFigures in %s (copied to docs/figures), table in docs/sensor_adc_study_H2_results.csv\n', outdir);
if usejava('desktop'), set(findall(0, 'Type', 'figure', 'Visible', 'off'), 'Visible', 'on'); end


%% ---- helper functions ----
function o = keepSignals(o)
% Runs on the parallel worker: keep only what the analysis needs (phase a, Vdc,
% controller status), so 100 runs fit in memory.
p = o.sim_power; c = o.sim_ctrl;
x = p.signals.values;
r.t = p.time; r.vga = x(:, 1); r.ila = x(:, 4); r.ifa = x(:, 7); r.isa = x(:, 10); r.vdc = x(:, 13);
r.tc = c.time;
r.ctrl = reshape(c.signals.values, [], numel(c.time)).';
o = struct('r', r);
end

function r = analyzeRun(d)
t = d.t; dt = median(diff(t));
c = d.ctrl;                          % [locked ready switching faults(4) freq idc vdc_target vdc_avg pll_err]
r.t_switch = firstTime(d.tc, c(:, 3) > 0.5);
fl = max(c(:, 4:7), [], 1) > 0.5;    % [measurement over_current over_voltage pll_lost]
r.faults = char('0' + fliplr(fl));   % printed as {pll ov oc meas}, like apf_core fault_flags
r.thd_grid = [NaN NaN]; r.thd_std = [NaN NaN]; r.angle = [NaN NaN]; r.thd_load = NaN;
spans = [0.40 0.60; 0.80 0.90];
for k = 1:2
    if spans(k, 2) + 0.1 > t(end) + 2 * dt, continue; end
    starts = spans(k, 1):0.02:spans(k, 2) + 1e-9;
    th = arrayfun(@(t0) thd(d.isa(window(t, t0, 5, dt))), starts);
    r.thd_grid(k) = mean(th); r.thd_std(k) = std(th);
    w = window(t, spans(k, 1), 5, dt);
    Fv = fft(d.vga(w)); Fi = fft(d.isa(w));
    r.angle(k) = mod(rad2deg(angle(Fi(6)) - angle(Fv(6))) + 180, 360) - 180;
    if k == 1, r.thd_load = thd(d.ila(w)); end
end
ws = t >= 0.7 & t < 0.8;
r.vdc_dip = 300 - min(d.vdc(ws));
end

function x = firstTime(t, m)
x = min([t(find(m, 1)); NaN]);
end

function w = window(t, t0, cycles, dt)
n = round(cycles * 0.02 / dt);
k0 = find(t >= t0 - dt / 2, 1);
w = (k0:k0 + n - 1)';
end

function r = thd(x)
% THD from harmonics 2..40 of exactly 5 grid cycles.
cycles = 5;
n = numel(x);
F = fft(x(:)) * 2 / n;
a = abs(F((1:40) * cycles + 1));
r = sqrt(sum(a(2:end).^2)) / a(1);
end

function lightTheme(fig)
try
    theme(fig, 'light');
catch
end
end
