# H3: checks of the virtual power stage FPGA code (Questa).
# From the APF_FPGA folder, after running matlab/vps_vectors_H3.m once:
#   vsim -c -do sim/run_vps_H3.do
# 1. bit-exact check against the MATLAB fixed-point model (~1 min)
# 2. the board design in closed loop: apf_core + virtual power stage, 1 s (~10 min)
# Then in MATLAB: vps_rtl_check_H3
file mkdir sim/out/H3
if {![file exists work]} { vlib work }
vlog -sv rtl/srf_pll.sv rtl/apf_reference.sv rtl/current_controller.sv rtl/three_phase_pwm.sv rtl/apf_core.sv \
    rtl/virtual_power_stage_H3.sv rtl/vps_adc_H3.sv sim/tb_vps_H3.sv sim/tb_apf_vps_H3.sv
vsim -c work.tb_vps_H3 +VEC=sim/out/H3/vps_vectors.txt
run -all
quit -sim
vopt work.tb_apf_vps_H3 -o tb_apf_vps_H3_opt
vsim -c tb_apf_vps_H3_opt +CSV=sim/out/H3/apf_vps.csv
run -all
quit -sim
quit -f
