function res = analyze_apf_results(out, outdir, t_step)
% Start-up times, THD, displacement angle and figures from a run of apf_system.
% Mirrors model/analyze_system.py so the Simulink and RTL results compare directly.
if nargin < 3, t_step = 0.7; end
if ~exist(outdir, 'dir'), mkdir(outdir); end

t = out.sim_power.time;
x = out.sim_power.signals.values;
vg = x(:, 1:3); il = x(:, 4:6); i_f = x(:, 7:8); is = x(:, 10:12); vdc = x(:, 13);
tc = out.sim_ctrl.time;
c = reshape(out.sim_ctrl.signals.values, [], numel(tc)).';   % logged as 1 x 12 x N
locked = c(:, 1); ready = c(:, 2); switching = c(:, 3); faults = c(:, 4:7);
freq = c(:, 8); idc_cmd = c(:, 9); vdc_target = c(:, 10);

first = @(tt, m) min([tt(find(m, 1)); NaN]);
res.t_lock = first(tc, locked > 0.5);
res.t_ready = first(tc, ready > 0.5);
res.t_switch = first(tc, switching > 0.5);
fprintf('PLL locked at %.1f ms, compensation ready at %.1f ms, switching from %.1f ms\n', ...
    1e3 * res.t_lock, 1e3 * res.t_ready, 1e3 * res.t_switch);
if any(faults(:) > 0.5)
    fprintf('FAULT flags [meas oc ov pll] seen from %.1f ms: %s\n', ...
        1e3 * first(tc, any(faults > 0.5, 2)), mat2str(max(faults, [], 1)));
end

dt = median(diff(t));
cases = {'33 ohm load', 0.60; '22 ohm load (after step)', 0.90};
res.cases = struct([]);
for k = 1:size(cases, 1)
    t0 = cases{k, 2};
    if t0 + 0.1 > t(end), continue; end
    w = window(t, t0, 5, dt);
    [thd_l, a_l] = thd(il(w, 1));
    [thd_s, a_s] = thd(is(w, 1));
    Fv = fft(vg(w, 1)); Fi = fft(is(w, 1));
    ang = mod(rad2deg(angle(Fi(6)) - angle(Fv(6))) + 180, 360) - 180;
    r = struct('label', cases{k, 1}, 'thd_load', thd_l, 'thd_grid', thd_s, ...
        'I1_load', a_l(1), 'I1_grid', a_s(1), 'angle_deg', ang, ...
        'vdc_min', min(vdc(w)), 'vdc_max', max(vdc(w)), 'h_load', a_l, 'h_grid', a_s);
    res.cases = [res.cases, r];
    fprintf('%-26s load THD %5.1f %%   grid THD %5.1f %%   I1 load %.2f A, grid %.2f A   angle %+.1f deg   Vdc %.1f..%.1f V\n', ...
        r.label, 100 * thd_l, 100 * thd_s, a_l(1), a_s(1), ang, r.vdc_min, r.vdc_max);
    h = [5 7 11 13 17 19];
    fprintf('   harmonics %% of fundamental:%s\n', sprintf('  %d: %4.1f->%4.1f', ...
        [h; 100 * a_l(h)' / a_l(1); 100 * a_s(h)' / a_s(1)]));
end

% ---- Figure 1: steady-state waveforms ----
if t(end) >= 0.64
    w = window(t, 0.60, 2, dt);
    tm = 1e3 * (t(w) - t(w(1)));
    f1 = figure('Visible', 'off', 'Position', [100 100 1000 750]);
    tl = tiledlayout(f1, 3, 1, 'TileSpacing', 'compact');
    nexttile; plot(tm, vg(w, 1), 'Color', [0.4 0.4 0.4]); ylabel('V'); legend('grid voltage a'); grid on
    nexttile; plot(tm, il(w, 1), tm, i_f(w, 1)); ylabel('A'); grid on
    legend('load current a', 'inverter current a (APF injects)');
    nexttile; plot(tm, is(w, 1)); ylabel('A'); xlabel('ms'); grid on
    legend('grid current a = load - inverter');
    if ~isempty(res.cases)
        title(tl, sprintf('Steady state, 33 ohm load: current THD %.1f %% -> %.1f %%', ...
            100 * res.cases(1).thd_load, 100 * res.cases(1).thd_grid));
    end
    exportgraphics(f1, fullfile(outdir, 'fig1_waveforms.png'), 'Resolution', 120);
