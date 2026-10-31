function [thd, valid] = thd_meter_H3(i24)
% H3: the THD meter of the DE2-115 board design, in the same integer math as
% the FPGA (rtl/thd_meter_H3.sv), so both give the same reading bit for bit.
%
%   [thd, valid] = thd_meter_H3(i24)
%
%   i24   grid current of phase a, one sample per controller frame (10 kHz, at
%         the PWM carrier boundary), integers in 2^-24 A (virtual power stage format)
%   thd   THD in 0.01 % (440 = 4.40 %), one reading per 1000 samples (5 grid cycles)
%   valid false when there is no current to measure (fundamental below ~0.1 A)
%
% Same definition as every THD in this project: harmonics 2..40 over the
% fundamental. Each harmonic h is measured with a DFT over the 5 cycles; the
% virtual grid is exactly 50 Hz and a frame is exactly 1/200 of a cycle, so the
% cosine and sine of h * (2*pi*k/200) come from a 200-point table.
N = 1000; M = 200; H = 40;
r = @(x, s) floor((x + 2^(s - 1)) / 2^s);   % rounding shift, as (x + 2^(s-1)) >>> s
[C, S] = thd_table_H3;
MIN_F1 = 2^28;
nw = floor(numel(i24) / N);
thd = zeros(nw, 1);
valid = false(nw, 1);
kk = mod(0:N - 1, M).';                      % frame index within the grid cycle
for w = 1:nw
    is = r(i24((w - 1) * N + (1:N)), 14);    % 2^-10 A
    is = is(:);
    p = zeros(H, 1);
    for h = 1:H
        m = mod(h * kk, M) + 1;
        re = r(sum(is .* C(m)), 16);         % sums < 2^39, then scaled so that
        im = r(sum(is .* S(m)), 16);         % the squares stay under 2^53
        p(h) = re^2 + im^2;
    end
    f1 = p(1);
    hs = sum(p(2:H));
    if f1 < MIN_F1
        continue
    end
    valid(w) = true;
    if hs >= f1                              % THD of 100 % or more
        thd(w) = 9999;
    else
        n = hs; q = 0;                       % q = floor(hs / f1 * 2^24), one bit per step
        for j = 1:24
            n = 2 * n; q = 2 * q;
            if n >= f1, n = n - f1; q = q + 1; end
        end
        thd(w) = min(floor(sqrt(floor(q * 1e8 / 2^24))), 9999);   % 0.01 %
    end
end
end
