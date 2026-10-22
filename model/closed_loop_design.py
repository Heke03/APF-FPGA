"""Floating-point design study for the APF current controller and DC-link loop.

Average-value plant (no switching ripple), 2 us integration step, 10 kHz control.
Used to choose the control structure and gains before writing the RTL; the
switching-level check with the real RTL is sim/tb_apf_system.sv.
Run:  python closed_loop_design.py
"""
import math

# ---- Assumed power stage (teammates' real values go here) -------------------
VM = 100.0          # grid phase voltage peak, V  (122 V line-line rms)
F = 50.0
LF, RF = 3e-3, 0.1  # filter inductor per phase
CDC = 1000e-6       # DC-link capacitor
RLEAK = 20e3        # DC-link bleed resistor
VDC0 = math.sqrt(3) * VM      # precharge through the inverter diodes
VDC_REF = 300.0
RLOAD, LDC = 33.0, 20e-3      # diode-bridge load, DC side
TAU_COMM = 0.2e-3             # stands in for commutation overlap of the bridge
TS = 1e-4
TD = 2e-6                     # PWM dead time
H = 2e-6
N = 200                       # samples per grid cycle


def thd(x, fs, f0=50.0, hmax=40):
    n = len(x)
    def mag(h):
        w = 2 * math.pi * f0 * h / fs
        re = sum(x[k] * math.cos(w * k) for k in range(n))
        im = sum(x[k] * math.sin(w * k) for k in range(n))
        return 2 * math.hypot(re, im) / n
    m1 = mag(1)
    return math.sqrt(sum(mag(h) ** 2 for h in range(2, hmax + 1))) / m1, m1


