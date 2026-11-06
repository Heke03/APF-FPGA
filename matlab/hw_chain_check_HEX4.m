function T = hw_chain_check_HEX4(hw_file, h3_file)
% HEX4: the real-hardware design against the H3 board design, both in closed loop in Questa.
% Same plant and same apf_core, but the codes now travel the real route: plant value -> raw
% ADC count -> AD7606 model -> ad7606_if_HEX4 -> adc_scale_HEX4 -> apf_core, and the gates pass
% gate_guard_HEX4. If that route is right, the results must match the H3 run.
%
%   T = hw_chain_check_HEX4                       % sim/out/HEX4/hw_loop.csv, sim/out/H3/apf_vps.csv
%   T = hw_chain_check_HEX4(hw_file, h3_file)     % .csv as above, or a .mat holding a table R
%
% The limits were set before the first comparison, each for a stated reason:
%   THD 0.25 points : the spread between 0.1 s windows of one H3 run is about 0.1 point
%   DC-link dip 1 V : about 1/3 of a percent of the DC link
%   lock 1 ms       : a few PWM frames. The PLL runs once per frame
%   switching 21 ms : the DC-link loop updates once per grid cycle (20 ms), so an ADC delay
%                     change can move the start by one whole cycle (see docs/H3_progress.md)
%   final Vdc 1 V   : as for the dip
here = fileparts(mfilename('fullpath'));
if nargin < 1, hw_file = fullfile(here, '..', 'sim', 'out', 'HEX4', 'hw_loop.csv'); end
if nargin < 2, h3_file = fullfile(here, '..', 'sim', 'out', 'H3', 'apf_vps.csv'); end
a = metrics(load_run(hw_file));
b = metrics(load_run(h3_file));

what = ["grid THD 33 ohm (%)"; "grid THD 22 ohm (%)"; "DC-link dip at the load step (V)"; "PLL lock (ms)"; ...
        "switching from (ms)"; "DC link at the end (V)"];
hw = [a.thd33; a.thd22; a.dip; a.lock_ms; a.switch_ms; a.vend];
h3 = [b.thd33; b.thd22; b.dip; b.lock_ms; b.switch_ms; b.vend];
limit = [0.25; 0.25; 1; 1; 21; 1];
ok = abs(hw - h3) <= limit;
what(end + 1) = "faults (any seen)"; hw(end + 1) = a.faults; h3(end + 1) = b.faults; limit(end + 1) = 0; ok(end + 1) = a.faults == 0;
T = table(what, round(hw, 2), round(h3, 2), round(hw - h3, 2), limit, ok, ...
    'VariableNames', {'measure', 'real_hardware_design', 'H3_design', 'difference', 'allowed', 'ok'});
if nargout == 0
    disp(T)
    if all(T.ok), fprintf('hw_chain_check_HEX4: all %d OK\n', height(T));
    else, fprintf('hw_chain_check_HEX4: %d of %d FAILED\n', sum(~T.ok), height(T)); end
    clear T
end
end

function R = load_run(f)
[~, ~, e] = fileparts(f);
if strcmpi(e, '.mat'), s = load(f, 'R'); R = s.R;
else, R = readtable(f); end
end

function m = metrics(R)
% the same windows and method as vps_rtl_check_H3
t = R.t; dt = median(diff(t));
m.thd33 = 100 * mean_thd(t, R.isa, dt, 0.40, 0.60);
m.thd22 = 100 * mean_thd(t, R.isa, dt, 0.80, 0.90);
m.dip = 300 - min(R.vdc(t >= 0.7 & t < 0.8));
m.lock_ms = 1e3 * first_on(t, R.locked);
m.switch_ms = 1e3 * first_on(t, R.switching);
m.vend = R.vdc(end);
m.faults = double(any(R.faults ~= 0));
end

function v = first_on(t, x)
k = find(x > 0.5, 1);
if isempty(k), v = NaN; else, v = t(k); end
end

function r = mean_thd(t, x, dt, t1, t2)
starts = t1:0.02:t2 + 1e-9;
r = mean(arrayfun(@(t0) thd(x(window(t, t0, dt))), starts));
end

function w = window(t, t0, dt)
k0 = find(t >= t0 - dt / 2, 1);
w = (k0:k0 + round(0.1 / dt) - 1)';
end

function r = thd(x)
n = numel(x);
F = fft(x(:)) * 2 / n;
a = abs(F((1:40) * 5 + 1));
r = sqrt(sum(a(2:end) .^ 2)) / a(1);
end
