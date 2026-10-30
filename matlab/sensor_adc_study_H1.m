function res = sensor_adc_study_H1(outdir)
% H1: compares the measurement chains run by sim/run_sensor_study_H1.do.
% Each CSV is a full closed-loop run of the real apf_core RTL (tb_apf_system_H1).
% THD per 5-cycle window as in model/analyze_system.py, averaged over all
% steady-state windows of each load (see the comment in the loop).
if nargin < 1
    outdir = fullfile(fileparts(mfilename('fullpath')), '..', 'sim', 'out', 'H1');
end

scen = {
    'S0_ideal',            'Ideal sensors, 12-bit ADC (original testbench)'
    'S1_LEM_AD7606',       'LEM LV 25-P + LA 25-NP, AD7606 (simultaneous)'
    'S2_LEM_LTC2308',      'LEM LV 25-P + LA 25-NP, LTC2308 (multiplexed)'
    'S3_isoamp_AD7606',    'Isolated-amp voltage + LA 25-NP, AD7606'
    'S4_cRIO_NI9215',      'LEM sensors, cRIO NI 9215 + link to DE2-115'
    'S5_cRIO_NI9244',      'cRIO NI 9244/9246 delta-sigma (0.8 ms delay)'
    'S6_LEM_AD7606_noisy', 'As S1 with 3 counts rms noise'
    'S7_delay100us',       'As S1 + 100 us extra delay'
    'S8_delay200us',       'As S1 + 200 us extra delay'
    'S9_delay400us',       'As S1 + 400 us extra delay'
    'S10_LEM_AD7606_real', 'LEM + AD7606 +-5 V, all real lags'
    'S11_AD7606_10V',      'As S10 on the AD7606 +-10 V range'
    'S12_AD7606B_10V',     'As S10 with AD7606B, +-10 V range'
    'S13_fastV_AD7606',    'As S10 with a fast grid-voltage sensor'
    'S14_delay30us',       'As S1 + 30 us extra delay'
    'S15_delay50us',       'As S1 + 50 us extra delay'
    };
% Delay of the current channels BEFORE the sample instant (sensor lag + filter or
% transport delay), us. The conversion/transfer time after the sample (CONV) is not
% included: S1 (8 us) and S4 (35 us) give the same result, so it does not matter.
lat_names = {'S1_LEM_AD7606', 'S12_AD7606B_10V', 'S11_AD7606_10V', 'S10_LEM_AD7606_real', ...
             'S14_delay30us', 'S15_delay50us', 'S7_delay100us', 'S8_delay200us', 'S9_delay400us', 'S5_cRIO_NI9244'};
lat_us    = [0.43, 7.9, 11.4, 15.4, 30.4, 50.4, 100.4, 200.4, 400.4, 802];

res = struct([]);
traces = struct();
for k = 1:size(scen, 1)
    f = fullfile(outdir, [scen{k, 1} '.csv']);
    if ~isfile(f), fprintf('%-20s missing (%s)\n', scen{k, 1}, f); continue; end
    d = readtable(f);
    t = d.t; dt = median(diff(t));
    if t(end) < 1 - 2 * dt
        fprintf('%-20s incomplete (ends at %.3f s), skipped\n', scen{k, 1}, t(end)); continue;
    end
    r.name = scen{k, 1}; r.desc = scen{k, 2};
    r.t_switch = firstTime(t, d.switching > 0);
    r.faults = max(d.faults);
    r.t_fault = firstTime(t, d.faults > 0);
    % Grid THD from every 5-cycle window that starts on a cycle boundary inside the
    % steady state of each load (one window varies by +-0.5 points at 33 ohm, so
    % single-window numbers cannot rank chains that differ by less than that):
    %   33 ohm: windows starting 0.40 .. 0.60 s (Vdc settled, ends before the 0.7 s step)
    %   22 ohm: windows starting 0.80 .. 0.90 s (0.1 s after the step, ends at 1.0 s)
    r.thd_grid = [NaN NaN]; r.thd_std = [NaN NaN]; r.angle = [NaN NaN]; r.vdc = [NaN NaN];
    spans = [0.40 0.60; 0.80 0.90];
    for c = 1:2
        if spans(c, 2) + 0.1 > t(end) + 2 * dt, continue; end
        starts = spans(c, 1):0.02:spans(c, 2) + 1e-9;
        th = arrayfun(@(t0) thd(d.isa(window(t, t0, 5, dt))), starts);
        r.thd_grid(c) = mean(th); r.thd_std(c) = std(th);
        w = window(t, spans(c, 1), 5, dt);
        Fv = fft(d.vga(w)); Fi = fft(d.isa(w));
        r.angle(c) = mod(rad2deg(angle(Fi(6)) - angle(Fv(6))) + 180, 360) - 180;
        r.vdc(c) = mean(d.vdc(w));
        if c == 1, [~, r.h_grid] = thd(d.isa(w)); [r.thd_load, ~] = thd(d.ila(w)); end
    end
    % load-step dip: Vdc minimum in the 100 ms after the step
    ws = t >= 0.7 & t < 0.8;
    r.vdc_dip = 300 - min(d.vdc(ws));
    res = [res, r]; %#ok<AGROW>
    w2 = window(t, 0.60, 2, dt);
    traces.(scen{k, 1}) = struct('t', t(w2) - t(w2(1)), 'isa', d.isa(w2), 'ila', d.ila(w2));
