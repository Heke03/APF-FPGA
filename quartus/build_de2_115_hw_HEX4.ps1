# HEX4: builds de2_115_hw_top_HEX4.sof, the real-hardware design, and checks it:
# resources, timing at 50 MHz, and exactly which pins it drives.
#
# DO NOT load this file on a board wired to a power stage before the checks in
# docs/HEX4_progress.md are done. Building it drives nothing.
#
# From the APF_FPGA folder:
#   .\quartus\build_de2_115_hw_HEX4.ps1
param(
    [string] $QuartusBin = ''
)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
if (-not $QuartusBin) {
    if ($env:QUARTUS_ROOTDIR) { $QuartusBin = Join-Path $env:QUARTUS_ROOTDIR 'bin64' }
    elseif (Test-Path 'C:\altera_lite\25.1std\quartus\bin64') { $QuartusBin = 'C:\altera_lite\25.1std\quartus\bin64' }
    else { throw 'Quartus not found: install Quartus Prime Lite or pass -QuartusBin <folder with quartus_sh.exe>' }
}
$top = 'de2_115_hw_top_HEX4'
$dir = Join-Path $PSScriptRoot 'de2_115_hw_HEX4'
New-Item -ItemType Directory -Force $dir | Out-Null
function Abs($f) { (Resolve-Path (Join-Path $root $f)).Path -replace '\\', '/' }

$files = 'srf_pll', 'apf_reference', 'current_controller', 'three_phase_pwm', 'apf_core',
         'thd_meter_H3', 'display_H3', 'capture_H3', 'ad7606_if_HEX4', 'adc_scale_HEX4', 'gate_guard_HEX4', $top
$lines = @(
    "project_new $top -overwrite",
    'set_global_assignment -name FAMILY "Cyclone IV E"',
    'set_global_assignment -name DEVICE EP4CE115F29C7',
    "set_global_assignment -name TOP_LEVEL_ENTITY $top",
    "set_global_assignment -name SDC_FILE $top.sdc",
    'set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL',
    'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files',
    'set_global_assignment -name STRATIX_DEVICE_IO_STANDARD "3.3-V LVTTL"',
    'set_global_assignment -name RESERVE_ALL_UNUSED_PINS_WEAK_PULLUP "AS INPUT TRI-STATED"'
)
foreach ($f in $files) { $lines += "set_global_assignment -name SYSTEMVERILOG_FILE $(Abs "rtl/$f.sv")" }
$lines += "set_parameter -name COS_FILE `"$(Abs 'rtl/cos_table_4096.hex')`""
$lines += "set_parameter -name THD_TABLE_FILE `"$(Abs 'rtl/thd_table_200.hex')`""
$lines += "source $(Abs 'quartus/de2_115_pins_H3.tcl')"
$lines += "source $(Abs 'quartus/de2_115_hw_pins_HEX4.tcl')"
$lines += 'project_close'
$lines | Set-Content (Join-Path $dir 'make_project.tcl') -Encoding ascii
@(
    'create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]',
    'derive_clock_uncertainty',
    '# buttons, switches, BUSY and DRIVERS_OK go through synchronizers; LEDs and displays are for the eye',
    'set_false_path -from [get_ports {KEY[*] SW[*] ADC_BUSY DRIVERS_OK}]',
    'set_false_path -to [get_ports {LEDG[*] LEDR[*] HEX*}]',
    '# ADC data: read 60 ns after RD falls, valid at most 24 ns after it (data sheet t14), and it stays',
    '# until the next RD falls. That window is set by the state machine, not by one clock period.',
    'set_false_path -from [get_ports {ADC_DB[*] ADC_FRSTDATA}]',
    '# outputs to the ADC and the gate drivers: every limit is many clocks long and checked in simulation.',
    '# Quartus still reports the delay of these pins in the skew check below.',
    'set_false_path -to [get_ports {ADC_CONVST ADC_RD_N ADC_CS_N ADC_RESET ADC_RANGE ADC_OS[*] GATE_* CONTACTOR}]'
) | Set-Content (Join-Path $dir "$top.sdc") -Encoding ascii

Push-Location $dir
try {
    & "$QuartusBin\quartus_sh.exe" -t make_project.tcl | Out-Null
    foreach ($tool in 'quartus_map', 'quartus_fit', 'quartus_asm', 'quartus_sta') {
        $out = & "$QuartusBin\$tool.exe" $top 2>&1
        $out | Select-String 'Error \(|was successful|Can''t open|initialization file|uninferred' |
            ForEach-Object { "[$tool] " + $_.Line.Trim() }
        if ($LASTEXITCODE -ne 0) { throw "$tool failed" }
    }
    Get-Content "output_files\$top.fit.summary" | Select-String 'logic elements|Total registers|Total pins|memory bits|Multiplier'
    $sta = Get-Content "output_files\$top.sta.summary"
    for ($i = 0; $i -lt $sta.Count; $i++) {
        if ($sta[$i] -match "Type\s*:\s*(.*Model (Setup|Hold) 'CLOCK_50')") { "{0,-45} {1}" -f $Matches[1], $sta[$i + 1].Trim() }
    }
    # pin check: the outputs must be exactly the LEDs, the displays, and the signals named in the pin list
    $pins = Get-Content "output_files\$top.pin" | Where-Object { $_ -match '^\S.*:\s*\w+\s*:' }
    $outs = $pins | Where-Object { ($_ -split ':')[2].Trim() -eq 'output' } | ForEach-Object { ($_ -split ':')[0].Trim() }
    $cfgPattern = '^(~ALTERA_\w+~|TDO|altera_reserved_\w+)'
    $user = $outs | Where-Object { $_ -notmatch $cfgPattern }
    $known = '^(LEDG|LEDR|HEX[0-7])\[\d+\]$|^ADC_(CONVST|RD_N|CS_N|RESET|RANGE)$|^ADC_OS\[\d\]$|^GATE_(EN_N|[ABC]_(HI|LO))$|^CONTACTOR$'
    $bad = $user | Where-Object { $_ -notmatch $known }
    $hdr = $user | Where-Object { $_ -match '^(ADC|GATE|CONTACTOR)' }
    "Pins: {0} user outputs, {1} on the 40-pin header; outputs not in the plan: {2}" -f $user.Count, $hdr.Count, $(if ($bad) { $bad -join ', ' } else { 'none' })
    $ins = $pins | Where-Object { ($_ -split ':')[2].Trim() -eq 'input' } | ForEach-Object { ($_ -split ':')[0].Trim() } |
        Where-Object { $_ -match '^(ADC_|DRIVERS_OK)' }
    "      header inputs: {0}" -f (($ins | Sort-Object) -join ' ')
    Get-Content "output_files\$top.fit.rpt" | Select-String 'Reserve all unused pins' | Select-Object -First 1 | ForEach-Object { $_.Line.Trim() }
} finally { Pop-Location }
