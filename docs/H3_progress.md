# H3 progress: virtual power stage on the DE2-115

Goal: run the APF controller in closed loop **on the DE2-115 board with nothing connected**.
The grid, the diode-bridge load and the inverter are computed inside the FPGA (the "virtual power stage", VPS),
and the switches, LEDs, 7-segment displays and Signal Tap are used to run and watch it.
Decided with the user on 31 Oct 2026; the presentation format is still to be decided by the team.

| Step | What | Status |
|---|---|---|
| 1 | MATLAB/Simulink model of the VPS in fixed point, checked against the Simscape model | **done** |
| 2 | FPGA code for the VPS (+ ADC code converter), bit-exact against the MATLAB model; closed loop with `apf_core` in Questa | **done** |
| 3 | DE2-115 top level: Cyclone IV support in Quartus (**needs the user's OK to install**), pins from Terasic's list, switches/LEDs/7-seg, compile, timing | waiting |
| 4 | Test on the board together with the user (Signal Tap instead of an oscilloscope) | waiting |

## Step 1 result (31 Oct 2026)

Files: `matlab/vps_params_H3.m` (the specification: number formats and integer constants),
`matlab/blocks/vps_block_H3.m` (one plant step, bit-exact reference), `matlab/build_apf_vps_H3.m`
(builds `apf_vps_H3.slx`: the unchanged controller of `apf_system.slx` + the VPS), `matlab/vps_check_H3.m`.

| Plant | Grid THD 33 Ω | Grid THD 22 Ω | Load THD (no APF) |
|---|---|---|---|
| Simscape (`apf_system.slx`) | 4.85 % | 3.59 % | 28.1 % |
| VPS fixed point (= FPGA math) | 4.43 % | 3.50 % | 26.1 % |
| VPS real numbers | 4.44 % | 3.53 % | 26.1 % |

- **Integer math is accurate:** before switching starts, the fixed-point and real-number versions differ by less than 1 mA and 0.4 mV. In closed loop, THD changes by at most 0.03 points.
- **Same as the H1 testbench:** the VPS uses the same equations as `sim/tb_apf_system.sv` and gives the same THD (4.40 / 3.50 %).
- **Known difference from Simscape:** the VPS approximates the diode-bridge commutation with a 0.2 ms lag, while Simscape simulates the 0.5 mH line reactor itself. That gives a squarer load current in Simscape (28 % against 26 % load THD), and that's why Simscape shows about 0.4 points more grid THD. A proper commutation model could be added later if the team wants a closer match.
- **Same startup:** PLL lock at 40 ms and switching from 80 ms in all three; no faults, no shoot-through.
- **Speed:** a 1 s run takes about 70 s in Simulink (5 million plant steps). On the FPGA it runs in real time.

## Step 2 result (31 Oct 2026)

Files:

| File | What it is |
|---|---|
| `rtl/virtual_power_stage_H3.sv` | the plant in FPGA code: one step every 10 clocks, same integers as `vps_block_H3.m` |
| `rtl/vps_adc_H3.sv` | stands in for the ADC: takes the 7 codes at `adc_start`, delivers them 20 us later, optional ~1 count noise |
| `rtl/apf_vps_system_H3.sv` | `apf_core` + VPS + ADC stand-in: everything the board will run; the DE2-115 top level only wraps it |
| `matlab/vps_vectors_H3.m`, `matlab/vps_adc_codes_H3.m` | 40 ms of test inputs (PWM, connect/disconnect, a forced shoot-through, load step, gates off) and the expected outputs from the MATLAB model |
| `sim/tb_vps_H3.sv` | compares the FPGA code with the MATLAB model, every output at every step |
| `sim/tb_apf_vps_H3.sv` | closed loop, 1 s: run request at 10 ms, load step at 0.7 s, ADC noise on |
| `sim/run_vps_H3.do` | runs both testbenches; then `vps_rtl_check_H3` in MATLAB compares the closed loop with Simulink |

**Bit-exact:** 200,000 plant steps (40 ms) with **0 mismatches** on all 21 outputs.
That covers grid voltages, all currents, Vdc, the 7 ADC codes, and the shoot-through counter.

**Closed loop on the FPGA code (Questa):**

1 s, ADC noise on, run request at 10 ms, load step at 0.7 s. The Questa run takes about 9.5 min.

| Plant | Grid THD 33 Ω | Grid THD 22 Ω | Vdc dip at load step | PLL lock | Switching from | Faults |
|---|---|---|---|---|---|---|
| Simscape (`apf_system.slx`) | 4.85 % | 3.59 % | 13.3 V | 39.9 ms | 80.0 ms | none |
| VPS fixed point, Simulink | 4.43 % | 3.50 % | 13.3 V | 39.9 ms | 80.0 ms | none |
| **FPGA code (`apf_core` + VPS), Questa** | **4.40 %** | **3.51 %** | 13.7 V | 40.0 ms | 80.2 ms | **none** |

DC link ends at 301.4 V (target 300 V). Shoot-through steps: 0.

![closed loop on the FPGA code](figures/H3_fpga_closed_loop.png)

- **The FPGA code behaves like the Simulink model.** THD differs by 0.03 points or less, and the load step at 0.7 s is the same.
- **One small timing difference at start-up:** the FPGA run starts switching 0.2 ms later. The DC-link loop in `current_controller.sv` only updates once per grid cycle, and that 0.2 ms seems to miss one update, so the FPGA charges the DC link one cycle (20 ms) later. From 0.4 s on the two curves lie on top of each other.
- The two testbenches (bit-exact and closed loop) were rerun on the final code, after the timing fix.

**Fit and timing** (on Cyclone V 5CSEMA5F31C6, the only Cyclone family installed right now):

| Item | Value |
|---|---|
| Setup slack at 50 MHz | **+2.98 ns** worst |
| Hold slack | +0.11 ns |
| Logic | 2,615 ALMs (8 %) |
| Registers | 2,810 |
| Block memory | 158 kbit (4 %) |
| DSP blocks | 67 / 87 (77 %) |

The first version failed timing by 2 ns: one path did the inverter voltages, the sum of
currents, a multiply and the Vdc update all in one clock. It now spreads them over three
extra clocks of the 10-clock step.

**Things to check in step 3 (Cyclone IV E on the DE2-115):**

- **Clock speed:** the Cyclone IV E is slower than the Cyclone V, so the +2.98 ns may shrink or go negative. If it does, there's room to pipeline more: the plant step has 10 clocks and most of them are short.
- **Multipliers:** the EP4CE115 has 266 18x18 multipliers but no 27x27 blocks, so the wide products will take more of them. It should fit; the compile will tell.

## Notes for whoever continues

- The VPS takes one step every 200 ns (10 clocks at 50 MHz). Every product is rounded with
  `(x + (1 << (s-1))) >>> s`, and every product stays below 2^53, so MATLAB doubles match the FPGA exactly.
- The cosine table is `rtl/cos_table_4096.hex`: 4096 points per turn, peak 65536, stored as 5 hex digits of which the FPGA keeps the low 18 bits.
- Don't start the Cyclone IV install without asking the user (they stopped it once).
- After any MATLAB batch run, check for leftover MATLABWindow processes.
