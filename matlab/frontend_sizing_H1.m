function fe = frontend_sizing_H1(opt)
% H1: sizes the sensor front end (LEM LV 25-P / LA 25-NP -> AD7606, +-5 V range)
% so that the codes reaching apf_core have exactly the scaling it was designed for:
%   grid voltage 16 counts/V, currents 100 counts/A, DC link 10 counts/V (12-bit).
% Checks every part against its datasheet limits and returns the sensor time
% constants used by sim/run_sensor_study_H1.do (scenario S10).
%
%   fe = frontend_sizing_H1();                         % lab values from the testbench
%   fe = frontend_sizing_H1(struct('Vph_rms', 230));   % e.g. a 230 V grid
%
% Datasheets: LEM LV 25-P (v19, 2014), LEM LA 25-NP (v17, 2022), ADI AD7606.
if nargin < 1, opt = struct(); end
d = struct( ...
    'Vph_rms', 100 / sqrt(2), ...  % grid phase voltage, V rms (testbench: 100 V peak)
    'grid_tol', 1.10, ...          % worst-case grid over-voltage factor
    'Vdc_nom', 300, ...            % DC-link reference, V
    'Vdc_trip', 380, ...           % over-voltage trip, V
    'I_trip', 15, ...              % over-current trip, A
    'R1_grid', 10e3, ...           % LV 25-P primary resistor, grid channels
    'R1_dc', 30e3, ...             % LV 25-P primary resistor, DC link
    'turns', 1);                   % LA 25-NP primary turns
f = fieldnames(opt);
for k = 1:numel(f), d.(f{k}) = opt.(f{k}); end

% ---- what apf_core expects ----
KV = 16; KI = 100; KDC = 10;            % counts per V / A / V (12-bit codes)
% ---- AD7606, +-5 V range, 16-bit; the FPGA adapter turns it into 12-bit codes ----
%   bipolar channels: code12 = (raw16 >>> 4) + 2048   -> 4096 counts over 10 V
%   DC link:          code12 = max(raw16, 0) >>> 3     -> 4096 counts over 0..5 V
cpv_bip = 4096 / 10;  cpv_uni = 4096 / 5;   % 12-bit counts per ADC-input volt
Vfs = 5;
% ---- LEM data ----
lv.KN = 2.5; lv.Ip_max = 14e-3; lv.Rp = 250;              % LV 25-P
lv.RM = [100 190];                                         % +-15 V supply, +-14 mA
lv.Lp = 40e-6 / log(10) * (25e3 + lv.Rp);                  % t90 = 40 us at R1 = 25 k (L/R)
la.ratio = d.turns / 1000; la.Ip_max = 36 / d.turns;       % LA 25-NP
la.RM = [100 320];                                         % +-15 V supply, +-25 At
la.tau = 1e-6 / log(10);                                   % t90 < 1 us

% ---- grid voltage channels (LV 25-P, phase to neutral) ----
g.gain = KV / cpv_bip;                                     % V at ADC per grid volt
g.RM = g.gain * (d.R1_grid + lv.Rp) / lv.KN;
g.V_fs = Vfs / g.gain;                                     % grid volts at ADC full scale
g.Ip_fs = g.V_fs / (d.R1_grid + lv.Rp);
g.Ip_nom_rms = d.Vph_rms / (d.R1_grid + lv.Rp);
g.P_R1 = (d.grid_tol * d.Vph_rms)^2 / d.R1_grid;
g.tau = lv.Lp / (d.R1_grid + lv.Rp);
g.ok = g.RM >= lv.RM(1) && g.RM <= lv.RM(2) && g.Ip_fs <= lv.Ip_max ...
    && d.grid_tol * d.Vph_rms * sqrt(2) < g.V_fs;

% ---- DC link (LV 25-P) ----
v.gain = KDC / cpv_uni;
v.RM = v.gain * (d.R1_dc + lv.Rp) / lv.KN;
v.V_fs = Vfs / v.gain;
v.Ip_fs = v.V_fs / (d.R1_dc + lv.Rp);
v.Ip_nom = d.Vdc_nom / (d.R1_dc + lv.Rp);
v.P_R1 = d.Vdc_trip^2 / d.R1_dc;
v.tau = lv.Lp / (d.R1_dc + lv.Rp);
v.ok = v.RM >= lv.RM(1) && v.RM <= lv.RM(2) && v.Ip_fs <= lv.Ip_max && d.Vdc_trip < v.V_fs;

% ---- currents (LA 25-NP) ----
c.gain = KI / cpv_bip;                                     % V at ADC per amp
c.RM = c.gain / la.ratio;
c.I_fs = Vfs / c.gain;
c.P_RM = (c.I_fs * la.ratio)^2 * c.RM;
c.tau = la.tau;
c.ok = c.RM >= la.RM(1) && c.RM <= la.RM(2) && c.I_fs <= la.Ip_max && d.I_trip < c.I_fs;

fe = struct('opt', d, 'grid', g, 'dc', v, 'cur', c, 'Lp_LV25P', lv.Lp);

fprintf('\nFront end for apf_core scaling (AD7606 +-5 V range, +-15 V LEM supply)\n');
fprintf('Grid voltage x2   LV 25-P  R1 = %5.1f kOhm (>= %.1f W)  RM = %6.1f Ohm  full scale %6.1f V  Ip(fs) %.1f mA  tau %.1f us  %s\n', ...
    d.R1_grid / 1e3, 4 * g.P_R1, g.RM, g.V_fs, 1e3 * g.Ip_fs, 1e6 * g.tau, okstr(g.ok));
fprintf('DC link     x1   LV 25-P  R1 = %5.1f kOhm (>= %.1f W)  RM = %6.1f Ohm  full scale %6.1f V  Ip(fs) %.1f mA  tau %.1f us  %s\n', ...
    d.R1_dc / 1e3, 2 * v.P_R1, v.RM, v.V_fs, 1e3 * v.Ip_fs, 1e6 * v.tau, okstr(v.ok));
fprintf('Currents    x4   LA 25-NP %d turn(s)                   RM = %6.1f Ohm  full scale +-%.2f A  P(RM) %.2f W  tau %.2f us  %s\n', ...
    d.turns, c.RM, c.I_fs, c.P_RM, 1e6 * c.tau, okstr(c.ok));
fprintf('Nominal primary currents: grid %.2f mA rms, DC link %.2f mA (LV 25-P nominal 10 mA)\n', ...
    1e3 * g.Ip_nom_rms, 1e3 * v.Ip_nom);
fprintf('Nearest E96 burden resistors: %g / %g / %g Ohm (gain error removed by calibration constants)\n', ...
    e96(g.RM), e96(v.RM), e96(c.RM));
end

function s = okstr(ok)
if ok, s = 'OK'; else, s = 'OUT OF LIMITS'; end
end

function r = e96(x)
dec = 10 ^ floor(log10(x));
s = round(10 .^ ((0:95) / 96) * 100) / 100;   % within 0.01 of the standard E96 table
[~, k] = min(abs(s * dec - x));
r = s(k) * dec;
end
