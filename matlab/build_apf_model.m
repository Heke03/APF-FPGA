function build_apf_model()
% Builds apf_system.slx: the three-phase shunt APF with a switching power
% stage (Simscape Electrical, Specialized Power Systems) and a controller
% subsystem that follows the FPGA design in rtl/ block for block.
%
%   >> build_apf_model          % (re)creates matlab/apf_system.slx
%
% The controller code lives in matlab/blocks/*.m and is copied into the
% MATLAB Function blocks, so edit those files and rebuild.

here = fileparts(mfilename('fullpath'));
mdl = 'apf_system';
file = fullfile(here, [mdl '.slx']);
if bdIsLoaded(mdl), close_system(mdl, 0); end
if exist(file, 'file'), delete(file); end
evalin('base', sprintf('run(''%s'')', fullfile(here, 'apf_params.m')));

new_system(mdl);
load_system('spsUniversalBridgeLib');
load_system('spsThreePhaseSeriesRLCBranchLib');
load_system('spsSeriesRLCBranchLib');
load_system('spsThreePhaseBreakerLib');
load_system('spsBreakerLib');
load_system('spsThreePhaseSourceLib');
load_system('spsThreePhaseVIMeasurementLib');
load_system('spspowerguiLib');
load_system('spsVoltageMeasurementLib');

set_param(mdl, 'SolverType', 'Fixed-step', 'Solver', 'FixedStepDiscrete', ...
    'FixedStep', 'Tps', 'StopTime', 'T_end', 'EnableMultiTasking', 'off', ...
    'ReturnWorkspaceOutputs', 'on');
set_param(mdl, 'PostLoadFcn', sprintf('run(fullfile(fileparts(get_param(''%s'',''FileName'')),''apf_params.m''));', mdl));
set_param(mdl, 'InitFcn', sprintf(['if ~exist(''P'',''var''), run(fullfile(fileparts(get_param(''%s'',''FileName'')),''apf_params.m'')); end'], mdl));

%% ===================== power stage =====================
add_block('spspowerguiLib/powergui', [mdl '/powergui'], 'Position', [20 15 95 55], ...
    'SimulationMode', 'Discrete', 'SampleTime', 'Tps');

src = add_block('spsThreePhaseSourceLib/Three-Phase Source', [mdl '/Grid 122 V 50 Hz'], ...
    'Position', [40 110 100 210], 'InternalConnection', 'Yg', 'Voltage', 'Vll_rms', ...
    'PhaseAngle', '90', 'Frequency', 'f', 'NonIdealSource', 'on', 'SpecifyImpedance', 'off', ...
    'Resistance', 'Rgrid', 'Inductance', 'Lgrid');
mg = add_block('spsThreePhaseVIMeasurementLib/Three-Phase V-I Measurement', [mdl '/PCC V-I (grid)'], ...
    'Position', [170 110 220 210], 'VoltageMeasurement', 'phase-to-ground', 'CurrentMeasurement', 'yes');
ml = add_block('spsThreePhaseVIMeasurementLib/Three-Phase V-I Measurement', [mdl '/Load I'], ...
    'Position', [330 110 380 210], 'VoltageMeasurement', 'no', 'CurrentMeasurement', 'yes');
lr = add_block('spsThreePhaseSeriesRLCBranchLib/Three-Phase Series RLC Branch', [mdl '/Load line reactor'], ...
    'Position', [450 110 500 210], 'BranchType', 'RL', 'Resistance', 'Rac_load', 'Inductance', 'Lac_load');
db = add_block('spsUniversalBridgeLib/Universal Bridge', [mdl '/Diode bridge (load)'], ...
    'Position', [570 110 640 210], 'Arms', '3', 'Device', 'Diodes', 'Ron', 'Ron_sw', ...
    'SnubberResistance', '1e5', 'SnubberCapacitance', 'inf');
ldc = add_block('spsSeriesRLCBranchLib/Series RLC Branch', [mdl '/Ldc 20 mH'], ...
    'Position', [700 90 750 110], 'BranchType', 'L', 'Inductance', 'Ldc_load');
r1 = add_block('spsSeriesRLCBranchLib/Series RLC Branch', [mdl '/R load 33'], ...
    'Position', [810 130 830 190], 'Orientation', 'down', 'BranchType', 'R', 'Resistance', 'R_load1');
bs = add_block('spsBreakerLib/Breaker', [mdl '/Load step breaker'], ...
    'Position', [880 90 930 120], 'External', 'on', 'InitialState', '0', 'BreakerResistance', '1e-3');
r2 = add_block('spsSeriesRLCBranchLib/Series RLC Branch', [mdl '/R step 66'], ...
    'Position', [960 130 980 190], 'Orientation', 'down', 'BranchType', 'R', 'Resistance', 'R_step');
add_block('simulink/Sources/Step', [mdl '/Load step 0.7 s'], 'Position', [820 40 850 70], ...
    'Time', 't_step', 'Before', '0', 'After', '1', 'SampleTime', 'Ts');

cb = add_block('spsThreePhaseBreakerLib/Three-Phase Breaker', [mdl '/Contactor'], ...
    'Position', [330 300 380 400], 'External', 'on', 'InitialState', 'open', 'BreakerResistance', '1e-3');
mf = add_block('spsThreePhaseVIMeasurementLib/Three-Phase V-I Measurement', [mdl '/Inverter I'], ...
    'Position', [450 300 500 400], 'VoltageMeasurement', 'no', 'CurrentMeasurement', 'yes');
lf = add_block('spsThreePhaseSeriesRLCBranchLib/Three-Phase Series RLC Branch', [mdl '/Filter 3 mH'], ...
    'Position', [570 300 620 400], 'BranchType', 'RL', 'Resistance', 'Rf', 'Inductance', 'Lf');
ib = add_block('spsUniversalBridgeLib/Universal Bridge', [mdl '/IGBT inverter'], ...
    'Position', [690 300 760 400], 'Arms', '3', 'Device', 'IGBT / Diodes', 'Ron', 'Ron_sw', ...
    'ForwardVoltages', '[0 0]', 'SnubberResistance', '1e5', 'SnubberCapacitance', 'inf');
cdc = add_block('spsSeriesRLCBranchLib/Series RLC Branch', [mdl '/Cdc 1000 uF'], ...
    'Position', [840 320 860 380], 'Orientation', 'down', 'BranchType', 'C', 'Capacitance', 'Cdc', ...
    'Setx0', 'on', 'InitialVoltage', 'Vdc0');
rlk = add_block('spsSeriesRLCBranchLib/Series RLC Branch', [mdl '/Bleed 20k'], ...
    'Position', [910 320 930 380], 'Orientation', 'down', 'BranchType', 'R', 'Resistance', 'Rleak');
vm = add_block('spsVoltageMeasurementLib/Voltage Measurement', [mdl '/Vdc meas'], ...
    'Position', [990 325 1020 375]);

% Electrical wiring
P_ = @(h) get_param(h, 'PortHandles');
wire = @(a, b) add_line(mdl, a, b, 'autorouting', 'smart');
for k = 1:3
    wire(P_(src).RConn(k), P_(mg).LConn(k));
    wire(P_(mg).RConn(k), P_(ml).LConn(k));
    wire(P_(ml).RConn(k), P_(lr).LConn(k));
    wire(P_(lr).RConn(k), P_(db).LConn(k));
    wire(P_(mg).RConn(k), P_(cb).LConn(k));
    wire(P_(cb).RConn(k), P_(mf).LConn(k));
    wire(P_(mf).RConn(k), P_(lf).LConn(k));
    wire(P_(lf).RConn(k), P_(ib).LConn(k));
end
% Load DC side: + -> Ldc -> (33 ohm || breaker + 66 ohm) -> -
wire(P_(db).RConn(1), P_(ldc).LConn(1));
wire(P_(ldc).RConn(1), P_(r1).LConn(1));
wire(P_(ldc).RConn(1), P_(bs).LConn(1));
wire(P_(bs).RConn(1), P_(r2).LConn(1));
wire(P_(r1).RConn(1), P_(db).RConn(2));
wire(P_(r2).RConn(1), P_(db).RConn(2));
add_line(mdl, 'Load step 0.7 s/1', 'Load step breaker/1', 'autorouting', 'smart');
% Inverter DC link
wire(P_(ib).RConn(1), P_(cdc).LConn(1));
wire(P_(ib).RConn(2), P_(cdc).RConn(1));
wire(P_(cdc).LConn(1), P_(rlk).LConn(1));
wire(P_(cdc).RConn(1), P_(rlk).RConn(1));
wire(P_(rlk).LConn(1), P_(vm).LConn(1));
wire(P_(rlk).RConn(1), P_(vm).LConn(2));

% Measurement signals -> Goto tags
goto = @(name, tag, pos) add_block('simulink/Signal Routing/Goto', [mdl '/' name], ...
    'GotoTag', tag, 'Position', pos, 'ShowName', 'off');
from = @(sys, name, tag, pos) add_block('simulink/Signal Routing/From', [sys '/' name], ...
    'GotoTag', tag, 'Position', pos, 'ShowName', 'off');
goto('G_vg', 'Vabc_pcc', [240 60 300 80]);
add_line(mdl, 'PCC V-I (grid)/1', 'G_vg/1', 'autorouting', 'smart');
goto('G_is', 'Iabc_grid', [240 220 300 240]);
add_line(mdl, 'PCC V-I (grid)/2', 'G_is/1', 'autorouting', 'smart');
goto('G_il', 'Iabc_load', [400 220 460 240]);
add_line(mdl, 'Load I/1', 'G_il/1', 'autorouting', 'smart');
% The measurement counts current from the PCC into the inverter; the
% controller uses inverter -> grid, as in the RTL.
add_block('simulink/Math Operations/Gain', [mdl '/to inverter->grid'], 'Gain', '-1', ...
    'Position', [450 420 480 440]);
add_line(mdl, 'Inverter I/1', 'to inverter->grid/1', 'autorouting', 'smart');
goto('G_if', 'Iabc_inv', [510 420 570 440]);
add_line(mdl, 'to inverter->grid/1', 'G_if/1');
goto('G_vdc', 'Vdc', [1050 340 1100 360]);
add_line(mdl, 'Vdc meas/1', 'G_vdc/1');

% Gate and contactor commands from the controller
from(mdl, 'F_gates', 'Gates', [640 250 690 270]);
add_line(mdl, 'F_gates/1', 'IGBT inverter/1', 'autorouting', 'smart');
from(mdl, 'F_sw', 'Switching', [270 250 320 270]);
add_line(mdl, 'F_sw/1', 'Contactor/1', 'autorouting', 'smart');

%% ===================== controller =====================
ctl = [mdl '/FPGA controller (apf_core)'];
add_block('simulink/Ports & Subsystems/Subsystem', ctl, 'Position', [420 520 620 660]);
delete_line(ctl, 'In1/1', 'Out1/1');
delete_block([ctl '/In1']); delete_block([ctl '/Out1']);
build_controller(ctl, here);

from(mdl, 'F_vg', 'Vabc_pcc', [300 525 350 545]);
from(mdl, 'F_il', 'Iabc_load', [300 555 350 575]);
from(mdl, 'F_if', 'Iabc_inv', [300 585 350 605]);
from(mdl, 'F_vdc', 'Vdc', [300 615 350 635]);
add_block('simulink/Sources/Step', [mdl '/Run request'], 'Position', [300 640 330 670], ...
    'Time', 't_run', 'Before', '0', 'After', '1', 'SampleTime', 'Ts');
add_line(mdl, 'F_vg/1', 'FPGA controller (apf_core)/1');
add_line(mdl, 'F_il/1', 'FPGA controller (apf_core)/2');
add_line(mdl, 'F_if/1', 'FPGA controller (apf_core)/3');
add_line(mdl, 'F_vdc/1', 'FPGA controller (apf_core)/4');
add_line(mdl, 'Run request/1', 'FPGA controller (apf_core)/5');
goto('G_gates', 'Gates', [680 525 730 545]);
goto('G_sw', 'Switching', [680 575 730 595]);
add_line(mdl, 'FPGA controller (apf_core)/1', 'G_gates/1');
add_line(mdl, 'FPGA controller (apf_core)/2', 'G_sw/1');

%% ===================== scopes and logging =====================
from(mdl, 'S_vg', 'Vabc_pcc', [800 480 850 500]);
from(mdl, 'S_is', 'Iabc_grid', [800 510 850 530]);
from(mdl, 'S_il', 'Iabc_load', [800 540 850 560]);
from(mdl, 'S_if', 'Iabc_inv', [800 570 850 590]);
from(mdl, 'S_vdc', 'Vdc', [800 600 850 620]);
add_block('simulink/Sinks/Scope', [mdl '/Waveforms'], 'NumInputPorts', '5', ...
    'Position', [920 470 960 630]);
names = {'S_vg', 'S_is', 'S_il', 'S_if', 'S_vdc'};
for k = 1:5
    add_line(mdl, [names{k} '/1'], sprintf('Waveforms/%d', k));
end
add_block('simulink/Signal Routing/Mux', [mdl '/Mux log'], 'Inputs', '[3 3 3 3 1]', ...
    'Position', [880 660 885 760]);
from(mdl, 'L_vg', 'Vabc_pcc', [800 660 850 675]);
from(mdl, 'L_il', 'Iabc_load', [800 680 850 695]);
from(mdl, 'L_if', 'Iabc_inv', [800 700 850 715]);
from(mdl, 'L_is', 'Iabc_grid', [800 720 850 735]);
from(mdl, 'L_vdc', 'Vdc', [800 740 850 755]);
names = {'L_vg', 'L_il', 'L_if', 'L_is', 'L_vdc'};
for k = 1:5
    add_line(mdl, [names{k} '/1'], sprintf('Mux log/%d', k));
end
add_block('simulink/Sinks/To Workspace', [mdl '/log power'], 'VariableName', 'sim_power', ...
    'SaveFormat', 'Structure With Time', 'SampleTime', 'T_log', 'Position', [930 695 1010 725]);
add_line(mdl, 'Mux log/1', 'log power/1');

add_block('simulink/Sinks/Scope', [mdl '/Controller status'], 'Position', [700 620 740 660]);
add_line(mdl, 'FPGA controller (apf_core)/3', 'Controller status/1');
add_block('simulink/Sinks/To Workspace', [mdl '/log controller'], 'VariableName', 'sim_ctrl', ...
    'SaveFormat', 'Structure With Time', 'SampleTime', 'Ts', 'Position', [680 680 760 710]);
add_line(mdl, 'FPGA controller (apf_core)/3', 'log controller/1');

note = Simulink.Annotation([mdl '/Three-phase shunt active power filter']);
note.Position = [120 15 700 70];
note.Text = sprintf(['Three-phase shunt active power filter (graduation project)\n' ...
    'Power stage: Specialized Power Systems, discrete at Tps. Controller: floating-point model of the FPGA RTL (10 kHz).\n' ...
    'Parameters: matlab/apf_params.m (loaded automatically). Run matlab/run_apf_simulation.m for THD and figures.']);

save_system(mdl, file);
fprintf('Saved %s\n', file);
end


function build_controller(ctl, here)
% Controller subsystem: ADC sampling -> SRF-PLL + reference -> current
% control -> one-frame delay -> PWM with dead time.
add_block('simulink/Sources/In1', [ctl '/vg_abc'], 'Position', [20 40 50 54]);
add_block('simulink/Sources/In1', [ctl '/il_abc'], 'Position', [20 120 50 134]);
add_block('simulink/Sources/In1', [ctl '/if_abc'], 'Position', [20 200 50 214]);
add_block('simulink/Sources/In1', [ctl '/vdc'], 'Position', [20 280 50 294]);
add_block('simulink/Sources/In1', [ctl '/run_request'], 'Position', [20 360 50 374]);

% ADC: sample at the carrier boundary; only phases a and b are measured.
inputs = {'vg_abc', 'il_abc', 'if_abc'};
for k = 1:3
    y = 40 + 80 * (k - 1);
    zoh = sprintf('ADC %s', inputs{k}(1:2));
    sel = sprintf('phases a,b %s', inputs{k}(1:2));
    add_block('simulink/Discrete/Zero-Order Hold', [ctl '/' zoh], 'SampleTime', 'Ts', ...
        'Position', [90 y-5 120 y+20]);
    add_block('simulink/Signal Routing/Selector', [ctl '/' sel], 'InputPortWidth', '3', ...
        'Indices', '[1 2]', 'Position', [150 y-5 180 y+20]);
    add_line(ctl, [inputs{k} '/1'], [zoh '/1']);
    add_line(ctl, [zoh '/1'], [sel '/1']);
end
add_block('simulink/Discrete/Zero-Order Hold', [ctl '/ADC vdc'], 'SampleTime', 'Ts', ...
    'Position', [90 275 120 300]);
add_line(ctl, 'vdc/1', 'ADC vdc/1');

pll = add_fcn(ctl, 'SRF-PLL (srf_pll)', fullfile(here, 'blocks', 'srf_pll_block.m'), [260 20 400 110]);
ref = add_fcn(ctl, 'Reference (apf_reference)', fullfile(here, 'blocks', 'apf_reference_block.m'), [470 110 620 190]);
cc = add_fcn(ctl, 'Current + DC-link control (current_controller)', ...
    fullfile(here, 'blocks', 'apf_control_block.m'), [700 40 900 340]);
%#ok<*NASGU>

add_line(ctl, 'phases a,b vg/1', 'SRF-PLL (srf_pll)/1', 'autorouting', 'smart');
add_line(ctl, 'phases a,b il/1', 'Reference (apf_reference)/1', 'autorouting', 'smart');
add_line(ctl, 'SRF-PLL (srf_pll)/1', 'Reference (apf_reference)/2', 'autorouting', 'smart');
add_line(ctl, 'SRF-PLL (srf_pll)/4', 'Reference (apf_reference)/3', 'autorouting', 'smart');

cname = 'Current + DC-link control (current_controller)';
add_line(ctl, 'phases a,b vg/1', [cname '/1'], 'autorouting', 'smart');
add_line(ctl, 'phases a,b il/1', [cname '/2'], 'autorouting', 'smart');
add_line(ctl, 'phases a,b if/1', [cname '/3'], 'autorouting', 'smart');
add_line(ctl, 'ADC vdc/1', [cname '/4'], 'autorouting', 'smart');
add_line(ctl, 'Reference (apf_reference)/1', [cname '/5'], 'autorouting', 'smart');
add_line(ctl, 'Reference (apf_reference)/2', [cname '/6'], 'autorouting', 'smart');
add_line(ctl, 'SRF-PLL (srf_pll)/2', [cname '/7'], 'autorouting', 'smart');
add_line(ctl, 'SRF-PLL (srf_pll)/4', [cname '/8'], 'autorouting', 'smart');
add_line(ctl, 'run_request/1', [cname '/9'], 'autorouting', 'smart');

% Duties computed in frame k are loaded at the next carrier boundary.
add_block('simulink/Discrete/Unit Delay', [ctl '/next frame duty'], 'SampleTime', 'Ts', ...
    'Position', [960 45 1000 75]);
add_block('simulink/Discrete/Unit Delay', [ctl '/next frame enable'], 'SampleTime', 'Ts', ...
    'Position', [960 95 1000 125]);
add_line(ctl, [cname '/1'], 'next frame duty/1');
add_line(ctl, [cname '/2'], 'next frame enable/1');

pwm = [ctl '/PWM 10 kHz + dead time (three_phase_pwm)'];
add_block('simulink/Ports & Subsystems/Subsystem', pwm, 'Position', [1060 40 1220 130]);
delete_line(pwm, 'In1/1', 'Out1/1');
delete_block([pwm '/In1']); delete_block([pwm '/Out1']);
build_pwm(pwm);
add_line(ctl, 'next frame duty/1', 'PWM 10 kHz + dead time (three_phase_pwm)/1');
add_line(ctl, 'next frame enable/1', 'PWM 10 kHz + dead time (three_phase_pwm)/2');

add_block('simulink/Sinks/Out1', [ctl '/gates'], 'Position', [1280 75 1310 89]);
add_block('simulink/Sinks/Out1', [ctl '/switching'], 'Position', [1280 150 1310 164]);
add_block('simulink/Sinks/Out1', [ctl '/status'], 'Position', [1280 300 1310 314]);
add_line(ctl, 'PWM 10 kHz + dead time (three_phase_pwm)/1', 'gates/1');
add_line(ctl, 'next frame enable/1', 'switching/1', 'autorouting', 'smart');

% status = [locked ready switching faults(4) freq idc_cmd vdc_target vdc_avg pll_err]
add_block('simulink/Signal Routing/Mux', [ctl '/status mux'], 'Inputs', '[1 1 1 4 1 1 1 1 1]', ...
    'Position', [1200 220 1205 400]);
add_line(ctl, 'SRF-PLL (srf_pll)/4', 'status mux/1', 'autorouting', 'smart');
add_line(ctl, [cname '/7'], 'status mux/2', 'autorouting', 'smart');
add_line(ctl, 'next frame enable/1', 'status mux/3', 'autorouting', 'smart');
add_line(ctl, [cname '/3'], 'status mux/4', 'autorouting', 'smart');
add_line(ctl, 'SRF-PLL (srf_pll)/3', 'status mux/5', 'autorouting', 'smart');
add_line(ctl, [cname '/4'], 'status mux/6', 'autorouting', 'smart');
add_line(ctl, [cname '/5'], 'status mux/7', 'autorouting', 'smart');
add_line(ctl, [cname '/6'], 'status mux/8', 'autorouting', 'smart');
add_line(ctl, 'SRF-PLL (srf_pll)/5', 'status mux/9', 'autorouting', 'smart');
add_line(ctl, 'status mux/1', 'status/1');
add_block('simulink/Sinks/Terminator', [ctl '/amp'], 'Position', [440 90 460 110]);
add_line(ctl, 'SRF-PLL (srf_pll)/6', 'amp/1', 'autorouting', 'smart');
add_block('simulink/Sinks/Terminator', [ctl '/mean_d'], 'Position', [660 200 680 220]);
add_line(ctl, 'Reference (apf_reference)/3', 'mean_d/1', 'autorouting', 'smart');
end


function build_pwm(pwm)
% Center-aligned 10 kHz carrier (0 at the frame boundary, where the ADC
% samples). Upper switch on while carrier < duty, as in three_phase_pwm.sv.
% Shifting the two comparators by +/- dtc leaves Td between every
% upper/lower transition.
add_block('simulink/Sources/In1', [pwm '/duty'], 'Position', [20 40 50 54]);
add_block('simulink/Sources/In1', [pwm '/enable'], 'Position', [20 200 50 214]);
add_block('simulink/Sources/Repeating Sequence', [pwm '/carrier'], 'rep_seq_t', '[0 Ts/2 Ts]', ...
    'rep_seq_y', '[0 1 0]', 'Position', [20 110 60 140]);
add_block('simulink/Math Operations/Bias', [pwm '/d - dtc'], 'Bias', '-dtc', 'Position', [100 30 140 60]);
add_block('simulink/Math Operations/Bias', [pwm '/d + dtc'], 'Bias', 'dtc', 'Position', [100 70 140 100]);
add_block('simulink/Logic and Bit Operations/Relational Operator', [pwm '/upper'], 'Operator', '>', ...
    'Position', [190 40 220 90]);
add_block('simulink/Logic and Bit Operations/Relational Operator', [pwm '/lower'], 'Operator', '<', ...
    'Position', [190 110 220 160]);
add_line(pwm, 'duty/1', 'd - dtc/1');
add_line(pwm, 'duty/1', 'd + dtc/1');
add_line(pwm, 'd - dtc/1', 'upper/1');
add_line(pwm, 'carrier/1', 'upper/2');
add_line(pwm, 'd + dtc/1', 'lower/1');
add_line(pwm, 'carrier/1', 'lower/2');
add_block('simulink/Signal Routing/Mux', [pwm '/mux'], 'Inputs', '2', 'Position', [260 40 265 160]);
add_line(pwm, 'upper/1', 'mux/1');
add_line(pwm, 'lower/1', 'mux/2');
% Universal Bridge pulse order: [A upper, A lower, B upper, B lower, C upper, C lower]
add_block('simulink/Signal Routing/Selector', [pwm '/bridge order'], 'InputPortWidth', '6', ...
    'Indices', '[1 4 2 5 3 6]', 'Position', [300 85 340 115]);
add_line(pwm, 'mux/1', 'bridge order/1');
add_block('simulink/Signal Attributes/Data Type Conversion', [pwm '/to double'], ...
    'OutDataTypeStr', 'double', 'Position', [370 85 410 115]);
add_line(pwm, 'bridge order/1', 'to double/1');
add_block('simulink/Math Operations/Product', [pwm '/gate enable'], 'Position', [450 90 480 140]);
add_line(pwm, 'to double/1', 'gate enable/1');
add_line(pwm, 'enable/1', 'gate enable/2', 'autorouting', 'smart');
add_block('simulink/Sinks/Out1', [pwm '/gates'], 'Position', [520 108 550 122]);
add_line(pwm, 'gate enable/1', 'gates/1');
end


function blk = add_fcn(sys, name, codefile, pos)
% MATLAB Function block whose code is codefile; the input named P becomes
% a parameter (the struct P from apf_params.m).
blk = [sys '/' name];
add_block('simulink/User-Defined Functions/MATLAB Function', blk, 'Position', pos);
chart = find(sfroot, '-isa', 'Stateflow.EMChart', 'Path', blk);
chart.Script = fileread(codefile);
p = find(chart, '-isa', 'Stateflow.Data', 'Name', 'P');
p.Scope = 'Parameter';
end
