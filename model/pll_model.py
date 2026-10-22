"""Bit-accurate integer model of rtl/srf_pll.sv (three-phase synchronous-reference-frame PLL).

The RTL must reproduce these integer operations exactly; sim/tb_srf_pll.sv replays
vectors written by this script. Run:  python pll_model.py  (writes ../sim/pll_vectors.txt
and ../rtl/cos_table_4096.hex, then prints the scenario report).
"""
import math
import os
import random

FS = 10_000            # control sample rate, Hz (one ADC frame per 100 us)
F_NOM = 50.0           # nominal grid frequency, Hz
PHASE_BITS = 32        # phase accumulator: 2^32 = one full turn
LUT_BITS = 12          # 4096-entry cosine table
Q = 16                 # trig values and normalized error are Q16 (65536 = 1.0)

TURN = 1 << PHASE_BITS
NOM_WORD = (TURN * 50) // FS                     # 21,474,836
OFF_120 = round(TURN / 3)                        # 1,431,655,765
OFF_90 = TURN // 4
ADDR_SHIFT = PHASE_BITS - LUT_BITS               # 20
ADDR_ROUND = 1 << (ADDR_SHIFT - 1)               # round to nearest table entry

# Loop design: continuous-time PI on normalized error sin(e) (rad):
#   omega_n = 2*pi*20 Hz, zeta = 0.707  ->  Kp = 2*zeta*omega_n, Ki = omega_n^2
BW_HZ = 20.0
ZETA = 0.707
WN = 2 * math.pi * BW_HZ
KP_CT = 2 * ZETA * WN
KI_CT = WN * WN
WORD_PER_RAD = TURN / (2 * math.pi)
# Proportional: phase-word increment per Q16 error count.
KP = round(KP_CT / FS * WORD_PER_RAD / (1 << Q))                 # 185
# Integral: added each sample to an accumulator kept with 8 extra fraction bits.
KI_FRAC = 8
KI = round(KI_CT / FS / FS * WORD_PER_RAD / (1 << Q) * (1 << KI_FRAC))   # 422

F_MIN, F_MAX = 45.0, 55.0
FREQ_MIN = math.floor(TURN * F_MIN / FS)
FREQ_MAX = math.ceil(TURN * F_MAX / FS)
INTEG_MAX = ((FREQ_MAX - NOM_WORD) << KI_FRAC)                   # anti-windup bound

LOCK_E = round(math.sin(math.radians(2.0)) * (1 << Q))            # |error| <= 2 deg to count as locked
UNLOCK_E = round(math.sin(math.radians(15.0)) * (1 << Q))         # |error| > 15 deg counts against lock
LOCK_N = 400                                                      # 2 grid cycles of good samples
UNLOCK_N = 50                                                     # 5 ms of bad samples
SCALE_SHIFT = 8


def cos_table():
    t = []
    for k in range(1 << LUT_BITS):
        v = round(math.cos(2 * math.pi * k / (1 << LUT_BITS)) * (1 << Q))
        t.append(max(-(1 << Q), min(1 << Q, v)))
    return t


TABLE = cos_table()


def lut(phase):
    return TABLE[((phase + ADDR_ROUND) % TURN) >> ADDR_SHIFT]


def isqrt(n):
    return math.isqrt(n)


def trunc_div(n, d):
    q = abs(n) // d
    return q if n >= 0 else -q


