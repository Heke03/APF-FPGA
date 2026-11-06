# HEX4: the exact board design with the sequence of the guided board test (about 50 min).
# From the APF_FPGA folder:
#   vsim -c -do sim/run_board_sequence_HEX4.do
# Uses its own library, so other simulations can be compiled while it runs.
file mkdir sim/out/HEX4 sim/out/HEX4/rec1_sw0_up sim/out/HEX4/rec2_sw1_up sim/out/HEX4/rec3_sw0_down
if {![file exists work_hex4_seq]} { vlib work_hex4_seq }
vlog -work work_hex4_seq -sv rtl/srf_pll.sv rtl/apf_reference.sv rtl/current_controller.sv rtl/three_phase_pwm.sv rtl/apf_core.sv \
    rtl/virtual_power_stage_H3.sv rtl/vps_adc_H3.sv rtl/thd_meter_H3.sv rtl/apf_vps_system_H3.sv \
    rtl/display_H3.sv rtl/capture_H3.sv rtl/de2_115_top_H3.sv sim/tb_board_sequence_HEX4.sv
vopt -work work_hex4_seq -L altera_mf_ver tb_board_sequence_HEX4 -o seq_opt
vsim -c -lib work_hex4_seq -L altera_mf_ver -wlf sim/out/HEX4/seq.wlf -l sim/out/HEX4/sequence.log seq_opt
run -all
quit -sim
quit -f
