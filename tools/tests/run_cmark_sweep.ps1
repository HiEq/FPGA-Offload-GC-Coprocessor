# ============================================================
# run_cmark_sweep.ps1 - run cmark several times with larger / wider samples
#
#   Each entry below is:  maxN  trials  avg_refs
#   Edit $sweeps to change the matrix.
#
#   Close the board console first (it holds the COM port exclusively).
#
#   ASCII-ONLY, including comments.
# ============================================================
param([string]$Port = "auto", [int]$Baud = 115200)

# Port auto-detection: the CH340 re-enumerates across reboots (COM3 -> COM5 ...).
# Pass -Port COMx to override.
. (Join-Path $PSScriptRoot '..\serial-port.ps1')
$Port = Resolve-SerialPort $Port

$sweeps = @(
    ,@(4096, 24, 2)
    ,@(4096, 16, 4)
    ,@(4096, 16, 1)
    ,@(2048, 16, 2)
)

$sp = New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
$sp.ReadBufferSize  = 262144
$sp.WriteBufferSize = 65536
$sp.ReadTimeout     = 200
$sp.WriteTimeout    = 5000
try { $sp.Open() } catch { Write-Host "cannot open $Port : $($_.Exception.Message)"; exit 1 }
Write-Host "opened $Port @ $Baud"

$sb = New-Object System.Text.StringBuilder

function Pump([int]$ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$sb.Append($c); [Console]::Out.Write($c) } } catch {}
        Start-Sleep -Milliseconds 15
    }
}
function PumpUntil([string]$pattern, [int]$maxMs) {
    $end = (Get-Date).AddMilliseconds($maxMs)
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$sb.Append($c); [Console]::Out.Write($c) } } catch {}
        if ($sb.ToString() -match $pattern) { return $true }
        Start-Sleep -Milliseconds 15
    }
    return $false
}
function SendLine([string]$s, [int]$chunk = 32, [int]$gap = 25) {
    for ($i = 0; $i -lt $s.Length; $i += $chunk) {
        $n = [Math]::Min($chunk, $s.Length - $i)
        $sp.Write($s.Substring($i, $n))
        Start-Sleep -Milliseconds $gap
    }
    $sp.Write("`n")
    Start-Sleep -Milliseconds 120
}

Write-Host "`n--- sync + mount ---"
SendLine ""
Pump 800
SendLine "mkdir -p /mnt/userdata"
Pump 500
SendLine "mount -t vfat /dev/mmcblk0p2 /mnt/userdata 2>/dev/null"
Pump 800

$fail = 0
foreach ($sw in $sweeps) {
    $maxN = $sw[0]; $trials = $sw[1]; $avg = $sw[2]
    $mark = "SWEEP_" + $maxN + "_" + $trials + "_" + $avg + "_DONE"
    Write-Host ("`n===== cmark maxN=" + $maxN + " trials=" + $trials + " avg_refs=" + $avg + " =====")
    SendLine ("cd /mnt/userdata && ./cmark " + $maxN + " " + $trials + " " + $avg + " && echo " + $mark)
    if (PumpUntil $mark 300000) { Write-Host ("`n[" + $mark + " ok]") } else { Write-Host ("`n[" + $mark + " TIMEOUT]"); $fail++ }
    Pump 1200
}

$sp.Close()
$out = "$PSScriptRoot\..\logs\cmark_sweep.log"
$clean = [regex]::Replace($sb.ToString(), "`e\[[0-9;]*[A-Za-z]", "")
$lines = $clean -split "`r?`n" | Where-Object {
    $_ -notmatch '^(root@|cd /mnt/userdata|mkdir -p /mnt/userdata|mount -t vfat)' -and
    $_ -notmatch '^\d+_\d+_\d+_DONE$'
}
# 4-line provenance convention (see tools/logs/README.md).  The PL's bitstream md5 is not
# software-readable, so that line names its source; the promotion step fills in the value.
$gitSha = (& git rev-parse --short HEAD 2>$null); if (-not $gitSha) { $gitSha = 'unknown' }
$hdr = @(
    "# command: tools/tests/run_cmark_sweep.ps1 -> ./cmark <maxN> <trials> <avg_refs>   (4 groups, 72 runs)",
    "# bitstream: (the PL is loaded from the card image; md5 filled in when the log is promoted - see tools/logs/README.md)",
    "# commit: $gitSha   (this script; the card binaries' hashes are in artifacts/SHA256SUMS)",
    "# date: $(Get-Date -Format yyyy-MM-dd)",
    "# note: ANSI colour codes, prompts and the mount prologue were stripped; data lines unchanged",
    "#", ""
)
[IO.File]::WriteAllLines($out, $hdr + $lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "`n=== transcript: $out ==="
if ($fail -gt 0) { Write-Host ("SWEEP FAILED: " + $fail + " step(s) did not reach their DONE marker"); exit 1 }
exit 0