class Pll:
    def __init__(self, mag_min):
        self.mag_min = mag_min
        self.reset()

    def reset(self):
        self.theta = 0
        self.integ = 0
        self.locked = False
        self.lock_cnt = 0
        self.unlock_cnt = 0
        self.freq = NOM_WORD
        self.trig = self._trig(self.theta)

    @staticmethod
    def _trig(theta):
        c = (lut(theta), lut(theta - OFF_120), lut(theta + OFF_120))
        s = (lut(theta - OFF_90), lut(theta - OFF_120 - OFF_90), lut(theta + OFF_120 - OFF_90))
        return c, s

    def step(self, va, vb, vc, valid=True):
        """Process one voltage frame. Returns the outputs published after this frame.
        An invalid frame (measurement fault) drops lock at once; the angle keeps
        free-running at the last frequency with the integrator held."""
        c, s = self.trig
        vd_raw = va * c[0] + vb * c[1] + vc * c[2]
        vq_raw = -(va * s[0] + vb * s[1] + vc * s[2])
        vd_s = vd_raw >> SCALE_SHIFT
        vq_s = vq_raw >> SCALE_SHIFT
        mag = isqrt(vd_s * vd_s + vq_s * vq_s)
        low_amp = (not valid) or mag == 0 or mag < self.mag_min
        err = 0 if low_amp else trunc_div(vq_s << Q, mag)

        self.integ = max(-INTEG_MAX, min(INTEG_MAX, self.integ + KI * err))
        freq = NOM_WORD + KP * err + (self.integ >> KI_FRAC)
        self.freq = max(FREQ_MIN, min(FREQ_MAX, freq))
        self.theta = (self.theta + self.freq) % TURN
        self.trig = self._trig(self.theta)

        good = (not low_amp) and abs(err) <= LOCK_E
        bad = low_amp or abs(err) > UNLOCK_E
        if not valid:
            self.locked, self.lock_cnt, self.unlock_cnt = False, 0, 0
        elif not self.locked:
            self.lock_cnt = self.lock_cnt + 1 if good else 0
            if self.lock_cnt >= LOCK_N:
                self.locked, self.unlock_cnt = True, 0
        else:
            self.unlock_cnt = self.unlock_cnt + 1 if bad else 0
            if self.unlock_cnt >= UNLOCK_N:
                self.locked, self.lock_cnt = False, 0
        return dict(err=err, mag=mag, low_amp=low_amp, freq=self.freq, theta=self.theta,
                    locked=self.locked, cos=self.trig[0])


def wrap_deg(x):
    return (x + 180.0) % 360.0 - 180.0


def run(scenario, n, seed=0, collect=None):
    """scenario(k) -> (amplitude, freq_hz, phase_offset_rad, harmonics list[(order, rel_amp, seq)], valid)"""
    rnd = random.Random(seed)
    amp_counts = 1600
    pll = Pll(mag_min=MAG_MIN)
    theta_true = rnd.uniform(0, 2 * math.pi)
    log = []
    for k in range(n):
        amp, f, jump, harm, valid, noise = scenario(k)
        th = theta_true + jump
        v = []
        for p in range(3):
            shift = -2 * math.pi * p / 3
            x = amp * math.cos(th + shift)
            for order, rel, seq in harm:
                hs = shift * order if seq == 0 else (shift * order)  # natural sequence of order h
                x += amp * rel * math.cos(order * th + hs)
            x += rnd.gauss(0, noise)
            v.append(max(-32768, min(32767, round(x))))
        # angle the PLL used for this sample (predicted before seeing it)
        est = pll.theta * 2 * math.pi / TURN
        out = pll.step(*v, valid=valid)
        err_deg = wrap_deg(math.degrees(th - est))
        log.append((k, err_deg, out["freq"] * FS / TURN, out["locked"], v, valid))
        if collect is not None:
            collect.append((v, valid, out))
        theta_true += 2 * math.pi * f / FS
    return log


