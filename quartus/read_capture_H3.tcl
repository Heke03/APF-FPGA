# H3: reads the waveform recording (rtl/capture_H3.sv) from the DE2-115 over the
# USB-Blaster cable while the design runs, with the In-System Memory Content Editor.
# Writes one file per memory into the output folder: INF.txt (8 status words) and
# IG/IL/II/VD/VG.txt (the 5 channels), one hex word per line in address order.
#
#   quartus_stp -t read_capture_H3.tcl <output folder>
# (MATLAB's board_capture does this for you.)
catch {load_package jtag}
set outdir [lindex $quartus(args) 0]
if {$outdir eq ""} { set outdir capture }
file mkdir $outdir

# the board's USB-Blaster and the FPGA on it
set hw ""
if {[catch {get_hardware_names} hws]} { set hws {} }      ;# throws when no cable is plugged in
foreach h $hws { if {[string match "*USB-Blaster*" $h]} { set hw $h; break } }
if {$hw eq ""} {
    puts "ERROR: no USB-Blaster found. Is the board on, and the USB cable in the BLASTER port?"
    exit 1
}
set dev ""
foreach d [get_device_names -hardware_name $hw] { if {[string match "*EP4CE115*" $d]} { set dev $d; break } }
if {$dev eq ""} {
    puts "ERROR: $hw does not see the DE2-115 FPGA (EP4CE115)."
    exit 1
}
begin_memory_edit -hardware_name $hw -device_name $dev
set found {}
foreach inst [get_editable_mem_instances -hardware_name $hw -device_name $dev] {
    # {index depth width mode type name}
    dict set found [lindex $inst 5] [list [lindex $inst 0] [lindex $inst 1] [lindex $inst 2]]
}
foreach name {INF IG IL II VD VG} {
    if {![dict exists $found $name]} {
        end_memory_edit
        puts "ERROR: the board has no memory $name. Is de2_115_top_H3.sof (with the recorder) loaded?"
        exit 1
    }
    lassign [dict get $found $name] idx depth width
    set digits [expr {($width + 3) / 4}]
    set fd [open [file join $outdir $name.txt] w]
    set chunk 2048
    for {set a 0} {$a < $depth} {incr a $chunk} {
        set n [expr {min($chunk, $depth - $a)}]
        # the string holds the word at the highest address first
        set s [read_content_from_memory -instance_index $idx -start_address $a -word_count $n -content_in_hex -timeout 60000]
        for {set i [expr {$n - 1}]} {$i >= 0} {incr i -1} {
            puts $fd [string range $s [expr {$i * $digits}] [expr {($i + 1) * $digits - 1}]]
        }
    }
    close $fd
    puts "read $name: $depth words of $width bits"
}
end_memory_edit
puts "OK: recording saved in $outdir"
