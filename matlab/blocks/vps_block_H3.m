function [vg_abc, il_abc, if_abc, is_abc, vdc, shoot] = vps_block_H3(gates, contactor, load_step, V)
% H3: virtual power stage, one plant step (H = 200 ns). Equations and number
% formats are specified in vps_params_H3.m; with V.fx = true every operation is
% integer math with the rounding the FPGA uses, so this is the bit-exact
% reference for the FPGA code. With V.fx = false the same equations run with
% exact constants (the real-number reference).
%   gates      [A hi, A lo, B hi, B lo, C hi, C lo] (Universal Bridge order)
%   contactor  inverter connected (the controller's "switching")
%   load_step  0: R1 (33 ohm), 1: R2 (22 ohm)
%   outputs    grid voltage, load current (grid -> load), inverter current
%              (inverter -> grid), grid current (load - inverter), V and A;
%              shoot = number of steps with both switches of a leg on
persistent th vdcq ifq ilq idq nshoot
if isempty(th)
    th = 0; vdcq = V.vdc0_q; ifq = [0 0 0]; ilq = [0 0 0]; idq = 0; nshoot = 0;
end

% ---- grid voltage ----
th = mod(th + V.dth, 2^40);
vg = [0 0 0];
for p = 1:3
    a = mod(th - (p - 1) * V.th120, 2^40);
    vg(p) = rsh(cosine(a, V) * V.Kvm, 16, V.fx);
end

% ---- inverter legs, filter inductors, DC link ----
vdc_v = rsh(vdcq, 12, V.fx);                 % DC link in the voltage format (2^-12 V)
if contactor > 0.5
    vx = [0 0 0];
    for p = 1:3
        hi = gates(2 * p - 1) > 0.5; lo = gates(2 * p) > 0.5;
        if hi && lo, nshoot = nshoot + 1; end
        if hi
            vx(p) = vdc_v;
        elseif lo
            vx(p) = 0;
        elseif ifq(p) > 0                    % dead time: a diode carries the current
            vx(p) = 0;
        else
            vx(p) = vdc_v;
        end
    end
    vn = rsh((vx(1) + vx(2) + vx(3)) * V.K3, 16, V.fx);
    top = 0;
    for p = 1:3
        if vx(p) > 0, top = top + ifq(p); end   % current drawn from the DC link
    end
    for p = 1:2
        dv = vx(p) - vn - vg(p) - rsh(ifq(p) * V.Krf, 28, V.fx);
        ifq(p) = ifq(p) + rsh(dv * V.Kl, 16, V.fx);
    end
    ifq(3) = -(ifq(1) + ifq(2));
    vdcq = vdcq - rsh(top * V.Kc, 24, V.fx) - rsh(vdcq * V.Kleak, 32, V.fx);
else
    for p = 1:6
        if gates(p) > 0.5, nshoot = nshoot + 1; end   % gates must be off
    end
    ifq = [0 0 0];
    vdcq = vdcq - rsh(vdcq * V.Kleak, 32, V.fx);
end

% ---- diode-bridge load ----
imax = 1; imin = 1;
for p = 2:3                                  % first index wins on a tie (deterministic)
    if vg(p) > vg(imax), imax = p; end
    if vg(p) < vg(imin), imin = p; end
end
if load_step > 0.5, R = V.R2; else, R = V.R1; end
idq = idq + rsh((vg(imax) - vg(imin) - rsh(idq * R, 12, V.fx)) * V.Kd, 16, V.fx);
if idq < 0, idq = 0; end
for p = 1:3
    if p == imax
        target = idq;
    elseif p == imin
        target = -idq;
    else
        target = 0;
    end
    ilq(p) = ilq(p) + rsh((target - ilq(p)) * V.Kt, 20, V.fx);
end

vg_abc = vg(:) / 2^12;
il_abc = ilq(:) / 2^24;
if_abc = ifq(:) / 2^24;
is_abc = il_abc - if_abc;
vdc = vdcq / 2^24;
shoot = nshoot;
end


function c = cosine(a, V)
% cos(2*pi*a/2^40) * 2^16: table + linear interpolation (fixed point), exact otherwise
if V.fx
    idx = floor(a / 2^28);                   % top 12 bits
    frac = floor(mod(a, 2^28) / 2^16);       % next 12 bits
    c0 = V.cos_table(idx + 1);
    c1 = V.cos_table(mod(idx + 1, 4096) + 1);
    c = c0 + rsh((c1 - c0) * frac, 12, true);
else
    c = cos(2 * pi * a / 2^40) * 2^16;
end
end


function y = rsh(x, s, fx)
% x / 2^s, rounded half up in fixed point: (x + (1 << (s-1))) >>> s
if fx
    y = floor((x + 2^(s - 1)) / 2^s);
else
    y = x / 2^s;
end
end
