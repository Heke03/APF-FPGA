function capture_check_H3
% H3: checks the two waveform recordings made in sim/tb_de2_115_H3.sv:
%   - every recorded grid-current sample is the sample the THD meter took
%     (sim/out/H3/board_samples.txt), in order, with nothing missing
%   - the recorded window position of the trigger sample matches the meter's
%   - the THD readings recomputed from the recording equal the board's readings
%
%   >> capture_check_H3        % after the board simulation (sim/run_board_H3.do)
odir = fullfile(fileparts(mfilename('fullpath')), '..', 'sim', 'out', 'H3');
s = readmatrix(fullfile(odir, 'board_samples.txt'), 'FileType', 'text');
is_all = floor((s + 2^13) / 2^14);                       % what the meter keeps of each sample
R = readmatrix(fullfile(odir, 'board_readings.txt'), 'FileType', 'text');   % t thd valid peak
for name = ["capture_run", "capture_step"]
    c = load_capture_H3(fullfile(odir, name));
    k = find(~isnan(c.ig));
    seq = c.is(k);
    n0 = find(is_all(1:end - 1) == seq(1) & is_all(2:end) == seq(2));                         % candidate starts
    n0 = n0(arrayfun(@(p) p + numel(seq) - 1 <= numel(is_all) && isequal(is_all(p:p + numel(seq) - 1), seq), n0));
    assert(isscalar(n0), '%s: the recording is not one stretch of the meter''s samples', name);
    kt = find(c.t == 0);
    n_trig = n0 + (kt - k(1)) - 1;                           % 0-based index of the trigger sample since reset
    pos_ok = isempty(c.window_start) || all(mod(n0 - 1 + (c.window_start - k(1)), 1000) == 0);
    % readings of the complete meter windows inside the recording
    w = c.window_start(c.window_start + 999 <= k(end));
    thd = arrayfun(@(a) thd_meter_H3(c.is(a:a + 999) * 2^14), w);
    n_end = n0 + (w + 999 - k(1));                          % 1-based index of each window's last sample
    board = R(n_end / 1000, 2);
    fprintf('%s: %s, %d samples (%d before the trigger), found at meter sample %d; trigger is sample %d since reset\n', ...
        name, c.event, numel(k), c.samples_before, n0 - 1, n_trig);
    fprintf('   window positions %s; THD from the recording %s, board display %s -> %s\n', ...
        string(pos_ok), mat2str(thd.' / 100), mat2str(board.' / 100), ...
        string(pos_ok && isequal(thd, board)));
end
end
