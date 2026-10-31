function c = vps_adc_codes_H3(vg_q, il_q, if_q, vdc_q)
% H3: the 7 ADC codes apf_core expects, from the virtual power stage state in its
% integer formats (vps_params_H3.m), with the FPGA's rounding. No noise.
%   grid voltage 16 counts/V and currents 100 counts/A, zero at 2048;
%   DC link 10 counts/V. Order: vg_a vg_b il_a il_b if_a if_b vdc.
r = @(x, s) floor((x + 2^(s - 1)) / 2^s);
cl = @(x) min(max(x, 0), 4095);
c = [cl(r(vg_q(1), 8) + 2048), cl(r(vg_q(2), 8) + 2048), ...
     cl(r(il_q(1) * 100, 24) + 2048), cl(r(il_q(2) * 100, 24) + 2048), ...
     cl(r(if_q(1) * 100, 24) + 2048), cl(r(if_q(2) * 100, 24) + 2048), ...
     cl(r(vdc_q * 10, 24))];
end
