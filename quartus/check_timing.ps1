# Compiles one RTL block for the DE1-SoC chip (5CSEMA5F31C6) with a 50 MHz clock
# and prints resource use and worst-case timing slack. No pin assignments: this
# checks that the logic fits and is fast enough, not board wiring.
#
# Example (from the APF_FPGA folder):
#   .\quartus\check_timing.ps1 -Top three_phase_pwm -Files rtl\three_phase_pwm.sv
param(
    [Parameter(Mandatory)] [string]   $Top,
    [Parameter(Mandatory)] [string[]] $Files,
    [string] $Clock = 'clk',
    [hashtable] $Parameters = @{},   # e.g. @{ COS_FILE = 'rtl/cos_table_4096.hex' } (paths relative to APF_FPGA)
    [string] $QuartusBin = ''          # default: found from QUARTUS_ROOTDIR (set by the Quartus installer)
)
# Quartus writes harmless notices to stderr, so rely on its exit codes instead
# of PowerShell's error stream.
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
if (-not $QuartusBin) {
    if ($env:QUARTUS_ROOTDIR) { $QuartusBin = Join-Path $env:QUARTUS_ROOTDIR 'bin64' }
    elseif (Get-Command quartus_sh -ErrorAction SilentlyContinue) { $QuartusBin = Split-Path (Get-Command quartus_sh).Source }
    else { throw 'Quartus not found: install Quartus Prime Lite or pass -QuartusBin <folder with quartus_sh.exe>' }
}
$dir = Join-Path $PSScriptRoot "check_$Top"
New-Item -ItemType Directory -Force $dir | Out-Null

$lines = @(
    "project_new $Top -overwrite",
    'set_global_assignment -name FAMILY "Cyclone V"',
    'set_global_assignment -name DEVICE 5CSEMA5F31C6',
    "set_global_assignment -name TOP_LEVEL_ENTITY $Top",
    "set_global_assignment -name SDC_FILE $Top.sdc",
    'set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL'
)
foreach ($f in $Files) {
    $full = (Resolve-Path (Join-Path $root $f)).Path -replace '\\', '/'
    $kind = if ($f -like '*.sv') { 'SYSTEMVERILOG_FILE' } else { 'VERILOG_FILE' }
    $lines += "set_global_assignment -name $kind $full"
}
foreach ($k in $Parameters.Keys) {
    $v = $Parameters[$k]
    # Quartus reads files relative to its own project folder, so pass file paths as absolute.
    $candidate = Join-Path $root $v
    if (Test-Path $candidate) { $v = (Resolve-Path $candidate).Path -replace '\\', '/' }
    $lines += "set_parameter -name $k `"$v`""
}
$lines += 'project_close'
$lines | Set-Content (Join-Path $dir 'make_project.tcl') -Encoding ascii
"create_clock -name $Clock -period 20.000 [get_ports $Clock]" |
    Set-Content (Join-Path $dir "$Top.sdc") -Encoding ascii

Push-Location $dir
try {
    & "$QuartusBin\quartus_sh.exe" -t make_project.tcl | Out-Null
    foreach ($tool in 'quartus_map', 'quartus_fit', 'quartus_sta') {
        $out = & "$QuartusBin\$tool.exe" $Top 2>&1
        $out | Select-String 'Error \(|was successful|lpm_divide|uninferred' | ForEach-Object { "[$tool] " + $_.Line.Trim() }
        if ($LASTEXITCODE -ne 0) { throw "$tool failed" }
    }
    Get-Content "$Top.fit.summary" | Select-String 'ALMs|Total registers|block memory|DSP'
    $sta = Get-Content "$Top.sta.summary"
    for ($i = 0; $i -lt $sta.Count; $i++) {
        if ($sta[$i] -match "Type\s*:\s*(.*Model (Setup|Hold) '$Clock')") { "{0,-45} {1}" -f $Matches[1], $sta[$i + 1].Trim() }
    }
} finally { Pop-Location }
