# HEX4: the 40-pin header (JP5) of the DE2-115, for de2_115_hw_top_HEX4.
# FPGA pins: Terasic DE2-115 User Manual, Figure 4-15, and three independent project
# files, which agree on 36 of 36 GPIO pins and on all 106 pins of de2_115_pins_H3.tcl.
# Header pin = the pin number on JP5 (see docs/HEX4_progress.md for the wiring table).
# I/O voltage: 3.3 V, the default of jumper JP6 (pins 7-8). Check it before wiring.
#                              signal              FPGA      GPIO    header pin
set hw_pins {
    ADC_DB[0]       PIN_AB22
    ADC_DB[1]       PIN_AC15
    ADC_DB[2]       PIN_AB21
    ADC_DB[3]       PIN_Y17
    ADC_DB[4]       PIN_AC21
    ADC_DB[5]       PIN_Y16
    ADC_DB[6]       PIN_AD21
    ADC_DB[7]       PIN_AE16
    ADC_DB[8]       PIN_AD15
    ADC_DB[9]       PIN_AE15
    ADC_DB[10]      PIN_AC19
    ADC_DB[11]      PIN_AF16
    ADC_DB[12]      PIN_AD19
    ADC_DB[13]      PIN_AF15
    ADC_DB[14]      PIN_AF24
    ADC_DB[15]      PIN_AE21
    ADC_CONVST      PIN_AF25
    ADC_RD_N        PIN_AC22
    ADC_CS_N        PIN_AE22
    ADC_BUSY        PIN_AF21
    ADC_FRSTDATA    PIN_AF22
    ADC_RESET       PIN_AD22
    ADC_RANGE       PIN_AG25
    ADC_OS[0]       PIN_AD25
    ADC_OS[1]       PIN_AH25
    ADC_OS[2]       PIN_AE25
    GATE_EN_N       PIN_AG22
    GATE_A_HI       PIN_AE24
    GATE_A_LO       PIN_AH22
    GATE_B_HI       PIN_AF26
    GATE_B_LO       PIN_AE20
    GATE_C_HI       PIN_AG23
    GATE_C_LO       PIN_AF20
    DRIVERS_OK      PIN_AH26
    CONTACTOR       PIN_AH23
}
foreach {signal pin} $hw_pins {
    set_location_assignment $pin -to $signal
    set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to $signal
}
