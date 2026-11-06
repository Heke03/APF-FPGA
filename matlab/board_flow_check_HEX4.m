function T = board_flow_check_HEX4(folder, only)
% HEX4: runs the user's guided board test (run_board_HEX4) from start to end with no
% board, unchanged except for source = "board". Quartus itself is swapped for small
% .bat files in a pretend QUARTUS_ROOTDIR: jtagconfig and quartus_pgm print what the
% real ones print, and quartus_stp runs the REAL read script against a pretend board
% (sim/fake_board_HEX4.tcl), which flips the switches by itself.
%
%   T = board_flow_check_HEX4('...\matlab\5_Board_Test_HEX4')
%   T = board_flow_check_HEX4(folder, ["no_cable" "pgm_fails"])    % only these scenarios
%
% Together the 13 need all 3 expected recordings. These 8 need only rec1_sw0_up:
% no_cable, chip_missing, pgm_fails, never_flip, no_key1, cable_lost, key1_during_read,
% no_simulation_recordings
%
% A good run must pass and return the recordings bit for bit. Every staged failure
% must stop with a clear message, or show up as a failed check in the results.
% What this cannot prove: the real cable, the real chip, and the real display.
root = fileparts(fileparts(mfilename('fullpath')));
real_stp = fullfile(real_root(), 'bin64', 'quartus_stp.exe');
tmp = tempname; mkdir(tmp);
fake = fullfile(tmp, 'quartus', 'bin64'); mkdir(fake);
fake_tcl = fullfile(root, 'sim', 'fake_board_HEX4.tcl');
write_bat(fullfile(fake, 'quartus_stp.bat'), sprintf('@"%s" -t "%s" %%2 %%3 %%4', real_stp, fake_tcl));
write_bat(fullfile(fake, 'jtagconfig.bat'), jtag_script());
write_bat(fullfile(fake, 'quartus_pgm.bat'), pgm_script());

expected = fullfile(folder, 'support', 'expected');
old_root = getenv('QUARTUS_ROOTDIR');
restore = onCleanup(@() setenv('QUARTUS_ROOTDIR', old_root));
setenv('QUARTUS_ROOTDIR', fullfile(tmp, 'quartus'));
setenv('FAKE_EXPECTED', expected);

% staged recordings
bad_order = stage(tmp, expected, 'rec1_sw0_up', 'bad_order', @(n, w) rotate_vg(n, w));
dead_apf = stage(tmp, expected, 'rec1_sw0_up', 'dead_apf', @(n, w) dead(n, w));

%     scenario               recording overrides                what must happen                         text
cases = {
    'normal',                {},                                'pass',  "BOARD TEST PASSED"
    'switch_up_at_load',     {},                                'pass',  "BOARD TEST PASSED"
    'no_cable',              {},                                'error', "does not see the USB-Blaster"
    'chip_missing',          {},                                'error', "does not see the EP4CE115"
    'pgm_fails',             {},                                'error', "Loading the design failed"
    'never_flip',            {},                                'error', "Waited"
    'no_key1',               {},                                'error', "Waited"
    'cable_lost',            {'FAKE_SRC_2', fullfile(expected, 'rec1_sw0_up')}, 'error', "no USB-Blaster found"
    'key1_during_read',      {},                                'error', "changed while it was being read"
    'wrong_switch',          {'FAKE_SRC_1', fullfile(expected, 'rec2_sw1_up')}, 'fail', "what triggered it"
    'bad_order',             {'FAKE_SRC_1', bad_order},         'fail',  "one clean 50 Hz sine"
    'dead_apf',              {'FAKE_SRC_1', dead_apf},          'fail',  "DC link charged"
    % the simulated recordings are not there: all 3 steps must still run and report, with no crash.
    % The pretend board then gives recording 1 three times, so steps 2 and 3 must fail their first check.
    'no_simulation_recordings', {'FAKE_SRC_2', fullfile(expected, 'rec1_sw0_up'), 'FAKE_SRC_3', fullfile(expected, 'rec1_sw0_up')}, 'fail', "what triggered it"
    };
if nargin >= 2, cases = cases(ismember(string(cases(:, 1)), string(only)), :); end
n = size(cases, 1);
got = strings(n, 1); passed = false(n, 1); secs = zeros(n, 1);
here0 = pwd; back = onCleanup(@() cd(here0));
for k = 1:n
    [name, env, want, text] = cases{k, :};
    run_dir = fullfile(tmp, name);
    copy_user_folder(folder, run_dir);
    setenv('FAKE_SCENARIO', name);
    setenv('FAKE_STATE', fullfile(tmp, [name '.state']));
    setenv('FAKE_SRC_1', ''); setenv('FAKE_SRC_2', ''); setenv('FAKE_SRC_3', '');
    for e = 1:2:numel(env), setenv(env{e}, env{e + 1}); end
    if name == "no_simulation_recordings", rmdir(fullfile(run_dir, 'support', 'expected'), 's'); end
    t0 = tic;
    [outcome, msg, out] = run_one(run_dir);
    secs(k) = toc(t0);
    close all force
    switch want
        case 'pass'
            passed(k) = outcome == "finished" && contains(out, text) && recordings_identical(run_dir, expected);
            got(k) = "passed, recordings bit for bit";
        case 'error'
            passed(k) = outcome == "error" && contains(msg, text);
            got(k) = "stopped: " + extractBefore(msg + newline, newline);
        case 'fail'
            passed(k) = outcome == "finished" && contains(out, "BOARD TEST FAILED") && failed_check(run_dir, text);
            if name == "no_simulation_recordings", passed(k) = passed(k) && contains(out, "NOT compared with the simulation"); end
            got(k) = "BOARD TEST FAILED, check: " + text;
    end
    if ~passed(k), got(k) = "NOT AS EXPECTED (" + outcome + "): " + strtrim(extractBefore(msg + " " + string(out) + string(repmat(' ', 1, 300)), 300)); end
    fprintf('%-20s %-6s %4.0f s  %s\n', name, string(passed(k)), secs(k), extractBefore(got(k) + repmat(' ', 1, 90), 90));
