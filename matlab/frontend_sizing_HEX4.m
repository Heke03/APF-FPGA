function fe = frontend_sizing_HEX4(opt)
% HEX4: the sensor front end for the AD7606 on the +-10 V range, the range the H2 study
% recommends, and the digital gains for rtl/adc_scale_HEX4.sv.
%
% H1 sized the front end for the +-5 V range, so that the sensor's full scale filled
% the ADC and a plain shift gave the right 12-bit codes. That cannot work at +-10 V:
% the LV 25-P with its burden limit (190 ohm at +-15 V, 14 mA) reaches 6.65 V at most.
% So the sensor uses part of the range and a digital gain makes up the difference.
% 16-bit data leaves plenty of resolution for that.
%
%   fe = frontend_sizing_HEX4();
%   fe = frontend_sizing_HEX4(struct('Vph_rms', 230));     % e.g. a 230 V grid
%
% Data: LEM LV 25-P (v19, 2014), LEM LA 25-NP (v17, 2022), ADI AD7606 Rev. G.
if nargin < 1, opt = struct(); end
d = struct( ...
    'Vph_rms', 100 / sqrt(2), ...  % grid phase voltage, V rms (placeholder: 100 V peak)
    'grid_tol', 1.10, ...          % worst-case grid over-voltage factor
    'Vdc_trip', 380, ...           % over-voltage trip, V
    'I_trip', 15, ...              % over-current trip, A
    'R1_grid', 10e3, ...           % LV 25-P primary resistor, grid channels
    'R1_dc', 30e3, ...             % LV 25-P primary resistor, DC link
    'RM_lv', 187, ...              % LV 25-P burden, ohm (E96)
    'RM_la', 316, ...              % LA 25-NP burden, ohm (E96)
    'turns', 1);                   % LA 25-NP primary turns
f = fieldnames(opt);
for k = 1:numel(f), d.(f{k}) = opt.(f{k}); end

KV = 16; KI = 100; KDC = 10;                 % counts per V / A / V that apf_core expects
raw_per_V = 32768 / 10;                      % AD7606 at +-10 V: 305.175 uV per count
lv = struct('KN', 2.5, 'Ip_max', 14e-3, 'Rp', 250, 'RM', [100 190]);
la = struct('ratio', d.turns / 1000, 'Ip_max', 36 / d.turns, 'RM', [100 320]);

% what apf_core can represent in its 12-bit codes
V_range = 2032 / KV;  I_range = 2032 / KI;  Vdc_range = 4095 / KDC;

g.v_per_V = lv.KN * d.RM_lv / (d.R1_grid + lv.Rp);
g.Ip_fs = V_range / (d.R1_grid + lv.Rp);
g.V_adc_fs = V_range * g.v_per_V;
g.P_R1 = (d.grid_tol * d.Vph_rms) ^ 2 / d.R1_grid;
g.gain = KV / (g.v_per_V * raw_per_V);
g.ok = d.RM_lv >= lv.RM(1) && d.RM_lv <= lv.RM(2) && g.Ip_fs <= lv.Ip_max ...
    && g.V_adc_fs < 10 && d.grid_tol * d.Vph_rms * sqrt(2) < V_range;

v.v_per_V = lv.KN * d.RM_lv / (d.R1_dc + lv.Rp);
v.Ip_trip = d.Vdc_trip / (d.R1_dc + lv.Rp);
v.V_adc_fs = Vdc_range * v.v_per_V;
v.P_R1 = d.Vdc_trip ^ 2 / d.R1_dc;
v.gain = KDC / (v.v_per_V * raw_per_V);
v.ok = d.RM_lv >= lv.RM(1) && d.RM_lv <= lv.RM(2) && v.Ip_trip <= lv.Ip_max ...
    && v.V_adc_fs < 10 && d.Vdc_trip < Vdc_range;

c.v_per_A = la.ratio * d.RM_la;
c.V_adc_fs = I_range * c.v_per_A;
c.P_RM = (I_range * la.ratio) ^ 2 * d.RM_la;
c.gain = KI / (c.v_per_A * raw_per_V);
c.ok = d.RM_la >= la.RM(1) && d.RM_la <= la.RM(2) && I_range <= la.Ip_max ...
    && c.V_adc_fs < 10 && d.I_trip < I_range;

fe = struct('opt', d, 'grid', g, 'dc', v, 'cur', c, ...
    'gain_q16', round([g.gain g.gain c.gain c.gain c.gain c.gain v.gain] * 65536));

fprintf('\nSensor front end, AD7606 on the +-10 V range (RANGE pin high), LEM parts on +-15 V\n');
fprintf('  channel        part      R1 / turns    burden   ADC volts at the code limit   gain (Q16)  check\n');
fprintf('  grid voltage   LV 25-P   %5.1f kOhm   %5.0f ohm   %5.2f V at %6.1f V           %6d     %s\n', ...
    d.R1_grid / 1e3, d.RM_lv, g.V_adc_fs, V_range, round(g.gain * 65536), okstr(g.ok));
fprintf('  DC link        LV 25-P   %5.1f kOhm   %5.0f ohm   %5.2f V at %6.1f V           %6d     %s\n', ...
    d.R1_dc / 1e3, d.RM_lv, v.V_adc_fs, Vdc_range, round(v.gain * 65536), okstr(v.ok));
fprintf('  currents       LA 25-NP  %d turn(s)    %5.0f ohm   %5.2f V at %6.1f A           %6d     %s\n', ...
    d.turns, d.RM_la, c.V_adc_fs, I_range, round(c.gain * 65536), okstr(c.ok));
fprintf('  R1 power: grid %.1f W (use >= %.1f W), DC link %.1f W (use >= %.1f W)\n', g.P_R1, 4 * g.P_R1, v.P_R1, 2 * v.P_R1);
fprintf('  One ADC count at the sensor: grid %.1f mV, DC link %.1f mV, current %.2f mA. One 12-bit code: 62.5 mV, 100 mV, 10 mA.\n', ...
    1e3 / (g.v_per_V * raw_per_V), 1e3 / (v.v_per_V * raw_per_V), 1e3 / (c.v_per_A * raw_per_V));
fprintf('  rtl/adc_scale_HEX4.sv defaults, vdc first: {%d, %d, %d, %d, %d, %d, %d}\n', flip(fe.gain_q16));
end

function s = okstr(ok)
if ok, s = 'OK'; else, s = 'OUT OF LIMITS'; end
end
