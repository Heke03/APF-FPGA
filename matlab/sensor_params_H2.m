function S = sensor_params_H2(varargin)
% H2: measurement-chain settings for apf_system_H2.slx (block "Sensors + ADC").
% With no arguments: ideal sensors, 12-bit ADC with 1 count rms noise, all
% channels sampled at the PWM carrier boundary.
%
%   S = sensor_params_H2('tauV', 17.4e-6, 'tauI', 0.43e-6, 'tauDC', 17.4e-6, 'conv', 8e-6)
%
%   tauV, tauI, tauDC  sensor first-order time constants (grid voltage, currents, DC link), s
%   delay              pure delay before the sample (ADC filter, delta-sigma), s
%   skew               multiplexed ADC: channel ch is sampled ch*skew after the boundary, s
%   conv               when the codes reach the FPGA after the boundary, s (< Ts)
%   noise              ADC noise, counts rms
%   seed               noise seed
%   adc                false = ideal ADC (no quantization, no noise)
p = inputParser;
addParameter(p, 'tauV', 0);
addParameter(p, 'tauI', 0);
addParameter(p, 'tauDC', 0);
addParameter(p, 'delay', 0);
addParameter(p, 'skew', 0);
addParameter(p, 'conv', 0);
addParameter(p, 'noise', 1);
addParameter(p, 'seed', 12345);
addParameter(p, 'adc', true);
parse(p, varargin{:});
o = p.Results;

Ts = 1e-4; Tps = 0.5e-6;                % must match apf_params.m
if o.conv >= Ts
    error('sensor_params_H2:conv', 'conv must be shorter than the 100 us control frame.');
end
if o.skew > 0 && 6 * o.skew > o.conv
    error('sensor_params_H2:skew', 'conv must cover all 7 channels: conv >= 6*skew.');
end
if o.delay + o.conv > 4095 * Tps
    error('sensor_params_H2:delay', 'delay + conv is limited to 2.04 ms (buffer in sensor_chain_block_H2).');
end
if abs(o.conv / Tps - round(o.conv / Tps)) > 1e-9
    error('sensor_params_H2:grid', 'conv must be a multiple of the 0.5 us power-stage step.');
end
S = struct('tau', [o.tauV o.tauV o.tauI o.tauI o.tauI o.tauI o.tauDC], ...
    'delay', o.delay, 'skew', o.skew, 'conv', o.conv, 'noise', o.noise, ...
    'seed', o.seed, 'adc', logical(o.adc));
end
