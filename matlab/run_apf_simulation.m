% Runs apf_system.slx and reports the same figures of merit as
% model/analyze_system.py does for the RTL simulation (sim/tb_apf_system.sv).
%
%   >> run_apf_simulation              % full 1 s run (builds the model if missing)
%   >> T_end = 0.3; run_apf_simulation % shorter run: set variables after apf_params
%
% Figures are written to matlab/results/.

if verLessThan('matlab', '9.11')
    error('apf:version', 'MATLAB R2021b or newer is needed (this is %s).', version('-release'));
end
if exist('powerlib', 'file') ~= 4
    warning('apf:toolbox', ['Simscape Electrical (Specialized Power Systems) does not seem to be ' ...
        'installed; the power-stage blocks will not load.']);
end
here = fileparts(mfilename('fullpath'));
mdl = 'apf_system';
if ~exist(fullfile(here, [mdl '.slx']), 'file')
    build_apf_model;
end
T_end_override = [];
if exist('T_end', 'var'), T_end_override = T_end; end
load_system(fullfile(here, [mdl '.slx']));   % its PostLoadFcn also runs apf_params
run(fullfile(here, 'apf_params.m'));
if ~isempty(T_end_override), T_end = T_end_override; end
clear T_end_override
fprintf('Simulating %.2f s ...\n', T_end);
tic;
out = sim(mdl, 'StopTime', num2str(T_end));
fprintf('Simulation took %.0f s\n', toc);

res = analyze_apf_results(out, fullfile(here, 'results'), t_step);
if usejava('desktop')
    set(findall(0, 'Type', 'figure', 'Visible', 'off'), 'Visible', 'on');   % hidden while saving
end
