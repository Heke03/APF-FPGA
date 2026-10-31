function build_apf_model_H2()
% H2: builds apf_system_H2.slx = apf_system.slx plus a "Sensors + ADC" block
% between the power stage and the controller, for the sensor / ADC study
% (sensor_adc_study_H2.m). apf_system.slx itself is not changed.
%
%   >> build_apf_model_H2       % (re)creates matlab/apf_system_H2.slx
%
% The measurement chain is set by the struct S from sensor_params_H2.m:
%   power stage -> sensor lag + delay (every 0.5 us step) -> ADC sample at
%   S.conv after the carrier boundary -> 12-bit codes + noise -> controller.
% The controller runs at that same instant (S.conv after the boundary, when the
% FPGA gets the codes) and its duties still load at the next carrier boundary,
% as in rtl/apf_core.sv. With S.conv = 0 the timing is that of apf_system.slx.

here = fileparts(mfilename('fullpath'));
base = 'apf_system';
mdl = 'apf_system_H2';
file = fullfile(here, [mdl '.slx']);
if ~exist(fullfile(here, [base '.slx']), 'file'), build_apf_model; end
if bdIsLoaded(mdl), close_system(mdl, 0); end
if bdIsLoaded(base), close_system(base, 0); end
if exist(file, 'file'), delete(file); end
evalin('base', sprintf('addpath(''%s''); run(''%s''); S = sensor_params_H2;', here, fullfile(here, 'apf_params.m')));

load_system(fullfile(here, [base '.slx']));
save_system(base, file);                % the copy in memory is now apf_system_H2
setup = sprintf(['addpath(fileparts(get_param(''%s'',''FileName''))); ' ...
    'if ~exist(''P'',''var''), run(fullfile(fileparts(get_param(''%s'',''FileName'')),''apf_params.m'')); end; ' ...
    'if ~exist(''S'',''var''), S = sensor_params_H2; end'], mdl, mdl);
set_param(mdl, 'PostLoadFcn', setup, 'InitFcn', setup);

%% ===================== Sensors + ADC block =====================
ctl = [mdl '/FPGA controller (apf_core)'];
ctl_name = 'FPGA controller (apf_core)';
tags = {'F_vg', 'F_il', 'F_if', 'F_vdc'};
for k = 1:4
    delete_line(mdl, [tags{k} '/1'], sprintf('%s/%d', ctl_name, k));
    set_param([mdl '/' tags{k}], 'Position', [180 525 + 30 * (k - 1) 230 545 + 30 * (k - 1)]);
end
set_param([mdl '/Run request'], 'Position', [200 680 230 710]);
delete_line(mdl, 'Run request/1', [ctl_name '/5']);
add_line(mdl, 'Run request/1', [ctl_name '/5'], 'autorouting', 'smart');

sen = [mdl '/Sensors + ADC (H2)'];
add_block('simulink/Ports & Subsystems/Subsystem', sen, 'Position', [270 515 370 655]);
delete_line(sen, 'In1/1', 'Out1/1');
delete_block([sen '/In1']); delete_block([sen '/Out1']);
build_sensors(sen, here);
for k = 1:4
    add_line(mdl, [tags{k} '/1'], sprintf('Sensors + ADC (H2)/%d', k));
    add_line(mdl, sprintf('Sensors + ADC (H2)/%d', k), sprintf('%s/%d', ctl_name, k));
end

%% ===================== controller timing =====================
% The controller reads the codes when the ADC delivers them (S.conv after the
% boundary) ...
for b = {'ADC vg', 'ADC il', 'ADC if', 'ADC vdc'}
    set_param([ctl '/' b{1}], 'SampleTime', '[Ts S.conv]');
end
% The MATLAB Function blocks inherit their rate; run_request comes from the
% boundary rate, which would make the control block run at the GCD (4 us), so fix
% all three to the frame rate.
for b = {'SRF-PLL (srf_pll)', 'Reference (apf_reference)', 'Current + DC-link control (current_controller)'}
    set_param([ctl '/' b{1}], 'SystemSampleTime', '[Ts S.conv]');
end
% ... and its result is loaded into the PWM at the next carrier boundary: hold it
% for one power-stage step, then sample at the boundary. For S.conv = 0 this is
% the one-frame Unit Delay of apf_system.slx.
y = [45 95];
names = {'next frame duty', 'next frame enable'};
for k = 1:2
    blk = [ctl '/' names{k}];
    set_param(blk, 'SampleTime', 'Tps', 'Position', [915 y(k) 945 y(k) + 30]);
    ph = get_param(blk, 'PortHandles');
    ln = get_param(ph.Outport, 'Line');
    dst = get_param(ln, 'DstPortHandle');
    delete_line(ln);
    z = add_block('simulink/Discrete/Zero-Order Hold', [blk ' at boundary'], 'SampleTime', 'Ts', ...
        'Position', [985 y(k) 1015 y(k) + 30]);
    zp = get_param(z, 'PortHandles');
    add_line(ctl, ph.Outport, zp.Inport);
    for d = dst(:).'
        add_line(ctl, zp.Outport, d, 'autorouting', 'smart');
    end
