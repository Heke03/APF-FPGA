# HEX4: the tests of the real-hardware design. From the APF_FPGA folder:
#   vsim -c -do "set which fast; do sim/run_hw_HEX4.do"     driver and guard, with the broken copies (~3 min)
#   vsim -c -do "set which safety; do sim/run_hw_HEX4.do"   staged faults on the running inverter (~6 min)
#   vsim -c -do "set which loop; do sim/run_hw_HEX4.do"     1 s closed loop (~16 min); then hw_chain_check_HEX4 in MATLAB
#   vsim -c -do "set which chain; do sim/run_hw_HEX4.do"    30 ms of the loop test, good and with wrong values on purpose (~2 min)
# Each uses its own library, but this Questa license allows only one simulation at a time.
if {![info exists which]} { set which fast }
file mkdir sim/out/HEX4
set lib work_hex4_$which
if {![file exists $lib]} { vlib $lib }
set common {rtl/srf_pll.sv rtl/apf_reference.sv rtl/current_controller.sv rtl/three_phase_pwm.sv rtl/apf_core.sv
            rtl/virtual_power_stage_H3.sv rtl/thd_meter_H3.sv rtl/display_H3.sv rtl/capture_H3.sv
            rtl/ad7606_if_HEX4.sv rtl/adc_scale_HEX4.sv rtl/gate_guard_HEX4.sv rtl/de2_115_hw_top_HEX4.sv
            sim/ad7606_model_HEX4.sv sim/tb_ad7606_if_HEX4.sv sim/tb_gate_guard_HEX4.sv sim/tb_hw_loop_HEX4.sv}

if {$which eq "fast"} {
    vlog -work $lib -sv {*}$common
    # -onfinish stop: otherwise the first $finish closes the simulator and the rest never runs
    vsim -c -onfinish stop -lib $lib -wlf sim/out/HEX4/fast1.wlf tb_ad7606_if_HEX4
    run -all
    quit -sim
    vsim -c -onfinish stop -lib $lib -wlf sim/out/HEX4/fast2.wlf tb_gate_guard_HEX4
    run -all
    quit -sim
    # the guard with each rule removed on purpose: the test must fail on every copy
    set fd [open rtl/gate_guard_HEX4.sv r]; set src [read $fd]; close $fd
    set mutants {
        no_shoot_through_check  {if (hi_in[k] && lo_in[k]) now[0] = 1'b1;}                            {}
        no_dead_time_check      {if (hi_in[k] && !hi_prev[k] && (lo_prev[k] || lo_off[k] != MIN_DEAD_CLKS)) now[1] = 1'b1;} {}
        runs_without_arming     {assign running = armed && arm && !trip_any;}                         {assign running = !trip_any;}
        disarm_acts_late        {assign running = armed && arm && !trip_any;}                         {assign running = armed && !trip_any;}
        trip_does_not_stay      {if (now != 0) begin tripped <= 1'b1; cause <= cause | now; end}      {tripped <= (now != 0); cause <= cause | now;}
        ignores_driver_fault    {now[2] = !drivers_ok;}                                               {now[2] = 1'b0;}
        buffer_stays_enabled    {gate_en_n <= !running;}                                              {gate_en_n <= 1'b0;}
    }
    foreach {name from to} $mutants {
        set changed [string map [list $from $to] $src]
        if {$changed eq $src} { echo "MUTANT $name: pattern not found, test script is out of date"; continue }
        set f sim/out/HEX4/mut_$name.sv
        set fd [open $f w]; puts $fd $changed; close $fd
        set mlib work_hex4_mut
        if {![file exists $mlib]} { vlib $mlib }
        vlog -quiet -work $mlib -sv $f sim/tb_gate_guard_HEX4.sv
        echo "MUTANT $name"
        vsim -c -onfinish stop -lib $mlib -wlf sim/out/HEX4/mut.wlf tb_gate_guard_HEX4
        run -all
        quit -sim
    }
    quit -f
}

vlog -work $lib -sv {*}$common
vopt -work $lib -L altera_mf_ver tb_hw_loop_HEX4 -o hw_opt
if {$which eq "chain"} {
    # the good design first, then copies that deliver wrong values: the test must fail on every copy
    vsim -c -onfinish stop -lib $lib -L altera_mf_ver -wlf sim/out/HEX4/chain.wlf +MODE=loop +STOP_MS=30 +CSV=sim/out/HEX4/chain.csv hw_opt
    run -all
    quit -sim
    set mutants {
        scale_gain_wrong          rtl/adc_scale_HEX4.sv  {18'sd12941}                  {18'sd12900}
        driver_channels_shifted   rtl/ad7606_if_HEX4.sv  {raw[chan] <= $signed(ad_db);} {raw[3'(chan + 1)] <= $signed(ad_db);}
    }
    foreach {name file from to} $mutants {
        vlog -quiet -work $lib -sv {*}$common
        set fd [open $file r]; set src [read $fd]; close $fd
        set changed [string map [list $from $to] $src]
        if {$changed eq $src} { echo "MUTANT $name: pattern not found, test script is out of date"; continue }
        set f sim/out/HEX4/mut_$name.sv
        set fd [open $f w]; puts $fd $changed; close $fd
        vlog -quiet -work $lib -sv $f
        vopt -quiet -work $lib -L altera_mf_ver tb_hw_loop_HEX4 -o hw_opt_$name
        echo "MUTANT $name"
        vsim -c -onfinish stop -lib $lib -L altera_mf_ver -wlf sim/out/HEX4/chain.wlf +MODE=loop +STOP_MS=30 +CSV=sim/out/HEX4/chain.csv hw_opt_$name
        run -all
        quit -sim
    }
    quit -f
}
if {$which eq "loop"} {
    vsim -c -lib $lib -L altera_mf_ver -wlf sim/out/HEX4/loop.wlf -l sim/out/HEX4/hw_loop.log +MODE=loop hw_opt
} else {
    vsim -c -lib $lib -L altera_mf_ver -wlf sim/out/HEX4/safety.wlf -l sim/out/HEX4/hw_safety.log +MODE=safety hw_opt
}
run -all
quit -sim
quit -f
