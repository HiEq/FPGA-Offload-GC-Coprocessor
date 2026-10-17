param([string]$Port = "COM3")

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outFile = "$PSScriptRoot\cmark_verify_$stamp.log"

$sp = New-Object System.IO.Ports.SerialPort $Port,115200,'None',8,'One'
$sp.ReadBufferSize  = 65536
$sp.WriteBufferSize = 65536
$sp.ReadTimeout     = 200
$sp.WriteTimeout    = 3000
$sp.Open()
Write-Host "opened $Port @ 115200"

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

function SendLine([string]$s) {
    Write-Host ("> " + $s)
    for ($i = 0; $i -lt $s.Length; $i += 16) {
        $n = [Math]::Min(16, $s.Length - $i)
        $sp.Write($s.Substring($i, $n))
        Start-Sleep -Milliseconds 30
    }
    $sp.Write("`n")
    Start-Sleep -Milliseconds 400
}

SendLine ""
[void](PumpUntil '#\s*$' 5000)

# make sure the partition is still mounted
SendLine "mkdir -p /mnt/userdata"
[void](PumpUntil '#\s*$' 8000)
SendLine "ls /mnt/userdata/cmark >/dev/null 2>&1 || mount -t vfat /dev/mmcblk0p2 /mnt/userdata"
[void](PumpUntil '#\s*$' 10000)
Pump 300

Write-Host "`n=== running run_cmark.sh ==="
SendLine "sh /mnt/userdata/run_cmark.sh"
$done = PumpUntil 'speedup HW vs C-cached|ERROR|No such file|Permission denied' 420000
Write-Host ("  finished=" + $done)
Pump 2500

$sp.Close()
[System.IO.File]::WriteAllText($outFile, $sb.ToString())
Write-Host "`n=== transcript saved: $outFile ==="

$t = $sb.ToString()
Write-Host "=== tail ==="
($t -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 30 | ForEach-Object { "  | " + $_ }
