# Creates the Questa project for THIS computer (APF_FPGA.mpf) and compiles everything.
# Run once after copying the folder anywhere; Questa writes this PC's paths into the .mpf,
# so the .mpf itself is not shared.
#   In Questa:  File > Change Directory... > the APF_FPGA folder, then  do sim/make_project.do
#   or batch:   vsim -c -do "do sim/make_project.do; quit -f"     (from the APF_FPGA folder)
if {[file exists APF_FPGA.mpf]} { project close; file delete APF_FPGA.mpf }
project new . APF_FPGA work
foreach f {
    rtl/srf_pll.sv rtl/apf_reference.sv rtl/apf_reference_guard.sv rtl/current_controller.sv
    rtl/three_phase_pwm.sv rtl/measurement_frontend.sv rtl/apf_core.sv
    sim/tb_apf_system.sv sim/tb_srf_pll.sv sim/tb_apf_reference.sv sim/tb_reference_parameters.sv
    sim/tb_reference_guard.sv sim/tb_reference_demo.sv sim/tb_three_phase_pwm.sv
    sim/tb_measurement_frontend.sv sim/tb_measurement_parameters.sv
} { project addfile $f SystemVerilog }
project compileall