end
setenv('FAKE_SRC_1', ''); setenv('FAKE_SRC_2', ''); setenv('FAKE_SRC_3', '');
T = table(string(cases(:, 1)), got, passed, round(secs), 'VariableNames', {'scenario', 'result', 'passed', 'seconds'});
if all(passed)
    fprintf('BOARD FLOW CHECK: all %d run passed\n', n);
else
    fprintf('BOARD FLOW CHECK: %d FAILED\n', sum(~passed));
end
end

function [outcome, msg, out] = run_one(run_dir)
% in a function of its own, so the script's variables stay in here
cd(run_dir); rehash;
outcome = "finished"; msg = ""; out = "";
try
    out = evalc('run_board_HEX4');
catch e
    outcome = "error"; msg = string(e.message);
end
out = string(out);
end

function copy_user_folder(folder, run_dir)
mkdir(run_dir);
copyfile(fullfile(folder, 'support'), fullfile(run_dir, 'support'));
s = readlines(fullfile(folder, 'run_board_HEX4.m'));
hit = s == 'source = "simulation";     % "board" or "simulation"';
assert(sum(hit) == 1, 'the source line of run_board_HEX4 has changed');
s(hit) = 'source = "board";';
hit = startsWith(s, 'timeout_s = 180;');
assert(sum(hit) == 1, 'the timeout line of run_board_HEX4 has changed');
s(hit) = 'timeout_s = 25;';
writelines(s, fullfile(run_dir, 'run_board_HEX4.m'));
end

function ok = recordings_identical(run_dir, expected)
d = dir(fullfile(run_dir, 'recordings', '*'));
d = d([d.isdir] & ~startsWith({d.name}, '.'));
ok = numel(d) == 1;
if ~ok, return, end
for r = ["rec1_sw0_up" "rec2_sw1_up" "rec3_sw0_down"]
    for f = ["IG" "IL" "II" "VD" "VG" "INF"]
        a = upper(strtrim(readlines(fullfile(expected, r, f + ".txt"), 'EmptyLineRule', 'skip')));
        p = fullfile(run_dir, 'recordings', d.name, r, f + ".txt");
        if ~isfile(p) || ~isequal(a, upper(strtrim(readlines(p, 'EmptyLineRule', 'skip')))), ok = false; return, end
    end
end
end

function ok = failed_check(run_dir, text)
d = dir(fullfile(run_dir, 'recordings', '*', 'results.csv'));
ok = false;
if isempty(d), return, end
T = readtable(fullfile(d(1).folder, d(1).name), 'TextType', 'string');
ok = any(contains(T.check, text) & ~logical(T.pass));
end

function out = stage(tmp, expected, name, new, change)
out = fullfile(tmp, 'staged', new);
mkdir(out);
for f = ["IG" "IL" "II" "VD" "VG" "INF"]
    w = readlines(fullfile(expected, name, f + ".txt"), 'EmptyLineRule', 'skip');
    writelines(change(f, w), fullfile(out, f + ".txt"));
end
end

function w = rotate_vg(n, w)
% the grid voltage channel read in the wrong order: its second half in front of its first half
if n == "VG", w = [w(end/2 + 1 + 37:end); w(1:end/2 + 37)]; end
end

function w = dead(n, w)
% the controller never started: no inverter current, DC link stays at the precharge
if n == "II", w(:) = "0000"; end
if n == "VD", w(:) = upper(string(dec2hex(173 * 64, 4))); end
if n == "IG", w = readlines(fullfile(getenv('FAKE_EXPECTED'), 'rec1_sw0_up', 'IL.txt'), 'EmptyLineRule', 'skip'); end
end

function s = jtag_script()
s = [ ...
    '@echo off' newline ...
    'if "%FAKE_SCENARIO%"=="no_cable" ( echo No JTAG hardware available & exit /b 1 )' newline ...
    'echo 1) USB-Blaster [USB-0]' newline ...
    'if "%FAKE_SCENARIO%"=="chip_missing" ( echo   Unable to read device chain - JTAG chain broken & exit /b 0 )' newline ...
    'echo   020F70DD   EP3C120/EP4CE115' newline];
end

function s = pgm_script()
s = [ ...
    '@echo off' newline ...
    'if "%FAKE_SCENARIO%"=="pgm_fails" ( echo Error ^(209053^): Unexpected error in JTAG server & echo Error: Quartus Prime Programmer was unsuccessful. 1 error, 0 warnings & exit /b 3 )' newline ...
    'echo Info: Quartus Prime Programmer was successful. 0 errors, 0 warnings' newline];
end

function write_bat(p, s)
fd = fopen(p, 'w'); fprintf(fd, '%s\r\n', s); fclose(fd);
end

function r = real_root()
r = getenv('QUARTUS_ROOTDIR');
if isempty(r), r = 'C:\altera_lite\25.1std\quartus'; end
end
