# HEX4: reads the waveform recording (rtl/capture_H3.sv) from the DE2-115 over the
# USB-Blaster cable while the design runs, with the In-System Memory Content Editor.
#
#   quartus_stp -t read_capture_HEX4.tcl <folder>          whole recording, into <folder>
#   quartus_stp -t read_capture_HEX4.tcl <folder> status   only prints the STATUS line
#
# Whole recording: INF.txt (8 status words) and IG/IL/II/VD/VG.txt (the 5 channels),
# one hex word per line in address order. Prints STATUS, WARN, ERROR and OK lines
# for MATLAB (run_board_HEX4).
#
# What changed from read_capture_H3.tcl:
# - The design rewrites its status memory INF all the time, one word per clock. The
#   JTAG side runs on another clock, and Intel leaves a read of a word in the same
#   moment it is written undefined, so one read of INF can come back wrong. A wrong
#   trigger address would shift the plots without any error. Now every word of INF
#   is voted on over several reads (read_info).
# - INF is read again after the channels. If it changed (somebody pressed KEY1), the
#   channels may be a mix, so the read fails instead of saving them.
# - Every Quartus error becomes one ERROR line, and the cable is always released.
set CONSENSUS 3
set MAX_TRIES 40
set MAGIC A9F00003

proc fail {msg} {
    catch {end_memory_edit}
    puts "ERROR: $msg"
    exit 1
}

# one read of a memory: a list of hex words in address order
proc read_words {idx depth width} {
    set digits [expr {($width + 3) / 4}]
    set words {}
    set chunk 2048
    for {set a 0} {$a < $depth} {incr a $chunk} {
        set n [expr {min($chunk, $depth - $a)}]
        # the string holds the word at the highest address first (Quartus help, write_content_to_memory)
        set s [read_content_from_memory -instance_index $idx -start_address $a -word_count $n -content_in_hex -timeout 60000]
        if {[string length $s] != $n * $digits} {
            fail "memory $idx: asked for $n words, got [string length $s] hex digits instead of [expr {$n * $digits}]"
        }
        for {set i [expr {$n - 1}]} {$i >= 0} {incr i -1} {
            lappend words [string toupper [string range $s [expr {$i * $digits}] [expr {($i + 1) * $digits - 1}]]]
        }
    }
    return $words
}

# INF: every word is voted on separately over several reads, so a collision that spoils
# one word of one read costs nothing. A word is decided when one value has CONSENSUS
# votes and more votes than any other. While the board is recording its write address
# keeps moving, so then only the magic number and the status word have to be decided.
proc read_info {idx} {
    global CONSENSUS MAX_TRIES MAGIC
    for {set i 0} {$i < 8} {incr i} { set votes($i) [dict create] }
    for {set t 0} {$t < $MAX_TRIES} {incr t} {
        set w [read_words $idx 8 32]
        set tops {}; set decided {}
        for {set i 0} {$i < 8} {incr i} {
            dict incr votes($i) [lindex $w $i]
            set ranked [lsort -integer -decreasing -stride 2 -index 1 $votes($i)]
            lappend tops [lindex $ranked 0]
            set first [lindex $ranked 1]
            set second [expr {[llength $ranked] > 2 ? [lindex $ranked 3] : 0}]
            lappend decided [expr {$first >= $CONSENSUS && $first > $second}]
        }
        if {!([lindex $decided 0] && [lindex $decided 1]) || [lindex $tops 0] ne $MAGIC} { continue }
        scan [lindex $tops 1] %x status
        if {!($status & 1)} { return [concat [lrange $tops 0 1] [lrange $w 2 7]] }   ;# recording
        if {0 ni $decided} { return $tops }                                          ;# stopped: nothing moves
    }
    fail "the status memory INF never read the same $CONSENSUS times ($MAX_TRIES tries). Is de2_115_top_H3.sof (with the recorder) loaded?"
}

proc print_status {w} {
    scan [lindex $w 1] %x st
    puts "STATUS ready=[expr {$st & 1}] triggered=[expr {($st >> 1) & 1}] recording=[expr {($st >> 2) & 1}] depth=[expr {1 << (($st >> 8) & 255)}]"
}

set outdir [lindex $quartus(args) 0]
set mode   [lindex $quartus(args) 1]
if {$outdir eq ""} { set outdir capture }

# the board's USB-Blaster and the FPGA on it
set hw ""
if {[catch {get_hardware_names} hws]} { set hws {} }      ;# throws when no cable is plugged in
foreach h $hws { if {[string match "*USB-Blaster*" $h]} { set hw $h; break } }
if {$hw eq ""} { fail "no USB-Blaster found. Is the board on, and the USB cable in the BLASTER port?" }
set dev ""
if {[catch {get_device_names -hardware_name $hw} devs]} { fail "$hw does not answer: $devs" }
foreach d $devs { if {[string match "*EP4CE115*" $d]} { set dev $d; break } }
if {$dev eq ""} { fail "$hw does not see the DE2-115 FPGA (EP4CE115). It sees: $devs" }

if {[catch {begin_memory_edit -hardware_name $hw -device_name $dev} msg]} {
    fail "cannot start reading ($msg). Close the Quartus Programmer or any other window using the cable, and try again."
}
if {[catch {
    set found {}
    foreach inst [get_editable_mem_instances -hardware_name $hw -device_name $dev] {
        # {index depth width mode type name}
        dict set found [lindex $inst 5] [list [lindex $inst 0] [lindex $inst 1] [lindex $inst 2]]
    }
    foreach name {INF IG IL II VD VG} {
        if {![dict exists $found $name]} {
            fail "the board has no memory $name. Is de2_115_top_H3.sof (with the recorder) loaded?"
        }
    }
    lassign [dict get $found INF] idx depth width
    if {$depth != 8 || $width != 32} { fail "memory INF is $depth x $width bits, expected 8 x 32" }
    set before [read_info $idx]
    print_status $before
    if {$mode eq "status"} {
        end_memory_edit
        puts "OK: status read"
        exit 0
    }

    scan [lindex $before 1] %x st
    set need [expr {1 << (($st >> 8) & 255)}]
    set stopped [expr {$st & 1}]
    if {!$stopped} { puts "WARN: the board is still recording (LEDG8 off), so this read may mix old and new samples" }
    file mkdir $outdir
    foreach name {IG IL II VD VG} {
        lassign [dict get $found $name] idx2 depth width
        if {$depth != $need || $width != 16} { fail "memory $name is $depth x $width bits, expected $need x 16" }
        set words [read_words $idx2 $depth $width]
        set fd [open [file join $outdir $name.txt] w]
        puts $fd [join $words "\n"]
        close $fd
        puts "read $name: $depth words of $width bits"
    }
    set after [read_info $idx]
    if {$stopped && $after ne $before} {
        foreach name {IG IL II VD VG} { catch {file delete [file join $outdir $name.txt]} }
        fail "the recording changed while it was being read (KEY1 pressed, or a reset?). Nothing was saved. Run again."
    }
    # save the INF read before the channels: it describes them
    set fd [open [file join $outdir INF.txt] w]
    puts $fd [join $before "\n"]
    close $fd
    end_memory_edit
} msg]} {
    fail "reading failed: $msg"
}
puts "OK: recording saved in $outdir"
