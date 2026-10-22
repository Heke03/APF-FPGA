function [duty, gates_on, faults, idc_cmd, vdc_target, vdc_avg, ready] = apf_control_block( ...
    vg_ab, il_ab, if_ab, vdc, ref_ab, ref_ok, cos_next, locked, run_request, P)
% Predictive (deadbeat) current control, DC-link loop, protection and start-up
% sequencing: floating-point equivalent of rtl/current_controller.sv and the
% sequencing in rtl/apf_core.sv. Runs once per control frame k.
%   duty     upper-switch on fraction per phase, applied over [k+1, k+2]
%   gates_on inverter switching (and contactor) enable for the same interval
%   faults   latched [measurement, over_current, over_voltage, pll_lost]
persistent raw vg_prev hist wr fill vdc_sum vdc_cnt avg vdc_avg_ok integ idc vtgt fresh run_ctrl fault_q
NMAX = 400;
if isempty(raw)
    raw = [0.5, 0.5, 0.5]; vg_prev = [0, 0];
    hist = zeros(2, NMAX); wr = 1; fill = 0;
    vdc_sum = 0; vdc_cnt = 0; avg = 0; vdc_avg_ok = false;
    integ = 0; idc = 0; vtgt = 0;
    fresh = true; run_ctrl = false; fault_q = false(1, 4);
end
N = P.N; Ts = P.Ts; L = P.Lf;
vg3 = [vg_ab(1), vg_ab(2), -(vg_ab(1) + vg_ab(2))];
il3 = [il_ab(1), il_ab(2), -(il_ab(1) + il_ab(2))];
if3 = [if_ab(1), if_ab(2), -(if_ab(1) + if_ab(2))];

% ---- protection and sequencing (apf_core) ----
fault_now = [any(abs(vg3(1:2)) > P.v_range) || any(abs(il3(1:2)) > P.i_range) || ...
                 any(abs(if3(1:2)) > P.i_range), ...
             any(abs(if3) > P.i_trip), ...
             vdc > P.vdc_trip, ...
             run_ctrl && locked < 0.5];
% The controller sees the run decision registered in an earlier frame.
run_q = run_ctrl && fill == N && ref_ok > 0.5 && vdc_avg_ok;
if run_request < 0.5
    run_ctrl = false;                     % dropping the request clears faults
    fault_q(:) = false;
elseif any(fault_q) || any(fault_now)
    fault_q = fault_q | fault_now;        % latch, stop switching
    run_ctrl = false;
elseif ~run_ctrl && fill == N && vdc_avg_ok && locked > 0.5
    run_ctrl = true;
end
run_q = run_q && run_ctrl;

% ---- 1. predict the filter current at k+1 ----
dv = vg_ab(:)' - vg_prev;
u_prev = vdc * (raw(1:2) - mean(raw));    % differential voltage applied over [k, k+1]
e1 = u_prev - vg_ab(:)' - dv/2;
if fresh                                   % inverter was not switching over [k, k+1]
    i_pred = if_ab(:)';
else
    i_pred = if_ab(:)' + Ts/L * e1;
end
i_pred3 = [i_pred, -(i_pred(1) + i_pred(2))];

% ---- 2. reference for k+2: one grid cycle earlier, minus the DC-link term ----
rd = wr + P.pred_lead;
if rd > N, rd = rd - N; end
rp = hist(:, rd)' - idc * cos_next(1:2);

% ---- 3. deadbeat voltage with grid feed-forward ----
u = vg_ab(:)' + 1.5*dv + P.G * L/Ts * (rp - i_pred);
u3 = [u, -(u(1) + u(2))];

% ---- 4. min/max common-mode injection, divide by Vdc, dead-time compensation ----
off = -(max(u3) + min(u3)) / 2;
vdc_div = max(vdc, P.vdc_min_div);
raw_n = min(max(0.5 + (u3 + off) / vdc_div, 0), 1);
vg_prev = vg_ab(:)';
if run_q
    raw = raw_n;
    duty = min(max(raw_n + P.Td/Ts * (2*(i_pred3 > 0) - 1), 0), 1);
    fresh = false;
else
    raw = [0.5, 0.5, 0.5];
    duty = [0.5, 0.5, 0.5];
    fresh = true;
end
gates_on = double(run_q);

% ---- store this frame's reference; drop the history if it is broken ----
if ref_ok > 0.5
    hist(:, wr) = ref_ab(:);
    wr = wr + 1;
    if wr > N, wr = 1; end
    fill = min(fill + 1, N);
else
    wr = 1; fill = 0;
end

% ---- DC-link PI, once per grid cycle on the cycle average ----
vdc_sum = vdc_sum + vdc;
vdc_cnt = vdc_cnt + 1;
if vdc_cnt == N
    avg = vdc_sum / N;
    vdc_sum = 0; vdc_cnt = 0; vdc_avg_ok = true;
    if ~run_q
        vtgt = avg; integ = 0; idc = 0;
    else
        vtgt = min(vtgt + P.vdc_ramp * N * Ts, P.vdc_ref);
        err = vtgt - avg;
        integ = min(max(integ + P.ki_dc * err * N * Ts, -P.idc_max), P.idc_max);
        idc = min(max(P.kp_dc * err + integ, -P.idc_max), P.idc_max);
    end
end

faults = double(fault_q);
idc_cmd = idc;
vdc_target = vtgt;
vdc_avg = avg;
ready = double(fill == N && vdc_avg_ok && locked > 0.5);
