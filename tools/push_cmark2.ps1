# ============================================================
# push_cmark2.ps1 - push cmark.c as BASE64 over the serial console,
#                  verify with md5, rebuild DYNAMIC, then run the test.
#
#   Why base64: the source has UTF-8 Chinese comments.  Sending raw text in
#   chunks can split a multi-byte char and, more importantly, the board's line
#   editor dropped ~8% of the bytes last time.  base64 is pure ASCII and can be
#   verified with md5 of the DECODED file.
#
#   Why dynamic (-O2, no -static): the board's rootfs has no static libc
#   (ld: cannot find -lc).
#
#   Close the fogccc.bat console first (COM5 is exclusive).
#   ASCII-only strings on purpose (notes F17).
# ============================================================
param(
    [string]$Port = "COM5",
    [int]   $Baud = 115200,
    [string]$Src  = "$PSScriptRoot\..\csrc\cmark.c"
)

$bytes = [System.IO.File]::ReadAllBytes($Src)
$md5   = (Get-FileHash $Src -Algorithm MD5).Hash.ToLower()
$b64   = [Convert]::ToBase64String($bytes)
$b64lines = @()
for ($i = 0; $i -lt $b64.Length; $i += 72) {
    $b64lines += $b64.Substring($i, [Math]::Min(72, $b64.Length - $i))
}
Write-Host ("local: {0} bytes, md5={1}, base64 {2} lines" -f $bytes.Length, $md5, $b64lines.Count)

$sp = New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
$sp.ReadBufferSize  = 131072
$sp.WriteBufferSize = 131072
$sp.ReadTimeout     = 200
$sp.WriteTimeout    = 5000
try { $sp.Open() } catch { Write-Host "cannot open $Port : $($_.Exception.Message)"; exit 1 }
Write-Host "opened $Port @ $Baud"

$sb = New-Object System.Text.StringBuilder
function Pump([int]$ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$sb.Append($c) } } catch {}
        Start-Sleep -Milliseconds 15
    }
}
function PumpUntil([string]$pattern, [int]$maxMs) {
    $end = (Get-Date).AddMilliseconds($maxMs)
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$sb.Append($c) } } catch {}
        if ($sb.ToString() -match $pattern) { return $true }
        Start-Sleep -Milliseconds 15
    }
    return $false
}
function SendLine([string]$s, [int]$chunk = 32, [int]$gap = 25) {
    for ($i = 0; $i -lt $s.Length; $i += $chunk) {
        $n = [Math]::Min($chunk, $s.Length - $i)
        $sp.Write($s.Substring($i, $n)); Start-Sleep -Milliseconds $gap
    }
    $sp.Write("`n"); Start-Sleep -Milliseconds 60
}

SendLine ""; Pump 800
SendLine "mkdir -p /mnt/userdata"; Pump 500
SendLine "mount -t vfat /dev/mmcblk0p2 /mnt/userdata 2>/dev/null"; Pump 800

Write-Host "`n--- push base64 ---"
SendLine "rm -f /mnt/userdata/cmark.b64"
SendLine "cat > /mnt/userdata/cmark.b64 << 'B64EOF'" 32 20
Pump 400
$n = 0
foreach ($ln in $b64lines) {
    SendLine $ln 48 18
    $n++
    if (($n % 40) -eq 0) { Write-Host "   ... $n / $($b64lines.Count)" }
}
SendLine "B64EOF" 32 20
Pump 1000

Write-Host "`n--- decode + md5 verify ---"
# busybox base64 first, python3 as fallback
SendLine "base64 -d /mnt/userdata/cmark.b64 > /mnt/userdata/cmark.c 2>/dev/null || python3 -c `"import base64;open('/mnt/userdata/cmark.c','wb').write(base64.b64decode(open('/mnt/userdata/cmark.b64','rb').read()))`""
Pump 4000
SendLine "wc -c /mnt/userdata/cmark.c"; Pump 800
SendLine "md5sum /mnt/userdata/cmark.c"; Pump 1200

Write-Host "`n--- build DYNAMIC + run ---"
SendLine "rm -f /mnt/userdata/cmark"
SendLine "gcc -O2 -o /mnt/userdata/cmark /mnt/userdata/cmark.c && echo COMPILE_OK"; Pump 12000
SendLine "ls -l /mnt/userdata/cmark"; Pump 1000
SendLine "sh /mnt/userdata/run_cmark.sh"
if (PumpUntil 'speedup HW vs C' 180000) { Write-Host "`n[cmark finished]" } else { Write-Host "`n[cmark TIMEOUT]" }
Pump 2000

$sp.Close()
$out = "$PSScriptRoot\cmark_onboard.log"
[System.IO.File]::WriteAllText($out, $sb.ToString())
$log = $sb.ToString()
Write-Host ""
Write-Host "=== expected md5 : $md5"
$m = [regex]::Match($log, '(?m)^([0-9a-f]{32})\s+/mnt/userdata/cmark\.c')
if ($m.Success) {
    Write-Host "=== board    md5 : $($m.Groups[1].Value)"
    if ($m.Groups[1].Value -eq $md5) { Write-Host "=== MD5 MATCH - transfer OK ===" }
    else { Write-Host "=== MD5 MISMATCH - transfer corrupted, need slower pacing ===" }
} else { Write-Host "=== (board md5 not found in transcript) ===" }
Write-Host "=== transcript: $out ==="
