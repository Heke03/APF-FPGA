function build_apf_vps_H3()
% H3: builds apf_vps_H3.slx - the controller of apf_system.slx (copied unchanged)
% in closed loop with the virtual power stage (blocks/vps_block_H3.m) instead of
% the Simscape power stage. The virtual power stage is what will run inside the
% FPGA on the DE2-115, so this model shows the board demo before it is built.
%
%   >> build_apf_vps_H3        % (re)creates matlab/apf_vps_H3.slx
%   >> V = vps_params_H3(true);  sim('apf_vps_H3')   % fixed point (as in the FPGA)
%   >> V = vps_params_H3(false); sim('apf_vps_H3')   % real-number reference

here = fileparts(mfilename('fullpath'));
mdl = 'apf_vps_H3';
file = fullfile(here, [mdl '.slx']);
if ~exist(fullfile(here, 'apf_system.slx'), 'file'), build_apf_model; end
if bdIsLoaded(mdl), close_system(mdl, 0); end
if exist(file, 'file'), delete(file); end
evalin('base', sprintf('addpath(''%s''); run(''%s''); V = vps_params_H3(true);', here, fullfile(here, 'apf_params.m')));
load_system(fullfile(here, 'apf_system.slx'));

new_system(mdl);
set_param(mdl, 'SolverType', 'Fixed-step', 'Solver', 'FixedStepDiscrete', ...
    'FixedStep', 'V.H', 'StopTime', 'T_end', 'EnableMultiTasking', 'off', ...
    'ReturnWorkspaceOutputs', 'on');
setup = sprintf(['addpath(fileparts(get_param(''%s'',''FileName''))); ' ...
    'if ~exist(''P'',''var''), run(fullfile(fileparts(get_param(''%s'',''FileName'')),''apf_params.m'')); end; ' ...
    'if ~exist(''V'',''var''), V = vps_params_H3(true); end'], mdl, mdl);
set_param(mdl, 'PostLoadFcn', setup, 'InitFcn', setup);

%% controller (unchanged copy) and virtual power stage
ctl_name = 'FPGA controller (apf_core)';
add_block(['apf_system/' ctl_name], [mdl '/' ctl_name], 'Position', [420 120 620 260]);
% The copy re-infers the status mux sizes in a different order and rejects the
% 1x4 fault vector against the mux's "4"; let the mux take its input sizes as they come.
set_param([mdl '/' ctl_name '/status mux'], 'Inputs', '9');
vps_name = 'Virtual power stage (H3)';
vps = [mdl '/' vps_name];
add_block('simulink/User-Defined Functions/MATLAB Function', vps, 'Position', [760 110 960 270]);
chart = find(sfroot, '-isa', 'Stateflow.EMChart', 'Path', vps);
chart.Script = fileread(fullfile(here, 'blocks', 'vps_block_H3.m'));
p = find(chart, '-isa', 'Stateflow.Data', 'Name', 'V');
p.Scope = 'Parameter';
set_param(vps, 'SystemSampleTime', 'V.H');

add_block('simulink/Sources/Step', [mdl '/Run request'], 'Position', [300 225 330 255], ...
    'Time', 't_run', 'Before', '0', 'After', '1', 'SampleTime', 'Ts');
add_block('simulink/Sources/Step', [mdl '/Load step 33 -> 22 ohm'], 'Position', [650 290 680 320], ...
    'Time', 't_step', 'Before', '0', 'After', '1', 'SampleTime', 'Ts');

add_line(mdl, [ctl_name '/1'], [vps_name '/1'], 'autorouting', 'smart');   % gates
add_line(mdl, [ctl_name '/2'], [vps_name '/2'], 'autorouting', 'smart');   % switching = contactor
add_line(mdl, 'Load step 33 -> 22 ohm/1', [vps_name '/3'], 'autorouting', 'smart');
for k = 1:3                                                                % vg, il, if
    add_line(mdl, sprintf('%s/%d', vps_name, k), sprintf('%s/%d', ctl_name, k), 'autorouting', 'smart');
end
add_line(mdl, [vps_name '/5'], [ctl_name '/4'], 'autorouting', 'smart');   % vdc
add_line(mdl, 'Run request/1', [ctl_name '/5'], 'autorouting', 'smart');

%% scopes and logging (same layout as apf_system.slx, so analyze_apf_results works)
add_block('simulink/Signal Routing/Mux', [mdl '/Mux log'], 'Inputs', '[3 3 3 3 1]', ...
    'Position', [1060 100 1065 280]);
for k = 1:5
    add_line(mdl, sprintf('%s/%d', vps_name, k), sprintf('Mux log/%d', k), 'autorouting', 'smart');
end
add_block('simulink/Sinks/To Workspace', [mdl '/log power'], 'VariableName', 'sim_power', ...
    'SaveFormat', 'Structure With Time', 'SampleTime', 'T_log', 'Position', [1110 175 1190 205]);
add_line(mdl, 'Mux log/1', 'log power/1');
add_block('simulink/Sinks/Scope', [mdl '/Waveforms'], 'NumInputPorts', '5', ...
    'Position', [1110 300 1150 460]);
order = [1 4 2 3 5];                        % vg, grid current, load current, inverter current, Vdc
for k = 1:5
    add_line(mdl, sprintf('%s/%d', vps_name, order(k)), sprintf('Waveforms/%d', k), 'autorouting', 'smart');
end
add_block('simulink/Sinks/Display', [mdl '/shoot-through steps'], 'Position', [1110 500 1190 530]);
add_line(mdl, [vps_name '/6'], 'shoot-through steps/1', 'autorouting', 'smart');
add_block('simulink/Sinks/To Workspace', [mdl '/log shoot'], 'VariableName', 'sim_shoot', ...
    'SaveFormat', 'Array', 'SampleTime', 'Ts', 'Position', [1110 550 1190 580]);
add_line(mdl, [vps_name '/6'], 'log shoot/1', 'autorouting', 'smart');
add_block('simulink/Sinks/Scope', [mdl '/Controller status'], 'Position', [700 380 740 420]);
add_line(mdl, [ctl_name '/3'], 'Controller status/1', 'autorouting', 'smart');
add_block('simulink/Sinks/To Workspace', [mdl '/log controller'], 'VariableName', 'sim_ctrl', ...
    'SaveFormat', 'Structure With Time', 'SampleTime', 'Ts', 'Position', [700 440 780 470]);
add_line(mdl, [ctl_name '/3'], 'log controller/1', 'autorouting', 'smart');

note = Simulink.Annotation([mdl '/APF with the virtual power stage (H3)']);
note.Position = [120 15 900 70];
note.Text = sprintf(['Shunt APF controller (copied from apf_system.slx) + virtual power stage: the plant that will run inside the DE2-115 FPGA.\n' ...
    'Plant step 200 ns. V = vps_params_H3(true) -> fixed point, bit-exact with the FPGA; V = vps_params_H3(false) -> real numbers.\n' ...
    'Waveforms scope: grid voltage, grid current, load current, inverter current, DC link. Run matlab/vps_check_H3.m for the comparison.']);

save_system(mdl, file);
fprintf('Saved %s\n', file);
end
