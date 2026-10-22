# Batch: records 1 s of the whole-system simulation to sim/out/apf_system.wlf (about 5 min).
# From the APF_FPGA folder:  vsim -c -do sim/record_system.do
# View it: File > Open... > sim/out/apf_system.wlf, then Tools > Tcl > Execute Macro... > sim/wave_system.do
file mkdir sim/out
if {![file exists work]} { vlib work }
vlog -sv rtl/srf_pll.sv rtl/apf_reference.sv rtl/current_controller.sv rtl/three_phase_pwm.sv rtl/apf_core.sv sim/tb_apf_system.sv
vsim -voptargs=+acc -onfinish stop -wlf sim/out/apf_system.wlf work.tb_apf_system +CSV=sim/out/apf_system.csv
# Only the signals shown by sim/wave_system.do, to keep the file small.
log /tb_apf_system/grid_voltage_a /tb_apf_system/load_current_a /tb_apf_system/inverter_current_a
log /tb_apf_system/grid_current_a /tb_apf_system/dc_link_voltage /tb_apf_system/pll_frequency /tb_apf_system/run_request
log /tb_apf_system/gate_hi /tb_apf_system/gate_lo
log /tb_apf_system/dut/pll_locked /tb_apf_system/dut/compensating_ready /tb_apf_system/dut/switching
log /tb_apf_system/dut/fault_flags /tb_apf_system/dut/ctrl/duty_a /tb_apf_system/dut/idc_cmd
run -all
quit -sim
quit -f
