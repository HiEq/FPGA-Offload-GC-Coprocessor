# ============================================================
# vivado_affinity.ps1 - phase-aware CPU affinity for Vivado builds
#
#   powershell -ExecutionPolicy Bypass -File tools\vivado_affinity.ps1
#
# Rule (2026-10-22):
#   synthesis (synth_1 run child) is mostly single-threaded -> pin it to
#   the P-core logical CPUs 2-3 (default) so the serial phase gets big-core
#   single-thread performance;
#   place/route (impl_1 child) and the idle project driver -> wide mask
#   0xFFFFC (all logical CPUs except 0-1, which stay for the system).
#   Every vivado process gets AboveNormal priority.
#
# The phase is identified from the child's command line.  The run children
# start with relative args (no run-dir path), so the discriminator is the
# run log extension: synth runs use system_wrapper.vds, impl runs .vdi
# ("synth_1" in the command line is kept as a secondary match).
# Only a SOLO synthesis child is pinned to the P-core: when several synth
# runs are alive at once (IP out-of-context jobs spawn their own children,
# which would inherit the narrow mask), pinning them all to two CPUs would
# serialize them -- they stay wide until only one remains.
# The script exits when no vivado.exe remains.  Run it next to a build:
#   Start-Process powershell -ArgumentList '-File','tools\vivado_affinity.ps1'
# ============================================================
param(
    [string]$SynthCpus = '2-3',
    [string]$WideMask  = '0xFFFFC',
    [int]$PollSeconds  = 5
)

function ConvertTo-Mask([string]$spec) {
    if ($spec -match '^0x[0-9A-Fa-f]+$') { return [int64]$spec }
    $mask = [int64]0
    foreach ($part in ($spec -split ',')) {
        if ($part -match '^(\d+)-(\d+)$') {
            for ($i = [int]$Matches[1]; $i -le [int]$Matches[2]; $i++) { $mask = $mask -bor ([int64]1 -shl $i) }
        } elseif ($part -match '^\d+$') {
            $mask = $mask -bor ([int64]1 -shl [int]$part)
        } else {
            throw "bad CPU spec: $spec"
        }
    }
    return $mask
}

# NB: keep these names distinct from the parameters.  PowerShell variable
# names are case-insensitive, so naming the result $wideMask would collide
# with the [string]-constrained parameter $WideMask and silently coerce the
# Int64 mask to a decimal string ("0xFFFFC" -> "1048572").
$synthCpuMask = ConvertTo-Mask $SynthCpus
$wideCpuMask  = ConvertTo-Mask $WideMask
Write-Host ("synth mask = 0x{0:X}   wide mask = 0x{1:X}" -f $synthCpuMask, $wideCpuMask)

# Full type name: the bare [ProcessPriorityClass] does not resolve in PS 5.1
# and the resulting error used to be swallowed by the catch below.
$aboveNormal = [System.Diagnostics.ProcessPriorityClass]::AboveNormal

while ($true) {
    $procs = Get-CimInstance Win32_Process -Filter "Name='vivado.exe'" -ErrorAction SilentlyContinue
    if (-not $procs) { break }
    $synthPids = @($procs | Where-Object { ('' + $_.CommandLine) -match 'synth_1|\.vds(\s|"|$)' } | ForEach-Object { $_.ProcessId })
    $synthSolo = ($synthPids.Count -eq 1)
    foreach ($wp in $procs) {
        $cmd = '' + $wp.CommandLine
        $cpuMask = $wideCpuMask
        if ($synthSolo -and ($synthPids -contains $wp.ProcessId)) { $cpuMask = $synthCpuMask }
        try {
            $p = Get-Process -Id $wp.ProcessId -ErrorAction Stop
            $changed = ($p.ProcessorAffinity -ne [IntPtr]$cpuMask) -or ($p.PriorityClass -ne $aboveNormal)
            $p.PriorityClass = $aboveNormal
            $p.ProcessorAffinity = [IntPtr]$cpuMask
            if ($changed) {
                Write-Host ("{0}  PID {1}  affinity=0x{2:X}  prio=AboveNormal" -f (Get-Date -Format HH:mm:ss), $p.Id, $cpuMask)
            }
        } catch {
            Write-Host ("{0}  PID {1}  pin failed: {2}" -f (Get-Date -Format HH:mm:ss), $wp.ProcessId, $_.Exception.Message)
        }
    }
    Start-Sleep -Seconds $PollSeconds
}
Write-Host "no vivado.exe left; watcher exits"