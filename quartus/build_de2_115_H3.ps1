# H3: builds the DE2-115 file (de2_115_top_H3.sof) of the stand-alone demo and
# checks it: resources, timing at 50 MHz, and that the only pins driven are the
# LEDs and the 7-segment displays.
#
# From the APF_FPGA folder:
#   .\quartus\build_de2_115_H3.ps1
# Result: quartus\de2_115_H3\output_files\de2_115_top_H3.sof (load it with the Quartus Programmer)
param(
    [string] $QuartusBin = ''          # default: found from QUARTUS_ROOTDIR (set by the Quartus installer)
)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
if (-not $QuartusBin) {
    if ($env:QUARTUS_ROOTDIR) { $QuartusBin = Join-Path $env:QUARTUS_ROOTDIR 'bin64' }
    elseif (Get-Command quartus_sh -ErrorAction SilentlyContinue) { $QuartusBin = Split-Path (Get-Command quartus_sh).Source }
    else { throw 'Quartus not found: install Quartus Prime Lite or pass -QuartusBin <folder with quartus_sh.exe>' }
}
$top = 'de2_115_top_H3'
$dir = Join-Path $PSScriptRoot 'de2_115_H3'
New-Item -ItemType Directory -Force $dir | Out-Null
function Abs($f) { (Resolve-Path (Join-Path $root $f)).Path -replace '\\', '/' }

$files = 'srf_pll', 'apf_reference', 'current_controller', 'three_phase_pwm', 'apf_core',
         'virtual_power_stage_H3', 'vps_adc_H3', 'thd_meter_H3', 'apf_vps_system_H3', 'display_H3', $top
$lines = @(
    "project_new $top -overwrite",
    'set_global_assignment -name FAMILY "Cyclone IV E"',
    'set_global_assignment -name DEVICE EP4CE115F29C7',
    "set_global_assignment -name TOP_LEVEL_ENTITY $top",
    "set_global_assignment -name SDC_FILE $top.sdc",
    'set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL',
    'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files',
    'set_global_assignment -name STRATIX_DEVICE_IO_STANDARD "3.3-V LVTTL"',
    # every pin not in the pin list is an input, so nothing on the headers is driven
    'set_global_assignment -name RESERVE_ALL_UNUSED_PINS_WEAK_PULLUP "AS INPUT TRI-STATED"'
)
foreach ($f in $files) { $lines += "set_global_assignment -name SYSTEMVERILOG_FILE $(Abs "rtl/$f.sv")" }
# Quartus reads the tables relative to its own project folder, so pass them as absolute paths.
$lines += "set_parameter -name COS_FILE `"$(Abs 'rtl/cos_table_4096.hex')`""
$lines += "set_parameter -name THD_TABLE_FILE `"$(Abs 'rtl/thd_table_200.hex')`""
$lines += "source $(Abs 'quartus/de2_115_pins_H3.tcl')"
$lines += 'project_close'
$lines | Set-Content (Join-Path $dir 'make_project.tcl') -Encoding ascii
@(
    'create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]',
    'derive_clock_uncertainty',
    '# buttons and switches are synchronized and debounced; LEDs and displays are for the eye',
    'set_false_path -from [get_ports {KEY[*] SW[*]}]',
    'set_false_path -to [get_ports {LEDG[*] LEDR[*] HEX*}]'
) | Set-Content (Join-Path $dir "$top.sdc") -Encoding ascii

Push-Location $dir
try {
    & "$QuartusBin\quartus_sh.exe" -t make_project.tcl | Out-Null
    foreach ($tool in 'quartus_map', 'quartus_fit', 'quartus_asm', 'quartus_sta') {
        $out = & "$QuartusBin\$tool.exe" $top 2>&1
        $out | Select-String 'Error \(|was successful|readmemh|Can''t open|initialization file|uninferred' |
            ForEach-Object { "[$tool] " + $_.Line.Trim() }
        if ($LASTEXITCODE -ne 0) { throw "$tool failed" }
    }
    Get-Content "output_files\$top.fit.summary" | Select-String 'logic elements|Total registers|Total pins|memory bits|Multiplier'
    $sta = Get-Content "output_files\$top.sta.summary"
    for ($i = 0; $i -lt $sta.Count; $i++) {
        if ($sta[$i] -match "Type\s*:\s*(.*Model (Setup|Hold) 'CLOCK_50')") { "{0,-45} {1}" -f $Matches[1], $sta[$i + 1].Trim() }
    }
    # pin check: every user output must be an LED or a display segment. The chip's own
    # configuration and JTAG pins (~ALTERA_...~, TDO) are listed apart: every design has them.
    $pins = Get-Content "output_files\$top.pin" | Where-Object { $_ -match '^\S.*:\s*\w+\s*:' }
    $outs = $pins | Where-Object { ($_ -split ':')[2].Trim() -eq 'output' } | ForEach-Object { ($_ -split ':')[0].Trim() }
    $cfg = $outs | Where-Object { $_ -match '^(~ALTERA_\w+~|TDO)' }
    $user = $outs | Where-Object { $_ -notmatch '^(~ALTERA_\w+~|TDO)' }
    $bad = $user | Where-Object { $_ -notmatch '^(LEDG|LEDR|HEX[0-7])\[\d+\]$' }
    "Pins: {0} user outputs, other user outputs than LEDs and displays: {1}" -f $user.Count, $(if ($bad) { $bad -join ', ' } else { 'none' })
    "      configuration/JTAG outputs: {0}" -f ($cfg -join ', ')
    Get-Content "output_files\$top.fit.rpt" | Select-String 'Reserve all unused pins' | Select-Object -First 1 | ForEach-Object { $_.Line.Trim() }
} finally { Pop-Location }
