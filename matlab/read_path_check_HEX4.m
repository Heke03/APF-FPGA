function T = read_path_check_HEX4(src)
% HEX4: tests quartus/read_capture_HEX4.tcl with nothing plugged in. Runs the real
% script inside the real quartus_stp, with the board replaced by sim/mock_quartus_HEX4.tcl.
%
%   T = read_path_check_HEX4(recording_folder)
%
% Every scenario states what must happen. Good reads must return the recording bit
% for bit; bad ones must end in a clear ERROR and leave no recording behind. Then the
% script is broken on purpose (one read of INF instead of several) and the collision
% scenario must catch it, which proves that scenario can fail.
%
% What this cannot prove: that the real cable and memories answer as the help says.
here = fileparts(mfilename('fullpath'));
root = fileparts(here);
stp = fullfile(getenv_or('QUARTUS_ROOTDIR', 'C:\altera_lite\25.1std\quartus'), 'bin64', 'quartus_stp.exe');
mock = fullfile(root, 'sim', 'mock_quartus_HEX4.tcl');
script = fullfile(root, 'quartus', 'read_capture_HEX4.tcl');
tmp = tempname; mkdir(tmp);
cleanup = onCleanup(@() rmdir(tmp, 's'));

%          scenario               expect     must appear in the output
cases = {
    'ok',                  'same',    "OK: recording saved"
    'collisions',          'same',    "OK: recording saved"
    'recording',           'warn',    "WARN: the board is still recording"
    'low_address_first',   'error',   "never read the same"
    'no_cable',            'error',   "no USB-Blaster found"
    'other_cable',         'error',   "no USB-Blaster found"
    'wrong_device',        'error',   "does not see the DE2-115"
    'cable_busy',          'error',   "Close the Quartus Programmer"
    'no_design',           'error',   "has no memory"
    'memory_missing',      'error',   "has no memory VG"
    'wrong_size',          'error',   "memory VD is 1024"
    'wrong_design',        'error',   "never read the same"
    'never_agrees',        'error',   "never read the same"
    'key1_during_read',    'error',   "changed while it was being read"
    'short_answer',        'error',   "hex digits"
    'read_throws',         'error',   "JTAG communication error"
    };
n = size(cases, 1);
result = strings(n, 1); passed = false(n, 1);
for k = 1:n
    [name, expect, text] = cases{k, :};
    out = fullfile(tmp, name);
    txt = run_mock(stp, mock, script, name, src, out, '');
    saved = isfolder(out) && all(arrayfun(@(f) isfile(fullfile(out, f + ".txt")), ["IG" "IL" "II" "VD" "VG" "INF"]));
    has = contains(txt, text);
    switch expect
        case 'same',   ok = has && saved && same_recording(src, out); w = "bit for bit";
        case 'warn',   ok = has && saved; w = "warned";
        case 'error',  ok = has && ~saved && contains(txt, "ERROR:"); w = "clear error, nothing saved";
    end
    passed(k) = ok;
    result(k) = w;
end
T = table(string(cases(:, 1)), result, passed, 'VariableNames', {'scenario', 'expected', 'passed'});

% status mode
txt = run_mock(stp, mock, script, 'ok', src, fullfile(tmp, 'status_only'), 'status');
st_ok = contains(txt, "STATUS ready=1") && contains(txt, "OK: status read") && ~isfolder(fullfile(tmp, 'status_only'));
T = [T; {"status_mode", "prints STATUS, saves nothing", st_ok}];

% many different collision patterns (each word of each read wrong with chance 1/8)
tries = 12;
good = 0;
for k = 1:tries
    setenv('MOCK_SEED', num2str(k));
    out = fullfile(tmp, sprintf('seed_%d', k));
    run_mock(stp, mock, script, 'collisions', src, out, '');
    good = good + (isfolder(out) && same_recording(src, out));
end
T = [T; {"collisions_many_seeds", sprintf("bit for bit in %d of %d runs", good, tries), good == tries}];

% break the script on purpose: one read of INF, as read_capture_H3.tcl did. The
% collision scenario must now fail, or the test above proves nothing.
broken = fullfile(tmp, 'broken.tcl');
writelines(replace(readlines(script), "set CONSENSUS 3", "set CONSENSUS 1"), broken);
bad = 0;
for k = 1:tries
    setenv('MOCK_SEED', num2str(k));
    out = fullfile(tmp, sprintf('broken_%d', k));
    run_mock(stp, mock, broken, 'collisions', src, out, '');
    if ~(isfolder(out) && same_recording(src, out)), bad = bad + 1; end
end
setenv('MOCK_SEED', '');
T = [T; {"broken_script_is_caught", sprintf("one INF read: wrong recording in %d of %d runs", bad, tries), bad > 0}];

disp(T)
if all(T.passed)
    fprintf('READ PATH CHECK: all %d passed\n', height(T));
else
    fprintf('READ PATH CHECK: %d FAILED\n', sum(~T.passed));
end
end

function txt = run_mock(stp, mock, script, name, src, out, mode)
[~, txt] = system(sprintf('"%s" -t "%s" "%s" %s "%s" "%s" %s', stp, mock, script, name, src, out, mode));
txt = string(txt);
end

function ok = same_recording(a, b)
ok = true;
for f = ["IG" "IL" "II" "VD" "VG" "INF"]
    x = upper(strtrim(readlines(fullfile(a, f + ".txt"), 'EmptyLineRule', 'skip')));
    p = fullfile(b, f + ".txt");
    if ~isfile(p), ok = false; return, end
    y = upper(strtrim(readlines(p, 'EmptyLineRule', 'skip')));
    if ~isequal(x, y), ok = false; return, end
end
end

function v = getenv_or(name, dflt)
v = getenv(name);
if isempty(v), v = dflt; end
end