end

% ---- table ----
fprintf('\n%-20s %7s %16s %16s %7s %8s %7s  %s\n', 'scenario', 'switch', 'grid THD 33 ohm', 'grid THD 22 ohm', 'angle', 'Vdc dip', 'faults', '');
fprintf('%-20s %7s %16s %16s %7s %8s %7s\n', '', '(ms)', '(mean +- std)', '(mean +- std)', '(deg)', '(V)', '');
for r = res
    fprintf('%-20s %7.1f %8.2f%% +-%4.2f %8.2f%% +-%4.2f %+7.1f %8.1f %7s  %s\n', r.name, 1e3 * r.t_switch, ...
        100 * r.thd_grid(1), 100 * r.thd_std(1), 100 * r.thd_grid(2), 100 * r.thd_std(2), ...
        r.angle(1), r.vdc_dip, dec2bin(r.faults, 4), r.desc);
end
fprintf('(load current THD without the APF: %.1f %%)\n', 100 * res(1).thd_load);

% ---- repeatability: same scenario, different noise seed (seed777_*.csv) ----
for s = {'S0', 'S10', 'S11'}
    f = fullfile(outdir, ['seed777_' s{1} '.csv']);
    k = find(startsWith({res.name}, [s{1} '_']), 1);
    if ~isfile(f) || isempty(k), continue; end
    d = readtable(f); t = d.t; dt = median(diff(t));
    if t(end) < 1 - 2 * dt, continue; end   % run not finished
    m = [mean(arrayfun(@(t0) thd(d.isa(window(t, t0, 5, dt))), 0.40:0.02:0.60 + 1e-9)), ...
         mean(arrayfun(@(t0) thd(d.isa(window(t, t0, 5, dt))), 0.80:0.02:0.90 + 1e-9))];
    fprintf('repeatability %-4s seed 12345: %5.2f%% / %5.2f%%   seed 777: %5.2f%% / %5.2f%%  (33 / 22 ohm)\n', ...
        s{1}, 100 * res(k).thd_grid, 100 * m);
end

% ---- S0 must reproduce the original testbench run ----
orig = fullfile(outdir, '..', 'apf_system.csv');
if isfile(orig) && isfile(fullfile(outdir, 'S0_ideal.csv'))
    a = readmatrix(orig); b = readmatrix(fullfile(outdir, 'S0_ideal.csv'));
    same = isequal(size(a), size(b)) && max(abs(a(:) - b(:)), [], 'omitnan') == 0;
    fprintf('S0 identical to the original tb_apf_system run: %s\n', mat2str(same));
end

% ---- figures ----
ok = arrayfun(@(r) ~isnan(r.thd_grid(1)), res);
fig = figure('Name', 'H1 grid THD', 'Position', [100 100 1000 460]);
lightTheme(fig);
m = 100 * reshape([res(ok).thd_grid], 2, []).';
s = 100 * reshape([res(ok).thd_std], 2, []).';
b = bar(m); hold on
for c = 1:2
    errorbar(b(c).XEndPoints, m(:, c), s(:, c), 'k', 'LineStyle', 'none');
