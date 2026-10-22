# Wave layout for the recorded system run (sim/out/apf_system.wlf).
# In Questa: File > Open... > sim/out/apf_system.wlf, then Tools > Tcl > Execute Macro... > this file.
set d apf_system:/tb_apf_system
view wave

add wave -divider "GRID VOLTAGE"
add wave -format analog-step -height 90 -min -110 -max 110 -color gray   $d/grid_voltage_a
add wave -divider "CURRENTS (A): load = distorted, inverter = APF, grid = result"
add wave -format analog-step -height 90 -min -12 -max 12 -color red      $d/load_current_a
add wave -format analog-step -height 90 -min -12 -max 12 -color green    $d/inverter_current_a
add wave -format analog-step -height 90 -min -12 -max 12 -color cyan     $d/grid_current_a
add wave -divider "DC LINK (V)"
add wave -format analog-step -height 90 -min 150 -max 320 -color violet  $d/dc_link_voltage
add wave -divider "PLL"
add wave -format analog-step -height 70 -min 49.5 -max 50.5 -color orange $d/pll_frequency
add wave $d/dut/pll_locked
add wave -divider "CONTROL STATE"
add wave $d/run_request
add wave $d/dut/compensating_ready
add wave $d/dut/switching
add wave $d/dut/fault_flags
add wave -format analog-step -height 70 -min 0 -max 2500 -color yellow $d/dut/ctrl/duty_a
add wave -format analog-step -height 70 -min -8000 -max 8000 -color pink $d/dut/idc_cmd
add wave -divider "GATES (zoom to ~200 us to see PWM and dead time)"
add wave $d/gate_hi
add wave $d/gate_lo

configure wave -signalnamewidth 1
configure wave -namecolwidth 200
wave zoom full
