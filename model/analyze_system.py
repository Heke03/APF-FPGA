"""Turns sim/out/apf_system.csv (from tb_apf_system) into numbers and figures.

  python model/analyze_system.py [csv]     -> prints THD etc., writes sim/out/*.png
"""
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
CSV = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "sim", "out", "apf_system.csv")
OUT = os.path.dirname(os.path.abspath(CSV))

d = np.genfromtxt(CSV, delimiter=",", names=True)
t = d["t"]
dt = np.median(np.diff(t))


def window(t0, cycles=5):
    n = int(round(cycles * 0.02 / dt))
    k0 = np.searchsorted(t, t0)
    return slice(k0, k0 + n)


def spectrum(x, cycles=5, hmax=40):
    """Harmonic amplitudes 1..hmax from an integer number of cycles."""
    n = len(x)
    f = np.fft.rfft(x) * 2 / n
    return np.abs(f[[h * cycles for h in range(1, hmax + 1)]])


def thd(x, cycles=5):
    a = spectrum(x, cycles)
    return np.sqrt(np.sum(a[1:] ** 2)) / a[0], a


def first(mask):
    idx = np.flatnonzero(mask)
    return t[idx[0]] if len(idx) else float("nan")


print(f"PLL locked at {first(d['locked'] > 0) * 1e3:.1f} ms, "
      f"compensation ready at {first(d['ready'] > 0) * 1e3:.1f} ms, "
      f"switching from {first(d['switching'] > 0) * 1e3:.1f} ms")
if np.any(d["faults"] > 0):
    print(f"FAULT flags seen from {first(d['faults'] > 0) * 1e3:.1f} ms: {int(d['faults'].max())}")

rows = []
for label, t0 in (("33 ohm load", 0.60), ("22 ohm load (after step)", 0.90)):
    w = window(t0)
    thd_l, a_l = thd(d["ila"][w])
    thd_s, a_s = thd(d["isa"][w])
    # Displacement: phase of the source current fundamental relative to the voltage.
    n = len(d["isa"][w]); cyc = 5
    ph_v = np.angle(np.fft.rfft(d["vga"][w])[cyc]); ph_i = np.angle(np.fft.rfft(d["isa"][w])[cyc])
    pf_angle = np.degrees(ph_i - ph_v); pf_angle = (pf_angle + 180) % 360 - 180
    rows.append((label, thd_l, thd_s, a_l[0], a_s[0], pf_angle, a_l, a_s,
                 d["vdc"][w].min(), d["vdc"][w].max()))
    print(f"{label:26s} load THD {thd_l * 100:5.1f} %   grid THD {thd_s * 100:5.1f} %   "
          f"I1 load {a_l[0]:.2f} A, grid {a_s[0]:.2f} A   grid current angle {pf_angle:+.1f} deg   "
          f"Vdc {d['vdc'][w].min():.1f}..{d['vdc'][w].max():.1f} V")
    print("   harmonics % of fundamental  h:  " + "  ".join(f"{h}:{a_l[h-1]/a_l[0]*100:4.1f}->{a_s[h-1]/a_s[0]*100:4.1f}"
                                                             for h in (5, 7, 11, 13, 17, 19)))

# ---- Figure 1: before/after waveforms ----
w = window(0.60, cycles=2)
fig, ax = plt.subplots(3, 1, figsize=(10, 8), sharex=True)
tm = (t[w] - t[w][0]) * 1e3
ax[0].plot(tm, d["vga"][w], color="tab:gray", label="grid voltage a (V)")
ax[0].set_ylabel("V"); ax[0].legend(loc="upper right")
ax[1].plot(tm, d["ila"][w], color="tab:red", label="load current a (what the load draws)")
ax[1].plot(tm, d["ifa"][w], color="tab:green", label="inverter current a (what the APF injects)")
ax[1].set_ylabel("A"); ax[1].legend(loc="upper right")
ax[2].plot(tm, d["isa"][w], color="tab:blue", label="grid current a = load - inverter")
ax[2].set_ylabel("A"); ax[2].set_xlabel("ms"); ax[2].legend(loc="upper right")
fig.suptitle(f"Steady state, 33 ohm load: grid current THD {rows[0][1]*100:.1f} % -> {rows[0][2]*100:.1f} %")
fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig1_waveforms.png"), dpi=120)

# ---- Figure 2: whole run ----
fig, ax = plt.subplots(4, 1, figsize=(10, 9), sharex=True)
ax[0].plot(t, d["isa"], lw=0.4, label="grid current a")
ax[0].plot(t, d["ila"], lw=0.4, alpha=0.6, label="load current a")
ax[0].set_ylabel("A"); ax[0].legend(loc="upper left")
ax[1].plot(t, d["vdc"], color="tab:purple"); ax[1].set_ylabel("Vdc (V)")
ax[2].plot(t, d["freq"], color="tab:orange"); ax[2].set_ylabel("PLL f (Hz)"); ax[2].set_ylim(49, 51)
ax[3].plot(t, d["locked"], label="PLL locked"); ax[3].plot(t, d["ready"] * 0.9, label="ready")
ax[3].plot(t, d["switching"] * 0.8, label="switching"); ax[3].plot(t, (d["faults"] > 0) * 0.7, label="fault")
ax[3].set_ylabel("flags"); ax[3].set_xlabel("time (s)"); ax[3].legend(loc="lower right", ncol=4)
for a in ax:
    a.axvline(0.7, color="k", ls=":", lw=0.8)
fig.suptitle("Start-up: PLL lock -> compensation starts -> DC link 173 V -> 300 V; load step at 0.7 s")
fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig2_startup.png"), dpi=120)

# ---- Figure 3: spectrum ----
fig, ax = plt.subplots(figsize=(10, 4))
h = np.arange(2, 41)
a_l, a_s = rows[0][6], rows[0][7]
ax.bar(h - 0.2, a_l[1:] / a_l[0] * 100, width=0.4, color="tab:red", label="load current")
ax.bar(h + 0.2, a_s[1:] / a_s[0] * 100, width=0.4, color="tab:blue", label="grid current with APF")
ax.set_xlabel("harmonic order"); ax.set_ylabel("% of fundamental"); ax.legend()
ax.set_title("Harmonic content, 33 ohm load")
fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig3_spectrum.png"), dpi=120)

# ---- Figure 4: load step ----
w = slice(np.searchsorted(t, 0.68), np.searchsorted(t, 0.76))
fig, ax = plt.subplots(2, 1, figsize=(10, 6), sharex=True)
ax[0].plot(t[w] * 1e3, d["isa"][w], label="grid current a"); ax[0].plot(t[w] * 1e3, d["ila"][w], alpha=0.6, label="load current a")
ax[0].set_ylabel("A"); ax[0].legend(loc="upper left")
ax[1].plot(t[w] * 1e3, d["vdc"][w], color="tab:purple"); ax[1].set_ylabel("Vdc (V)"); ax[1].set_xlabel("ms")
fig.suptitle("Load step 33 -> 22 ohm at 700 ms")
fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig4_load_step.png"), dpi=120)
print("figures written to", OUT)
