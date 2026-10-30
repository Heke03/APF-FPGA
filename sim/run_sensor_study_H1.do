# H1 sensor / ADC study: the full closed-loop system (real apf_core RTL) with
# different measurement chains. About 5 min per scenario, run one after another.
# From the APF_FPGA folder:  vsim -c -do sim/run_sensor_study_H1.do
# Then in MATLAB:            run matlab/sensor_adc_study_H1.m
#
# Sensor time constants come from datasheet step-response times (tau = t90 / 2.3):
#   LEM LV 25-P voltage transducer   40 us to 90 %   -> 17.4 us
#   LEM LA 25-NP current transducer   1 us to 90 %   -> 0.43 us
#   isolated-amplifier divider       ~1 us (assumed)
# ADC timing (carrier boundary -> codes in the FPGA):
#   AD7606  8 ch simultaneous, 4 us conversion + serial read  -> 8 us
#   LTC2308 8 ch multiplexed, 2 us per channel                -> skew 2 us, 15 us
#   cRIO NI 9215 + digital link to the DE2-115                 -> 35 us (assumed link)
#   cRIO NI 9244/9246 delta-sigma: input delay (40 + 5/512)/fs + 1.7 us at 50 kS/s -> 0.80 ms
# S7..S9, S14, S15 add an extra pure delay to S1 to find how much latency the controller tolerates.
# S10 is the recommended chain with every lag sized for the real parts:
#   LV 25-P: t90 = 40 us is an L/R constant quoted at R1 = 25 kOhm (primary ~0.44 H), so
#            grid channel R1 = 10 kOhm -> tau 42.8 us, DC-link R1 = 30 kOhm -> tau 14.5 us
#   AD7606 +-5 V range: on-chip 2nd-order filter, 15 kHz, group delay 15 us (all channels)
#   AD7606 4 us conversion + serial read of 64 bits at 12.5 MHz -> 10 us
# S11/S12 move S10 to the +-10 V range (same sensors, signals use half the range, 15 bits
# left): AD7606 group delay 11 us, AD7606B phase delay 7.5 us. S13 = S10 with a fast
# (~1 us) grid-voltage sensor instead of the LV 25-P, to isolate the voltage-sensor lag.
# Note: CONV only sets when the codes arrive inside the 100 us frame; the sample instant
# stays at the carrier boundary, so CONV does not degrade control (S1 vs S4 show this).
# The Questa Starter license allows two simulations at once, so this script runs them in series.
file mkdir sim/out/H1
if {![file exists work]} { vlib work }
vlog -sv rtl/srf_pll.sv rtl/apf_reference.sv rtl/current_controller.sv rtl/three_phase_pwm.sv rtl/apf_core.sv sim/tb_apf_system_H1.sv
vopt work.tb_apf_system_H1 -o tb_H1_opt

set lem {+TAU_V=17.4e-6 +TAU_I=0.43e-6 +TAU_DC=17.4e-6}
set scenarios [list \
    S0_ideal          {} \
    S1_LEM_AD7606     "$lem +CONV=8e-6" \
    S2_LEM_LTC2308    "$lem +SKEW=2e-6 +CONV=15e-6" \
    S3_isoamp_AD7606  {+TAU_V=1e-6 +TAU_I=0.43e-6 +TAU_DC=1e-6 +CONV=8e-6} \
    S4_cRIO_NI9215    "$lem +CONV=35e-6" \
    S5_cRIO_NI9244    {+DELAY=802e-6 +CONV=35e-6} \
    S6_LEM_AD7606_noisy "$lem +CONV=8e-6 +NOISE=3" \
    S7_delay100us     "$lem +CONV=8e-6 +DELAY=100e-6" \
    S8_delay200us     "$lem +CONV=8e-6 +DELAY=200e-6" \
    S9_delay400us     "$lem +CONV=8e-6 +DELAY=400e-6" \
    S10_LEM_AD7606_real {+TAU_V=42.8e-6 +TAU_I=0.43e-6 +TAU_DC=14.5e-6 +DELAY=15e-6 +CONV=10e-6} \
    S11_AD7606_10V    {+TAU_V=42.8e-6 +TAU_I=0.43e-6 +TAU_DC=14.5e-6 +DELAY=11e-6 +CONV=10e-6} \
    S12_AD7606B_10V   {+TAU_V=42.8e-6 +TAU_I=0.43e-6 +TAU_DC=14.5e-6 +DELAY=7.5e-6 +CONV=10e-6} \
    S13_fastV_AD7606  {+TAU_V=1e-6 +TAU_I=0.43e-6 +TAU_DC=14.5e-6 +DELAY=15e-6 +CONV=10e-6} \
    S14_delay30us     "$lem +CONV=8e-6 +DELAY=30e-6" \
    S15_delay50us     "$lem +CONV=8e-6 +DELAY=50e-6" ]

foreach {name opts} $scenarios {
    eval vsim -c tb_H1_opt +CSV=sim/out/H1/$name.csv $opts
    run -all
    quit -sim
}
quit -f
