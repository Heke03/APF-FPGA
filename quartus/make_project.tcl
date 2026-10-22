project_new apf_reference_check -overwrite
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSEMA5F31C6
set_global_assignment -name TOP_LEVEL_ENTITY apf_reference_guard
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/apf_reference.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/apf_reference_guard.sv
set_global_assignment -name SDC_FILE apf_reference_check.sdc
set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL
project_close
