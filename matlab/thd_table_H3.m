function [C, S] = thd_table_H3
% H3: the 200-point cosine and sine table of the THD meter (one grid cycle),
% scaled by 2^15. The FPGA reads the same values from rtl/thd_table_200.hex.
m = (0:199).';
C = round(2^15 * cos(2 * pi * m / 200));
S = round(2^15 * sin(2 * pi * m / 200));
end
