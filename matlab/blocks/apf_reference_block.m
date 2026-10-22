function [ref_ab, ref_ok, mean_d] = apf_reference_block(il_ab, cos_k, locked, P)
% Compensation reference, floating-point equivalent of rtl/apf_reference.sv.
%   d      = 2/3 * sum(i_load_p * cos_p)       (active load current, this sample)
%   mean_d = average of d over one grid cycle   (N samples)
%   ref_p  = i_load_p - mean_d * cos_p          (harmonics + reactive current)
% The history is discarded whenever the PLL is not locked.
persistent hist idx cnt total
NMAX = 400;                       % buffer size; P.N must not exceed it
if isempty(hist)
    hist = zeros(1, NMAX); idx = 1; cnt = 0; total = 0;
end
ref_ab = [0, 0];
ref_ok = 0;
mean_d = 0;
if locked < 0.5
    hist(:) = 0; idx = 1; cnt = 0; total = 0;
    return;
end
N = P.N;
il = [il_ab(1), il_ab(2), -(il_ab(1) + il_ab(2))];
d = 2/3 * sum(il .* cos_k);

% Rolling sum over the last N samples.
if cnt == N
    total = total - hist(idx);
end
total = total + d;
hist(idx) = d;
idx = idx + 1;
if idx > N, idx = 1; end
cnt = min(cnt + 1, N);

if cnt == N
    mean_d = total / N;
    ref_ab = il(1:2) - mean_d * cos_k(1:2);
    ref_ok = 1;
end
