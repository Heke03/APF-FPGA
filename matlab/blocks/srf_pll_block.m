function [cos_k, cos_next, freq, locked, err_deg, amp] = srf_pll_block(vg_ab, P)
% Three-phase SRF-PLL, floating-point equivalent of rtl/srf_pll.sv
% (bit-exact integer model: model/pll_model.py). Runs once per control frame.
%   cos_k    cosines of the angle predicted for this sample (used by the reference)
%   cos_next cosines for the next sample (used by the current controller)
persistent theta integ is_locked lock_cnt unlock_cnt
if isempty(theta)
    theta = 0; integ = 0; is_locked = false; lock_cnt = 0; unlock_cnt = 0;
end
sh = [0, -2*pi/3, 2*pi/3];
vabc = [vg_ab(1), vg_ab(2), -(vg_ab(1) + vg_ab(2))];

% 1. Park transform with the predicted angle.
c = cos(theta + sh);
s = sin(theta + sh);
vd = 2/3 * sum(vabc .* c);
vq = -2/3 * sum(vabc .* s);

% 2. Normalise q by the magnitude: error = sin(phase error).
amp = sqrt(vd^2 + vq^2);
low_amp = amp < P.pll_vmin;
e = 0;
if ~low_amp
    e = vq / amp;
end

% 3. PI loop with frequency clamp and anti-windup.
wn = 2*pi*P.pll_bw;
kp = 2*P.pll_zeta*wn;
ki = wn^2;
imax = 2*pi*(P.pll_fmax - P.f);
integ = min(max(integ + ki*e*P.Ts, -imax), imax);
w = min(max(2*pi*P.f + kp*e + integ, 2*pi*P.pll_fmin), 2*pi*P.pll_fmax);

% 4. Advance the angle for the next sample.
theta = mod(theta + w*P.Ts, 2*pi);

% 5. Lock detection.
good = ~low_amp && abs(e) <= sin(P.lock_deg*pi/180);
bad  = low_amp || abs(e) > sin(P.unlock_deg*pi/180);
if ~is_locked
    if good, lock_cnt = lock_cnt + 1; else, lock_cnt = 0; end
    if lock_cnt >= P.lock_n
        is_locked = true; unlock_cnt = 0;
    end
else
    if bad, unlock_cnt = unlock_cnt + 1; else, unlock_cnt = 0; end
    if unlock_cnt >= P.unlock_n
        is_locked = false; lock_cnt = 0;
    end
end

cos_k = c;
cos_next = cos(theta + sh);
freq = w / (2*pi);
locked = double(is_locked);
err_deg = asin(e) * 180/pi;
