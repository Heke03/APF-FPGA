function out = thd_vectors_H3
% H3: the table and test vectors for the bit-exact check of rtl/thd_meter_H3.sv.
% Writes
%   rtl/thd_table_200.hex          the meter's cos/sin table (thd_table_H3), one
%                                  34-bit word {cos, sin} per line, 17-bit two's complement each
%   sim/out/H3/thd_samples.txt     one grid-current sample per line, 2^-24 A
%   sim/out/H3/thd_expected.txt    one reading per 1000 samples: thd valid (thd_meter_H3)
% sim/tb_thd_meter_H3.sv feeds the samples to the FPGA code and compares every reading.
%
%   >> thd_vectors_H3
%   >> out = thd_vectors_H3;   % also returns the windows: name, THD, valid
%
% One 1000-sample window per test signal (10 kHz, 5 cycles of 50 Hz):
% clean and distorted currents like the APF's, the smallest current that still
% reads, too little current (no reading), THD over 100 %, 30 A, noise with a DC
% offset, and a harmonic above 40 (not counted).
here = fileparts(mfilename('fullpath'));
[C, S] = thd_table_H3;
fid = fopen(fullfile(here, '..', 'rtl', 'thd_table_200.hex'), 'w');
fprintf(fid, '%09X\n', mod(C, 2^17) * 2^17 + mod(S, 2^17));
fclose(fid);

rng(7);
k = (0:999).'; th = 2 * pi * 50 * k / 1e4;
cases = {   % name, fundamental (A peak), [harmonic amplitude(A) phase(rad)], noise (A rms), offset (A)
    'pure sine',            5.5,  [],                                                    0,    0
    'APF on (~4 %)',        5.5,  [5 0.17 0.4; 7 0.05 -1; 11 0.10 2; 13 0.07 0.5],      0,    0
    'APF off (~26 %)',      5.5,  [5 1.12 0.3; 7 0.66 -0.5; 11 0.40 1; 13 0.31 2; 17 0.21 0; 19 0.18 1], 0, 0
    '22 ohm (~2 %)',        8.2,  [5 0.09 0.4; 7 0.08 -1; 11 0.11 2; 13 0.10 0.5],      0,    0
    'small current 0.3 A',  0.3,  [5 0.03 0],                                            0,    0
    'too small 0.02 A',     0.02, [5 0.002 0],                                           0,    0
    'zero',                 0,    [],                                                    0,    0
    'THD over 100 %',       1,    [3 1.5 0; 5 0.8 1],                                    0,    0
    '30 A',                 30,   [5 6 0.2; 7 4 1.1; 11 2 -0.7],                         0,    0
    'negative 30 A',        -30,  [5 3 2],                                               0,    0
    'noise and offset',     3,    [2 0.2 0.5; 40 0.1 1],                                 0.5,  1.5
    'h = 45 only',          5,    [45 0.5 0],                                            0,    0
    'all harmonics 2..40',  4,    [(2:40).' 0.2 ./ (2:40).' (1:39).' * 0.3],             0,    0
    'phase shifted',        5.5,  [5 1.12 2.9; 7 0.66 0.1],                              0.02, 0};
n = size(cases, 1);
i24 = zeros(1000 * n, 1);
for c = 1:n
    H = cases{c, 3};
    i = cases{c, 2} * cos(th + 2 * pi * rand) + cases{c, 4} * randn(1000, 1) + cases{c, 5};
    for h = 1:size(H, 1), i = i + H(h, 2) * cos(H(h, 1) * th + H(h, 3)); end
    i24((c - 1) * 1000 + (1:1000)) = round(i * 2^24);
end
[thd, valid] = thd_meter_H3(i24);
out = table(string(cases(:, 1)), thd / 100, valid, 'VariableNames', {'signal', 'thd_pct', 'valid'});
disp(out)

odir = fullfile(here, '..', 'sim', 'out', 'H3');
if ~exist(odir, 'dir'), mkdir(odir); end
fid = fopen(fullfile(odir, 'thd_samples.txt'), 'w');
fprintf(fid, '%d\n', i24);
fclose(fid);
fid = fopen(fullfile(odir, 'thd_expected.txt'), 'w');
fprintf(fid, '%d %d\n', [thd valid].');
fclose(fid);
fprintf('Wrote rtl/thd_table_200.hex, %d samples and %d readings to %s\n', numel(i24), n, odir);
end
