function T = board_check_H3
% H3: checks the THD readings of the board top level (sim/tb_de2_115_H3.sv)
% against matlab/thd_meter_H3.m. The testbench logs every sample the FPGA's
% meter takes (grid current a, 2^-24 A) and every reading; this recomputes the
% readings from the samples and compares them number for number.
%
%   >> board_check_H3          % after: vsim -c work.tb_de2_115_H3 -do "run -all; quit -f"
odir = fullfile(fileparts(mfilename('fullpath')), '..', 'sim', 'out', 'H3');
i24 = readmatrix(fullfile(odir, 'board_samples.txt'), 'FileType', 'text');
R = readmatrix(fullfile(odir, 'board_readings.txt'), 'FileType', 'text');   % t thd valid peak
[thd, valid] = thd_meter_H3(i24);
n = min(numel(thd), size(R, 1));
same = R(1:n, 2) == thd(1:n) & R(1:n, 3) == valid(1:n);
T = table(round(R(1:n, 1), 3), R(1:n, 2) / 100, thd(1:n) / 100, logical(R(1:n, 3)), round(R(1:n, 4) / 2^24, 2), same, ...
    'VariableNames', {'t_s', 'board_THD_pct', 'MATLAB_THD_pct', 'valid', 'peak_A_same_window', 'same'});
disp(T)
verdict = ["MISMATCH", "BOARD THD BIT-EXACT"];
fprintf('%d samples, %d readings compared: %d different -> %s\n', numel(i24), n, sum(~same), ...
    verdict(1 + (all(same) && n > 0)));
end