def run(G=1.0, dt_comp=True, kp_dc=0.1, ki_dc=1.0, avg_len=200, l_err=1.0, t_end=0.8,
        t_enable=0.05, ramp=500.0, ref_predict="cycle", block_dc=True, u_from_raw=True):
    lf_true = LF * l_err
    # plant state
    i_f = [0.0, 0.0, 0.0]; vdc = VDC0; idc = 0.0; il = [0.0, 0.0, 0.0]
    duty = [0.5, 0.5, 0.5]; enabled = False
    # controller state
    hist = []                       # compensation reference history (a, b)
    vg_prev = [0.0, 0.0, 0.0]
    d_hist = []
    vdc_hist = []
    integ = 0.0
    idc_cmd = 0.0
    raw = [0.5, 0.5, 0.5]
    vref = VDC0
    log = []
    steps = int(TS / H)
    t = 0.0
    for k in range(int(t_end / TS)):
        th = 2 * math.pi * F * t
        vg = [VM * math.cos(th - 2 * math.pi * p / 3) for p in range(3)]
        cosv = [math.cos(th - 2 * math.pi * p / 3) for p in range(3)]
        # ----- measurements at sample k -----
        i_meas = list(i_f); il_meas = list(il); vdc_meas = vdc
        # ----- controller -----
        d = (2 / 3) * sum(il_meas[p] * cosv[p] for p in range(3))
        d_hist.append(d); d_hist[:] = d_hist[-N:]
        mean_d = sum(d_hist) / len(d_hist)
        vdc_hist.append(vdc_meas); vdc_hist[:] = vdc_hist[-avg_len:]
        vdc_avg = sum(vdc_hist) / len(vdc_hist)
        new_duty = [0.5, 0.5, 0.5]
        if t >= t_enable:
            if not enabled:
                enabled = True
                vref = vdc_avg
            if not block_dc:
                vref = min(VDC_REF, vref + ramp * TS)
                e = vref - vdc_avg
                integ = max(-10, min(10, integ + ki_dc * e * TS))
                idc_cmd = max(-10, min(10, kp_dc * e + integ))
            elif k % N == 0:
                # Once per grid cycle, on the average of the last cycle.
                vref = min(VDC_REF, vref + ramp * TS * N)
                e = vref - vdc_avg
                integ = max(-10, min(10, integ + ki_dc * e * TS * N))
                idc_cmd = max(-10, min(10, kp_dc * e + integ))
            # History holds only the load-dependent part; the slow DC-link term is
            # added fresh each sample so it does not go through a one-cycle delay.
            ref = [il_meas[p] - mean_d * cosv[p] for p in range(3)]
            cos_next = [math.cos(th + 2 * math.pi * F * TS - 2 * math.pi * p / 3) for p in range(3)]
            hist.append(ref); hist[:] = hist[-N:]
            if ref_predict == "cycle" and len(hist) == N:
                rp = [hist[2][p] - idc_cmd * cos_next[p] for p in range(3)]   # one cycle before k+2
            elif ref_predict == "none":
                rp = [ref[p] - idc_cmd * cosv[p] for p in range(3)]
            else:
                rp = None
            # applied differential voltage over [k, k+1]
            src = raw if u_from_raw else duty
            vx = [(src[p] - 0.5) * vdc_meas for p in range(3)]
            vn = sum(vx) / 3
            u_prev = [vx[p] - vn for p in range(3)]
            dv = [vg[p] - vg_prev[p] for p in range(3)]
            i_pred = [i_meas[p] + TS / LF * (u_prev[p] - (vg[p] + 0.5 * dv[p])) for p in range(3)]
            if rp is not None:
                u = [vg[p] + 1.5 * dv[p] + G * LF / TS * (rp[p] - i_pred[p]) for p in range(3)]
                off = -(max(u) + min(u)) / 2
                for p in range(3):
                    x = 0.5 + (u[p] + off) / vdc_meas
                    raw[p] = min(1.0, max(0.0, x))
                    if dt_comp:
                        x += (TD / TS) * (1 if i_pred[p] > 0 else -1)
                    new_duty[p] = min(1.0, max(0.0, x))
            else:
                new_duty = [0.5 + 0.0 for _ in range(3)]
        vg_prev = vg
        # one-sample delay: computed duty applies from k+1
        applied = duty
        duty = new_duty if enabled else [0.5, 0.5, 0.5]
        # ----- plant over [k, k+1] with the previously computed duty -----
        on = enabled
        for s in range(steps):
            th = 2 * math.pi * F * t
            vg_t = [VM * math.cos(th - 2 * math.pi * p / 3) for p in range(3)]
            if on:
                vx = []
                for p in range(3):
                    v = applied[p] * vdc
                    v -= (TD / TS) * vdc * (1 if i_f[p] > 0 else -1)
                    vx.append(v)
                vn = sum(vx) / 3 - sum(vg_t) / 3
                di = [(vx[p] - vn - vg_t[p] - RF * i_f[p]) / lf_true for p in range(3)]
                i_f = [i_f[p] + H * di[p] for p in range(3)]
                i_f[2] = -i_f[0] - i_f[1]
                p_in = sum(applied[p] * i_f[p] for p in range(3))   # dc current drawn = sum(d*i)
                vdc += H * (-p_in - vdc / RLEAK) / CDC
            # load: six-pulse bridge with commutation smoothing
            vmax, vmin = max(vg_t), min(vg_t)
            idc += H * (vmax - vmin - RLOAD * idc) / LDC
            idc = max(idc, 0.0)
            target = [idc if vg_t[p] == vmax else (-idc if vg_t[p] == vmin else 0.0) for p in range(3)]
            il = [il[p] + H * (target[p] - il[p]) / TAU_COMM for p in range(3)]
            t += H
        i_s = [il_meas[p] - i_meas[p] for p in range(3)]
        log.append((k, i_s[0], il_meas[0], i_meas[0], vdc_meas, applied[0]))
    return log


def report(name, log, t_from=0.6):
    k0 = int(t_from / TS)
    seg = [r for r in log if k0 <= r[0] < k0 + N]
    thd_s, m_s = thd([r[1] for r in seg], 1 / TS)
    thd_l, m_l = thd([r[2] for r in seg], 1 / TS)
    vdc = [r[4] for r in log[k0:]]
    sat = sum(1 for r in log[k0:] if r[5] in (0.0, 1.0))
    print(f"{name:38s} load THD {thd_l*100:5.1f}%  source THD {thd_s*100:5.1f}%  "
          f"Is1 {m_s:5.2f} A  Vdc {min(vdc):6.1f}..{max(vdc):6.1f}  sat {sat}")


if __name__ == "__main__":
    report("deadbeat G=1, cycle prediction", run())
    report("deadbeat G=0.7", run(G=0.7))
    report("no reference prediction", run(ref_predict="none"))
    report("no dead-time compensation", run(dt_comp=False))
    report("L actual +30 %", run(l_err=1.3))
    report("L actual -30 %", run(l_err=0.7))
    report("L actual -30 %, G=0.7", run(l_err=0.7, G=0.7))
