# H3: checks of the DE2-115 board design (Questa).
# From the APF_FPGA folder, after running matlab/thd_vectors_H3.m once:
#   vsim -c -do sim/run_board_H3.do
# 1. THD meter bit-exact against the MATLAB version (~1 min)
# 2. displays: every reading in every format (~1 min)
# 3. the board top level with the demo sequence on the switches, 1.13 s (~12 min)
# Then in MATLAB: board_check_H3 (the board's THD readings, bit-exact)
file mkdir sim/out/H3
if {![file exists work]} { vlib work }
vlog -sv rtl/srf_pll.sv rtl/apf_reference.sv rtl/current_controller.sv rtl/three_phase_pwm.sv rtl/apf_core.sv \
    rtl/virtual_power_stage_H3.sv rtl/vps_adc_H3.sv rtl/thd_meter_H3.sv rtl/apf_vps_system_H3.sv \
    rtl/display_H3.sv rtl/de2_115_top_H3.sv sim/tb_thd_meter_H3.sv sim/tb_display_H3.sv sim/tb_de2_115_H3.sv
vsim -c work.tb_thd_meter_H3
run -all
quit -sim
vsim -c work.tb_display_H3
run -all
quit -sim
vopt work.tb_de2_115_H3 -o tb_de2_115_H3_opt
vsim -c tb_de2_115_H3_opt
run -all
quit -sim
quit -f
