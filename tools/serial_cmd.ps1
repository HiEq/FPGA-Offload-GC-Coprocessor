param(
    [Parameter(Mandatory=$true)][string]$Cmd,
    [int]$WaitMs = 8000,
    [string]$Port = "COM3"
)
$ErrorActionPreference = 'Stop'
$sp = New-Object System.IO.Ports.SerialPort $Port,115200,'None',8,'One'
$sp.ReadBufferSize = 65536; $sp.ReadTimeout = 200
$sp.Open()
$sb = New-Object System.Text.StringBuilder

function Pump([int]$ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$sb.Append($c) } } catch {}
        Start-Sleep -Milliseconds 20
    }
}
function PumpUntil([string]$pattern, [int]$maxMs) {
    $end = (Get-Date).AddMilliseconds($maxMs)
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$sb.Append($c) } } catch {}
        if ($sb.ToString() -match $pattern) { return $true }
        Start-Sleep -Milliseconds 20
    }
    return $false
}

Pump 300
$sp.Write("`n")
Pump 400
foreach ($chunk in ($Cmd -split '(?<=\G.{16})')) {
    if ($chunk -ne '') { $sp.Write($chunk); Start-Sleep -Milliseconds 30 }
}
$sp.Write("`n")
[void](PumpUntil '#\s*$' $WaitMs)
Pump 300
$sp.Close()

$t = $sb.ToString()
($t -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 40 | ForEach-Object { "  | " + ($_ -replace "`e",'') }
