# HEX4: a whole pretend board session, for matlab/board_flow_check_HEX4.m. Keeps a small
# state file between the many quartus_stp calls of run_board_HEX4: which recording the
# board is on and whether it has stopped. The "user" flips the next switch and presses
# KEY1 by itself after a couple of status polls. It then runs the real read script
# through mock_quartus_HEX4.tcl.
#
#   quartus_stp -t fake_board_HEX4.tcl <read script> <folder> [status]
lassign $quartus(args) script out mode
set here [file dirname [info script]]
set scenario $::env(FAKE_SCENARIO)
set state_file $::env(FAKE_STATE)

# rec: which recording (0 = the one started by a switch left up at load); phase: armed / stopped
set rec 1; set phase armed; set polls 0; set was_read 0
if {[file exists $state_file]} {
    set fd [open $state_file r]; lassign [read $fd] rec phase polls was_read; close $fd
} elseif {$scenario eq "switch_up_at_load"} {
    set rec 0; set phase stopped
}

proc rec_folder {r} {
    if {[info exists ::env(FAKE_SRC_$r)]} { return $::env(FAKE_SRC_$r) }
    return [file join $::env(FAKE_EXPECTED) [lindex {rec1_sw0_up rec1_sw0_up rec2_sw1_up rec3_sw0_down} $r]]
}

# what the pretend user does between two polls
if {$mode eq "status"} {
    incr polls
    if {$phase eq "armed" && $polls >= 2 && $scenario ne "never_flip"} {
        set phase stopped; set polls 0; set was_read 0
    } elseif {$phase eq "stopped" && ($was_read || $rec == 0) && $polls >= 2 && $scenario ne "no_key1"} {
        set phase armed; set polls 0; incr rec
    }
}
set use [expr {$phase eq "stopped" ? "ok" : "recording"}]
if {$scenario eq "cable_lost" && $mode ne "status" && $rec == 2} { set use no_cable }
if {$scenario eq "key1_during_read" && $mode ne "status"} { set use key1_during_read }
if {$mode ne "status"} { set was_read 1 }
set fd [open $state_file w]; puts $fd [list $rec $phase $polls $was_read]; close $fd

set quartus(args) [list $script $use [rec_folder [expr {max($rec, 1)}]] $out $mode]
source [file join $here mock_quartus_HEX4.tcl]