end

% ---- Figure 2: whole run ----
f2 = figure('Visible', 'off', 'Position', [100 100 1000 850]);
tl = tiledlayout(f2, 4, 1, 'TileSpacing', 'compact');
ax1 = nexttile; plot(t, is(:, 1), 'LineWidth', 0.4); hold on; plot(t, il(:, 1), 'LineWidth', 0.4);
ylabel('A'); legend('grid current a', 'load current a', 'Location', 'northwest'); grid on
ax2 = nexttile; plot(t, vdc, tc, vdc_target, '--'); ylabel('Vdc (V)'); legend('Vdc', 'target', 'Location', 'southeast'); grid on
ax3 = nexttile; plot(tc, freq); ylabel('PLL f (Hz)'); ylim([49 51]); grid on
ax4 = nexttile; plot(tc, locked, tc, 0.9 * ready, tc, 0.8 * switching, tc, 0.7 * any(faults > 0.5, 2));
ylabel('flags'); xlabel('time (s)'); ylim([-0.1 1.1]); grid on
legend('PLL locked', 'ready', 'switching', 'fault', 'Location', 'southeast', 'NumColumns', 4);
linkaxes([ax1 ax2 ax3 ax4], 'x');
title(tl, 'Start-up: PLL lock -> compensation -> DC link 173 V -> 300 V; load step');
exportgraphics(f2, fullfile(outdir, 'fig2_startup.png'), 'Resolution', 120);

% ---- Figure 3: spectrum ----
if ~isempty(res.cases)
    f3 = figure('Visible', 'off', 'Position', [100 100 1000 400]);
    a_l = res.cases(1).h_load; a_s = res.cases(1).h_grid; h = 2:40;
    bar(h, [100 * a_l(h) / a_l(1), 100 * a_s(h) / a_s(1)], 'grouped');
    xlabel('harmonic order'); ylabel('% of fundamental'); grid on
    legend('load current', 'grid current with APF'); title('Harmonic content, 33 ohm load');
    exportgraphics(f3, fullfile(outdir, 'fig3_spectrum.png'), 'Resolution', 120);
end

% ---- Figure 4: load step ----
if t(end) > t_step + 0.06
    w = find(t >= t_step - 0.02 & t <= t_step + 0.06);
    f4 = figure('Visible', 'off', 'Position', [100 100 1000 600]);
    tl = tiledlayout(f4, 2, 1, 'TileSpacing', 'compact');
    nexttile; plot(1e3 * t(w), is(w, 1), 1e3 * t(w), il(w, 1)); ylabel('A'); grid on
    legend('grid current a', 'load current a', 'Location', 'northwest');
    nexttile; plot(1e3 * t(w), vdc(w)); ylabel('Vdc (V)'); xlabel('ms'); grid on
    title(tl, sprintf('Load step 33 -> 22 ohm at %.0f ms', 1e3 * t_step));
    exportgraphics(f4, fullfile(outdir, 'fig4_load_step.png'), 'Resolution', 120);
end
res.idc_cmd_final = idc_cmd(end);
res.vdc_final = vdc(end);
fprintf('final Vdc %.1f V, figures written to %s\n', vdc(end), outdir);
end


function w = window(t, t0, cycles, dt)
n = round(cycles * 0.02 / dt);
k0 = find(t >= t0, 1);
w = (k0:k0 + n - 1)';
end


function [r, a] = thd(x)
% Harmonic amplitudes 1..40 from exactly 5 grid cycles.
cycles = 5;
n = numel(x);
F = fft(x(:)) * 2 / n;
a = abs(F((1:40) * cycles + 1));
r = sqrt(sum(a(2:end).^2)) / a(1);
end
