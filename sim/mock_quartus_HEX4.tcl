# HEX4: a stand-in for the board, so quartus/read_capture_HEX4.tcl can be tested with
# nothing plugged in. It replaces the Quartus memory commands with procs that follow
# the rules in the Quartus help (word at the highest address first, hex digits,
# {index depth width mode type name} lists), serves a recording from a folder, and
# then runs the real read script unchanged, inside the real quartus_stp.
#
#   quartus_stp -t mock_quartus_HEX4.tcl <read script> <scenario> <recording> <out folder> [status]
#
# It only tests the logic of the script. It cannot prove the real cable or the real
# memories work; only the board can.
lassign $quartus(args) script scenario src out mode
expr {srand([expr {[info exists ::env(MOCK_SEED)] ? $::env(MOCK_SEED) : 12345}])}

proc load_mem {file} {
    set fd [open $file r]; set words [split [string trim [read $fd]] "\n"]; close $fd
    return [lmap w $words {string trim $w}]
}
foreach n {IG IL II VD VG} { set ::mem($n) [load_mem [file join $src $n.txt]] }
set ::mem(INF) [load_mem [file join $src INF.txt]]
set ::names {IG IL II VD VG INF}
set ::info_reads 0

proc get_hardware_names {} {
    if {$::scenario eq "no_cable"} { error "No hardware available" }
    if {$::scenario eq "other_cable"} { return {"Some-Other-Cable [USB-1]"} }
    return {"USB-Blaster [USB-0]"}
}
proc get_device_names {args} {
    if {$::scenario eq "wrong_device"} { return {"@1: EP2C35 (0x020B40DD)"} }
    return {"@1: EP3C120/EP4CE115 (0x020F70DD)"}
}
proc begin_memory_edit {args} {
    if {$::scenario eq "cable_busy"} { error "JTAG server is busy" }
    if {![string match "*EP4CE115*" $args]} { error "wrong device passed" }
}
proc end_memory_edit {} {
    if {$::scenario eq "must_release_cable"} { puts "CABLE RELEASED" }
}
proc get_editable_mem_instances {args} {
    if {$::scenario eq "no_design"} { return {} }
    set r {}
    set i 0
    foreach n $::names {
        set d [llength $::mem($n)]
        set w [expr {$n eq "INF" ? 32 : 16}]
        if {$::scenario eq "memory_missing" && $n eq "VG"} { incr i; continue }
        if {$::scenario eq "wrong_size" && $n eq "VD"} { set d 1024 }
        lappend r [list $i $d $w RW ROM/RAM $n]
        incr i
    }
    return $r
}
proc read_content_from_memory {args} {
    set hex [expr {"-content_in_hex" in $args}]
    if {!$hex} { error "the mock only serves hex" }
    array set a [lsearch -all -inline -not -exact $args -content_in_hex]
    set n [lindex $::names $a(-instance_index)]
    if {$::scenario eq "read_throws" && $n eq "VD"} { error "JTAG communication error" }
    set words [lrange $::mem($n) $a(-start_address) [expr {$a(-start_address) + $a(-word_count) - 1}]]
    if {$n eq "INF"} {
        incr ::info_reads
        # the board is hit by a collision with its own writes: a word comes back with wrong bits
        if {$::scenario in {collisions must_release_cable}} {
            set words [lmap w $words {
                if {rand() < 0.125} { format %08X [expr {[scan $w %x] ^ (1 << int(rand() * 32))}] } else { set w }
            }]
        }
        if {$::scenario eq "never_agrees"} { lset words 3 [format %08X [expr {int(rand() * 65536)}]] }
        if {$::scenario eq "wrong_design"} { lset words 0 DEADBEEF }
        if {$::scenario eq "key1_during_read" && $::info_reads > 3} { lset words 1 [format %08X [expr {[scan [lindex $words 1] %x] & ~7 | 4}]] }
        if {$::scenario eq "recording"} {
            lset words 1 [format %08X [expr {[scan [lindex $words 1] %x] & ~7 | 4}]]
            lset words 2 [format %08X [expr {$::info_reads * 7}]]                ;# the write address moves
        }
    }
    if {$::scenario eq "short_answer" && $n eq "IL"} { return [string range [join [lreverse $words] ""] 1 end] }
    # the WRONG word order, to prove the test notices it
    if {$::scenario eq "low_address_first"} { return [join $words ""] }
    # lower-case hex is allowed by the help
    return [string tolower [join [lreverse $words] ""]]
}

set quartus(args) [list $out $mode]
source $script
