function [vg_abc, il_abc, if_abc, vdc] = adc_quantizer_block_H2(x, noise, S)
% H2: 12-bit ADC codes exactly as rtl/apf_core.sv receives them, converted back
% to volts and amperes for the floating-point controller.
%   grid voltage 16 counts/V and currents 100 counts/A, zero at code 2048;
%   DC link 10 counts/V, zero at code 0; S.noise counts rms of white noise.
% Phase c is -(a + b), as in apf_core (only phases a and b are measured).
gain = [16 16 100 100 100 100 10]';
offset = [2048 2048 2048 2048 2048 2048 0]';
if S.adc
    c = offset + gain .* x(:) + S.noise * noise(:);
    c = floor(min(max(c, 0), 4095) + 0.5);
    v = (c - offset) ./ gain;
else
    v = x(:);                           % ideal ADC: no quantization or noise
end
vg_abc = [v(1); v(2); -(v(1) + v(2))];
il_abc = [v(3); v(4); -(v(3) + v(4))];
if_abc = [v(5); v(6); -(v(5) + v(6))];
vdc = v(7);