end
ycap = 10;
ylim([0 ycap]);
for k = find(m(:, 1) > ycap).'
    text(k, ycap - 0.4, sprintf('%.0f %%', m(k, 1)), 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
end
set(gca, 'XTick', 1:nnz(ok), 'XTickLabel', strrep({res(ok).name}, '_', '\_'), 'XTickLabelRotation', 30);
ylabel('grid current THD (%), mean \pm std over windows');
legend(b, {'33 \Omega load', '22 \Omega load'}, 'Location', 'northwest');
yline(5, ':', 'IEEE 519 5 %', 'HandleVisibility', 'off', 'LabelHorizontalAlignment', 'left'); grid on
title('Grid current THD with each sensor / ADC chain (bars above 10 % are clipped)');
exportgraphics(fig, fullfile(outdir, 'H1_thd_bar.png'), 'Resolution', 120);

fig = figure('Name', 'H1 waveforms', 'Position', [100 100 900 600]);
lightTheme(fig);
show = intersect({'S0_ideal', 'S12_AD7606B_10V', 'S9_delay400us', 'S5_cRIO_NI9244'}, fieldnames(traces), 'stable');
for k = 1:numel(show)
    subplot(numel(show), 1, k);
    tr = traces.(show{k});
    plot(1e3 * tr.t, tr.ila, 'Color', [0.85 0.4 0.4]); hold on
    plot(1e3 * tr.t, tr.isa, 'b'); grid on; ylabel('A');
    title(strrep(show{k}, '_', '\_'));
end
xlabel('ms'); legend('load current a', 'grid current a', 'Location', 'southeast');
exportgraphics(fig, fullfile(outdir, 'H1_waveforms.png'), 'Resolution', 120);

% ---- latency budget: grid THD vs total measurement latency ----
[have, idx] = ismember(lat_names, {res.name});
if nnz(have) >= 2
    th = nan(2, numel(lat_names)); sd = th;
    for k = find(have)
        r = res(idx(k));
        th(:, k) = 100 * r.thd_grid(:); sd(:, k) = 100 * r.thd_std(:);
        if r.faults > 0, th(:, k) = NaN; end   % tripped: no steady state to measure
    end
    fig = figure('Name', 'H1 latency budget', 'Position', [100 100 760 400]);
    lightTheme(fig);
    sel = have & ~isnan(th(1, :));
    errorbar(lat_us(sel), th(1, sel), sd(1, sel), 'o-', 'LineWidth', 1.5); hold on
    errorbar(lat_us(sel), th(2, sel), sd(2, sel), 's-', 'LineWidth', 1.5);
    set(gca, 'XScale', 'log'); grid on
    tripped = have & isnan(th(1, :));
    if any(tripped)
        plot(lat_us(tripped), 25 * ones(1, nnz(tripped)), 'rx', 'MarkerSize', 12, 'LineWidth', 2);
        text(lat_us(tripped), 28 * ones(1, nnz(tripped)), 'tripped', 'Color', 'r', 'HorizontalAlignment', 'center');
    end
    yline(5, ':', 'IEEE 519 5 %', 'HandleVisibility', 'off', 'LabelHorizontalAlignment', 'left');
    legend('33 \Omega load', '22 \Omega load', 'Location', 'northwest');
    xlabel('current-channel delay before the sample instant (\mus)'); ylabel('grid current THD (%)');
    title('How much measurement delay the controller tolerates');
    exportgraphics(fig, fullfile(outdir, 'H1_latency_budget.png'), 'Resolution', 120);
end
fprintf('figures written to %s\n', outdir);
end

function w = window(t, t0, cycles, dt)
n = round(cycles * 0.02 / dt);
k0 = find(t >= t0, 1);
w = k0:k0 + n - 1;
end

function [r, a] = thd(x)
% Harmonic amplitudes 1..40 from exactly 5 cycles.
n = numel(x);
F = abs(fft(x)) * 2 / n;
a = F(5 * (1:40) + 1);
r = sqrt(sum(a(2:end) .^ 2)) / a(1);
end

function tt = firstTime(t, m)
tt = min([t(find(m, 1)); NaN]);
end

function lightTheme(fig)
% Report figures use the light theme (R2025a defaults to the desktop theme).
try
    theme(fig, 'light');
catch   % theme() does not exist before R2025a; figures are light there anyway
end
end