end

note = find_system(mdl, 'FindAll', 'on', 'SearchDepth', 1, 'Type', 'annotation');
for h = note(:).'
    a = get_param(h, 'Object');
    if contains(a.Text, 'Three-phase shunt active power filter')
        a.Text = sprintf(['Three-phase shunt active power filter: H2 sensor / ADC study model\n' ...
            'Same as apf_system.slx plus "Sensors + ADC (H2)": sensor lag, delay before the sample, ADC timing, 12-bit codes + noise.\n' ...
            'Chain settings: struct S from sensor_params_H2.m. Run matlab/sensor_adc_study_H2.m for all scenarios.']);
    end
end

save_system(mdl, file);
fprintf('Saved %s\n', file);
end


function build_sensors(sen, here)
add_block('simulink/Sources/In1', [sen '/vg_abc'], 'Position', [20 40 50 54]);
add_block('simulink/Sources/In1', [sen '/il_abc'], 'Position', [20 90 50 104]);
add_block('simulink/Sources/In1', [sen '/if_abc'], 'Position', [20 140 50 154]);
add_block('simulink/Sources/In1', [sen '/vdc'], 'Position', [20 190 50 204]);
add_block('simulink/Signal Routing/Mux', [sen '/mux'], 'Inputs', '[3 3 3 1]', 'Position', [90 30 95 210]);
ins = {'vg_abc', 'il_abc', 'if_abc', 'vdc'};
for k = 1:4
    add_line(sen, [ins{k} '/1'], sprintf('mux/%d', k));
end
% the 7 ADC channels of apf_core: vg_a vg_b il_a il_b if_a if_b vdc
add_block('simulink/Signal Routing/Selector', [sen '/7 channels'], 'InputPortWidth', '10', ...
    'Indices', '[1 2 4 5 7 8 10]', 'Position', [130 105 170 135]);
add_line(sen, 'mux/1', '7 channels/1');

add_fcn(sen, 'Sensor lag + delay before the sample', ...
    fullfile(here, 'blocks', 'sensor_chain_block_H2.m'), [210 95 340 145], {'S', 'Tps'}, 'Tps');
add_line(sen, '7 channels/1', 'Sensor lag + delay before the sample/1');
add_block('simulink/Discrete/Zero-Order Hold', [sen '/ADC sample (S.conv after boundary)'], ...
    'SampleTime', '[Ts S.conv]', 'Position', [380 105 420 135]);
add_line(sen, 'Sensor lag + delay before the sample/1', 'ADC sample (S.conv after boundary)/1');
add_block('simulink/Sources/Random Number', [sen '/ADC noise'], 'Mean', 'zeros(7,1)', ...
    'Variance', '1', 'Seed', 'S.seed + (0:6)''', 'SampleTime', '[Ts S.conv]', ...
    'Position', [380 170 420 200]);
add_fcn(sen, '12-bit ADC codes', fullfile(here, 'blocks', 'adc_quantizer_block_H2.m'), ...
    [470 80 600 220], {'S'}, '-1');
add_line(sen, 'ADC sample (S.conv after boundary)/1', '12-bit ADC codes/1');
add_line(sen, 'ADC noise/1', '12-bit ADC codes/2');
outs = {'vg_abc_meas', 'il_abc_meas', 'if_abc_meas', 'vdc_meas'};
for k = 1:4
    add_block('simulink/Sinks/Out1', [sen '/' outs{k}], 'Position', [660 70 + 45 * k 690 84 + 45 * k]);
    add_line(sen, sprintf('12-bit ADC codes/%d', k), [outs{k} '/1']);
end
end


function blk = add_fcn(sys, name, codefile, pos, params, ts)
% MATLAB Function block whose code is codefile; inputs named in params become
% parameters taken from the base workspace.
blk = [sys '/' name];
add_block('simulink/User-Defined Functions/MATLAB Function', blk, 'Position', pos);
chart = find(sfroot, '-isa', 'Stateflow.EMChart', 'Path', blk);
chart.Script = fileread(codefile);
for k = 1:numel(params)
    p = find(chart, '-isa', 'Stateflow.Data', 'Name', params{k});
    p.Scope = 'Parameter';
end
set_param(blk, 'SystemSampleTime', ts);
end