AMP = 1600                                   # example nominal amplitude in ADC counts
MAG_MIN = (AMP * 3 // 2 * 256) // 4          # lock requires > 25 % of nominal amplitude (mag = 1.5*V*256)


def summarize(name, log, settle_from, lock_by=None):
    errs = [abs(e) for (k, e, f, l, v, ok) in log[settle_from:] if ok]
    lock_k = next((k for (k, e, f, l, v, ok) in log if l), None)
    print(f"{name:44s} lock at {('%.1f ms' % (lock_k / 10)) if lock_k is not None else 'never':>9s}"
          f"   max |phase err| after {settle_from / 10:.0f} ms: {max(errs):6.3f} deg"
          f"   final f = {log[-1][2]:.3f} Hz   locked at end: {log[-1][3]}")
    return lock_k, max(errs)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    print(f"KP={KP} KI={KI} (frac {KI_FRAC}) NOM={NOM_WORD} FREQ=[{FREQ_MIN},{FREQ_MAX}] "
          f"INTEG_MAX={INTEG_MAX} LOCK_E={LOCK_E} UNLOCK_E={UNLOCK_E} MAG_MIN={MAG_MIN}")

    clean = lambda k: (AMP, 50.0, 0.0, [], True, 0.0)
    summarize("1. 50 Hz clean, random start phase", run(clean, 3000, seed=1), 1500)
    for seed in range(2, 12):
        lk, mx = summarize(f"   start-phase seed {seed}", run(clean, 3000, seed=seed), 1500)
    summarize("2. 52 Hz grid (off-nominal)", run(lambda k: (AMP, 52.0, 0.0, [], True, 0.0), 3000, 3), 1500)
    summarize("3. 47 Hz grid (off-nominal)", run(lambda k: (AMP, 47.0, 0.0, [], True, 0.0), 3000, 4), 1500)
    summarize("4. 50 -> 51 Hz step at 150 ms", run(lambda k: (AMP, 50.0 if k < 1500 else 51.0, 0.0, [], True, 0.0), 4000, 5), 2500)
    summarize("5. 30 deg phase jump at 150 ms", run(lambda k: (AMP, 50.0, 0.0 if k < 1500 else math.radians(30), [], True, 0.0), 4000, 6), 2500)
    summarize("6. half amplitude", run(lambda k: (AMP // 2, 50.0, 0.0, [], True, 0.0), 3000, 7), 1500)
    summarize("7. 5th (5 %, neg. seq) + 7th (3 %) harmonics",
              run(lambda k: (AMP, 50.0, 0.0, [(5, 0.05, 0), (7, 0.03, 0)], True, 0.0), 3000, 8), 1500)
    summarize("8. ADC-like noise (sigma 8 counts)", run(lambda k: (AMP, 50.0, 0.0, [], True, 8.0), 3000, 9), 1500)
    lg = run(lambda k: (AMP if not (1500 <= k < 1800) else 0, 50.0, 0.0, [], True, 0.0), 5000, 10)
    summarize("9. voltage lost 150-180 ms, then returns", lg, 4000)
    unlocked = [k for (k, e, f, l, v, ok) in lg if 1500 <= k < 1800 and not l]
    print(f"   unlocked during outage after {(unlocked[0] - 1500) / 10 if unlocked else 'never'} ms")

    # Vector file for the RTL testbench: scenario mix with exact expected integer outputs.
    vectors = []
    def mixed(k):
        f = 50.0 if k < 3000 else 51.0
        jump = 0.0 if k < 5000 else math.radians(30)
        amp = AMP if not (7000 <= k < 7300) else 0
        valid = not (8500 <= k < 8510)
        return amp, f, jump, [(5, 0.05, 0), (7, 0.03, 0)], valid, 6.0
    run(mixed, 11000, seed=42, collect=vectors)
    with open(os.path.join(here, "..", "sim", "pll_vectors.txt"), "w") as fh:
        fh.write("# va vb vc valid | err mag low_amp freq theta locked cos_a cos_b cos_c\n")
        for v, valid, o in vectors:
            fh.write(f"{v[0]} {v[1]} {v[2]} {int(valid)} {o['err']} {o['mag']} {int(o['low_amp'])} "
                     f"{o['freq']} {o['theta']} {int(o['locked'])} {o['cos'][0]} {o['cos'][1]} {o['cos'][2]}\n")
    with open(os.path.join(here, "..", "rtl", "cos_table_4096.hex"), "w") as fh:
        for v in TABLE:
            fh.write(f"{v & 0xFFFFF:05x}\n")      # 20-bit two's complement, 5 hex digits
    print(f"wrote {len(vectors)} vectors and the 4096-entry cosine table")


if __name__ == "__main__":
    main()
