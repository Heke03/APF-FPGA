# H3 progress: virtual power stage on the DE2-115

Goal: run the APF controller in closed loop **on the DE2-115 board with nothing connected**.
The grid, the diode-bridge load and the inverter are computed inside the FPGA (the "virtual power stage", VPS),
and the switches, LEDs, 7-segment displays and Signal Tap are used to run and watch it.
Decided with the user on 31 Oct 2026; the presentation format is still to be decided by the team.

| Step | What | Status |
|---|---|---|
| 1 | MATLAB/Simulink model of the VPS in fixed point, checked against the Simscape model | **done** |
| 2 | FPGA code for the VPS (+ ADC code converter), bit-exact against the MATLAB model; closed loop with `apf_core` in Questa | in progress |
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

## Notes for whoever continues

- The VPS takes one step every 200 ns (10 clocks at 50 MHz). Every product is rounded with
  `(x + (1 << (s-1))) >>> s`, and every product stays below 2^53, so MATLAB doubles match the FPGA exactly.
- The cosine table is `rtl/cos_table_4096.hex`: 4096 points per turn, peak 65536, stored as 5 hex digits of which the FPGA keeps the low 18 bits.
- Don't start the Cyclone IV install without asking the user (they stopped it once).
- After any MATLAB batch run, check for leftover MATLABWindow processes.
