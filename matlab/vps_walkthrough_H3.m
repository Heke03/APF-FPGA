%[text] # H3 virtual power stage: the data and the math
%[text] This Live Script runs every part of the virtual power stage (VPS) that is not a simulation: the plant data, the integer constants the FPGA uses, the plant equations, 40 ms of plant steps, the ADC codes, and the comparison of the FPGA run with Simulink. Each result appears next to the code that made it. Press **Run** (or Ctrl+Enter in one section) to run it again.
%[text] The code it calls: `vps_params_H3.m` (data), `blocks/vps_block_H3.m` (one plant step), `vps_vectors_H3.m` (40 ms of steps), `vps_adc_codes_H3.m` (ADC codes), `vps_rtl_check_H3.m` (FPGA vs Simulink).
%%
%[text] ## 1. The data: the plant
%[text] `vps_params_H3(true)` is the fixed-point version (what the FPGA computes), `vps_params_H3(false)` the same plant with exact real numbers.
here = fileparts(which('vps_params_H3'));       % the APF_FPGA/matlab folder
addpath(fullfile(here, 'blocks'))
format longG
V = vps_params_H3(true);
Vr = vps_params_H3(false);
plant = table([V.H*1e9; V.Vm; V.f; V.Lf*1e3; V.Rf; V.Cdc*1e6; V.Rleak/1e3; V.Ldc*1e3; V.R1; V.R2; V.tau_comm*1e3; V.vdc0], ...
    ["ns"; "V peak"; "Hz"; "mH"; "ohm"; "uF"; "kohm"; "mH"; "ohm"; "ohm"; "ms"; "V"], ...
    'VariableNames', {'Value', 'Unit'}, ...
    'RowNames', {'plant step H', 'grid voltage', 'grid frequency', 'filter inductor Lf', 'filter resistance Rf', ...
    'DC-link capacitor', 'DC-link leakage', 'load inductor Ldc', 'load R before step', 'load R after step', ...
    'commutation lag', 'DC-link precharge'})
%%
%[text] ## 2. The data: integer constants used by the FPGA
%[text] The FPGA has no decimals, so every constant is a scale factor rounded to a whole number. For example `Kl` is $\\frac{H}{L_f} \\cdot 2^{28}$.
names = ["dth"; "th120"; "Kvm"; "K3"; "Krf"; "Kl"; "Kc"; "Kleak"; "Kd"; "Kt"; "vdc0_q"];
fpga = arrayfun(@(n) V.(n), names);
exact = arrayfun(@(n) Vr.(n), names);
meaning = ["grid angle step per 200 ns"; "120 degrees (one turn = 2^40)"; "cosine -> grid volts"; ...
    "divide by 3 (neutral point)"; "Rf times current"; "H/Lf: inverter current"; "H/Cdc: DC link"; ...
    "H/(Rleak Cdc): DC-link leakage"; "H/Ldc: load DC current"; "H/tau: diode commutation"; "173.2 V precharge"];
constants = table(fpga, round(exact, 4), round(fpga - exact, 3), meaning, ...
    'VariableNames', {'FPGA_integer', 'exact_value', 'rounding', 'what_it_does'}, 'RowNames', cellstr(names))
%%
%[text] ## 3. What the rounding does to the plant
%[text] The rounded constants describe an almost identical plant:
e = V.effective;
rounding_effect = table([50; 3; 1000; 20; 20; 0.2; 0.1; round(1/3, 6, 'significant')], ...
    round([e.f_Hz; e.Lf_H*1e3; e.Cdc_F*1e6; e.Ldc_H*1e3; e.Rleak_ohm/1e3; e.tau_comm_s*1e3; e.Rf_ohm; e.one_third], 6, 'significant'), ...
    'VariableNames', {'nominal', 'after_rounding'}, ...
    'RowNames', {'frequency (Hz)', 'Lf (mH)', 'Cdc (uF)', 'Ldc (mH)', 'Rleak (kohm)', 'tau (ms)', 'Rf (ohm)', 'one third'})
