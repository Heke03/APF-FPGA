function y = sensor_chain_block_H2(x, S, Tps)
% H2: sensors and the delay in front of the ADC, run at the power-stage step Tps.
%   x, y   [vg_a vg_b il_a il_b if_a if_b vdc]  (V, A, V); y is what the ADC samples
% Per channel:
%   - first-order sensor lag, time constant S.tau (0 = ideal sensor)
%   - pure delay S.delay before the sample (ADC anti-alias filter group delay,
%     delta-sigma decimation filter, ...)
%   - plus S.conv - ch*S.skew: the ADC block samples at S.conv after the carrier
%     boundary (when the codes reach the FPGA), so this extra delay makes channel ch
%     show its value at boundary + ch*S.skew (multiplexed ADC) or at the boundary
%     itself (simultaneous ADC, skew 0), as in sim/tb_apf_system_H1.sv.
persistent lag buf wr
NBUF = 4096;                            % 2.048 ms at Tps = 0.5 us
if isempty(lag)
    lag = x(:);                         % start settled at the first plant values
    buf = repmat(x(:), 1, NBUF);
    wr = 1;
end
a = 1 - exp(-Tps ./ S.tau(:));          % tau = 0 gives a = 1 (no lag)
lag = lag + a .* (x(:) - lag);
buf(:, wr) = lag;
y = zeros(7, 1);
for ch = 1:7
    n = round((S.delay + S.conv - (ch - 1) * S.skew) / Tps);
    rd = wr - n;
    if rd < 1, rd = rd + NBUF; end
    y(ch) = buf(ch, rd);
end
wr = wr + 1;
if wr > NBUF, wr = 1; end
