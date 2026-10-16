# ============================================================
# push_cmark.ps1 - push cmark.c to the board over the serial console
#                  and rebuild it on the board (no SD-card removal)
#
#   Close the fogccc.bat console first (COM5 is exclusive).
#   Usage: powershell -ExecutionPolicy Bypass -File push_cmark.ps1
#
#   How:  cat > /mnt/userdata/cmark.c << 'FOGCEOF'   (quoted heredoc => the
#         board's shell does NO expansion, so the C source lands verbatim)
#         ... file ...
#         FOGCEOF
#         then gcc -O2 -static on the board.
#
#   ASCII-only strings on purpose (see notes F17).
# ============================================================
param(
    [string]$Port = "COM5",
    [int]   $Baud = 115200,
    [string]$Src  = "$PSScriptRoot\..\csrc\cmark.c"
)

$sp = New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
$sp.ReadBufferSize  = 131072
$sp.WriteBufferSize = 131072
$sp.ReadTimeout     = 200
$sp.WriteTimeout    = 5000

try { $sp.Open() } catch {
    Write-Host "cannot open $Port : $($_.Exception.Message)"
    Write-Host "close the fogccc.bat console first."
    exit 1
}
Write-Host "opened $Port @ $Baud"

$sb = New-Object System.Text.StringBuilder
function Pump([int]$ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$sb.Append($c); [Console]::Out.Write($c) } } catch {}
        Start-Sleep -Milliseconds 10
    }
}
# send raw text in small chunks so the board's line editor never drops bytes
function SendChunked([string]$s, [int]$chunk, [int]$gap) {
    for ($i = 0; $i -lt $s.Length; $i += $chunk) {
        $n = [Math]::Min($chunk, $s.Length - $i)
        $sp.Write($s.Substring($i, $n))
        Start-Sleep -Milliseconds $gap
    }
}
function SendLine([string]$s, [int]$chunk = 24, [int]$gap = 20) {
    SendChunked $s $chunk $gap
    $sp.Write("`n")
    Start-Sleep -Milliseconds 120
}

Write-Host "`n--- sync prompt ---"
SendLine ""
Pump 800

Write-Host "`n--- mount USERDATA ---"
SendLine "mkdir -p /mnt/userdata"
Pump 600
SendLine "mount -t vfat /dev/mmcblk0p2 /mnt/userdata 2>/dev/null"
Pump 800

$lines = [System.IO.File]::ReadAllLines($Src)
$bytes = (Get-Item $Src).Length
Write-Host "`n--- push $Src ($bytes bytes, $($lines.Count) lines) ---"
SendLine "cat > /mnt/userdata/cmark.c << 'FOGCEOF'" 32 15
Pump 400
$n = 0
foreach ($ln in $lines) {
    SendChunked $ln 32 12
    $sp.Write("`n")
    Start-Sleep -Milliseconds 25
    $n++
    if (($n % 50) -eq 0) { Write-Host "   ... $n / $($lines.Count) lines" }
}
SendLine "FOGCEOF" 32 15
Pump 800

Write-Host "`n--- verify size + rebuild on board ---"
SendLine "wc -c /mnt/userdata/cmark.c"
Pump 800
SendLine "gcc -O2 -static -o /mnt/userdata/cmark /mnt/userdata/cmark.c && echo COMPILE_OK"
Pump 6000
SendLine "ls -l /mnt/userdata/cmark"
Pump 1200

$sp.Close()
[System.IO.File]::WriteAllText("$PSScriptRoot\push_cmark.log", $sb.ToString())
Write-Host "`n=== transcript: $PSScriptRoot\push_cmark.log ==="