%%
%[text] ## 4. The data: cosine table shared with the FPGA
%[text] `rtl/cos_table_4096.hex`, 4096 points per turn, peak 65536 (= 1.0). Between two points the plant interpolates linearly.
plot(0:4095, V.cos_table, 'LineWidth', 1.2)
grid on, xlim([0 4095])
title('Cosine table (rtl/cos_table_4096.hex)')
xlabel('table address (4096 = one turn)'), ylabel('value (65536 = 1.0)')
%%
%[text] ## 5. The math: one plant step
%[text] Every 200 ns (`blocks/vps_block_H3.m`), forward Euler:
%[text] - grid: $\\theta \\leftarrow \\theta + 2\\pi f H$, $v_{g,p} = V_m \\cos(\\theta - p \\cdot 120^{\\circ})$
%[text] - inverter legs: $v_x = V_{dc}$ when the top switch (or its diode) conducts, else 0; neutral $v_n = (v_{x,a}+v_{x,b}+v_{x,c})/3$
%[text] - inverter currents: $i_f \\leftarrow i_f + \\frac{H}{L_f}(v_x - v_n - v_g - R_f i_f)$
%[text] - DC link: $V_{dc} \\leftarrow V_{dc} - \\frac{H}{C}\\, i_{top} - \\frac{H}{R_{leak} C} V_{dc}$
%[text] - diode-bridge load: $i_d \\leftarrow i_d + \\frac{H}{L_{dc}}(v_{g,max} - v_{g,min} - R\\, i_d)$, $i_d \\ge 0$
%[text] - load phase currents follow $+i_d$ (highest phase), $-i_d$ (lowest), 0 (other) with the lag $\\tau$ \
%[text] The first step from reset, with the inverter disconnected and all switches off:
clear vps_block_H3                              % reset the plant state
[vg, il, iff, is, vdc, shoot] = vps_block_H3(zeros(1, 6), false, false, V);
first_step = table(vg, il, iff, 'VariableNames', {'grid_voltage_V', 'load_current_A', 'inverter_current_A'}, ...
    'RowNames', {'phase a', 'phase b', 'phase c'})
%%
%[text] ## 6. The math: 40 ms of plant steps (200,000 steps)
%[text] `vps_vectors_H3` drives the plant with open-loop PWM and a list of events, and writes every step to `sim/out/H3/vps_vectors.txt`. The FPGA code is checked against this file, line by line.
%[text] - 0-2 ms: inverter disconnected, gates off; 2-2.5 ms: PWM while disconnected
%[text] - 3 ms: connected, PWM; 10 ms: leg A shoot-through for 3 steps (tests the counter)
%[text] - 20 ms: load step 33 -> 22 ohm; 25-25.5 ms: all gates off; 30-31 ms: disconnected \
out = vps_vectors_H3;
%%
%[text] The same 40 ms as waveforms:
t = (0:size(out, 1) - 1).' * V.H * 1e3;          % ms
tiledlayout(4, 1, 'TileSpacing', 'compact')
nexttile, plot(t, out(:, 4:6) / 2^12), grid on, ylabel('grid V'), title('Plant, 40 ms, open-loop PWM')
nexttile, plot(t, out(:, 7:9) / 2^24), grid on, ylabel('load A')
nexttile, plot(t, out(:, 10:12) / 2^24), grid on, ylabel('inverter A')
nexttile, plot(t, out(:, 13) / 2^24, 'LineWidth', 1.2), grid on, ylabel('DC link V'), xlabel('time (ms)')
xline([3 10 20 25 30], ':', {'connect', 'shoot-through', 'load step', 'gates off', 'disconnect'})
%%
%[text] ## 7. The data the controller sees: ADC codes
%[text] `vps_adc_codes_H3` turns the plant state into the 12-bit codes `apf_core` expects: grid voltage 16 counts/V and current 100 counts/A (both centered at 2048), DC link 10 counts/V.
ms = [5; 15; 22; 28];
k = round(ms * 1e-3 / V.H) + 1;
adc_codes = array2table(out(k, 14:20), 'VariableNames', {'vg_a', 'vg_b', 'il_a', 'il_b', 'if_a', 'if_b', 'vdc'}, ...
    'RowNames', compose('%g ms', ms))
%%
%[text] ## 8. FPGA code vs Simulink
%[text] `vps_rtl_check_H3` reads the closed-loop run of the FPGA code (Questa, `sim/out/H3/apf_vps.csv`) and the saved Simulink runs (`results/H3/vps_runs.mat`) and compares them. Nothing is simulated here; it only reads the saved results.
vps_rtl_check_H3
%%
image(imread(fullfile(here, '..', 'docs', 'figures', 'H3_fpga_closed_loop.png')))
axis image off
title('FPGA code (dashed) vs Simulink')
%%
%[text] ## 9. Open the code
%[text] The plant equations and the data, in the Editor:
if usejava('desktop')
    edit(fullfile(here, 'vps_params_H3.m'))
    edit(fullfile(here, 'blocks', 'vps_block_H3.m'))
    edit(fullfile(here, 'vps_vectors_H3.m'))
    edit(fullfile(here, 'vps_adc_codes_H3.m'))
end

%[appendix]{"version":"1.0"}
%---
%[metadata:view]
%   data: {"layout":"inline"}
%---
