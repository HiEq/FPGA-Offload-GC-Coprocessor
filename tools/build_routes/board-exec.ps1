param(
    [Parameter(Mandatory=$true)][string[]]$Cmd,
    [string]$Port = 'auto',
    [int]$WaitMs = 30000,
    [int]$LoginWaitMs = 40000,
    [string]$User = 'root',
    [string]$Password = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'serial-port.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'serial-session.ps1')

function Get-CleanText($Session) {
    return (ConvertFrom-Ansi $Session.Sb.ToString())
}

$Port = Resolve-SerialPort $Port
$sp = New-Object System.IO.Ports.SerialPort $Port, 921600, 'None', 8, 'One'
$sp.ReadBufferSize = 65536
$sp.WriteBufferSize = 65536
$sp.ReadTimeout = 200
$sp.WriteTimeout = 5000
$sp.Open()
$s = @{ Port = $Port; Sp = $sp; Sb = (New-Object System.Text.StringBuilder) }
try {
    Start-Sleep -Milliseconds 300
    $sp.Write("`r")
    $deadline = (Get-Date).AddMilliseconds($LoginWaitMs)
    $loggedIn = $false
    $sentUser = $false
    $sentPass = $false
    while ((Get-Date) -lt $deadline) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$s.Sb.Append($c) } } catch {}
        $t = Get-CleanText $s
        if ($t -match '[\$#]\s*$') { $loggedIn = $true; break }
        if (-not $sentUser -and $t -match 'login:\s*$') {
            Write-Host ('[serial] login prompt -> {0}' -f $User)
            $sp.Write("$User`r"); $sentUser = $true
            Start-Sleep -Milliseconds 500
            continue
        }
        if (-not $sentPass -and $t -match 'Password:\s*$') {
            Write-Host ('[serial] password prompt -> {0}' -f $(if ($Password) { '<set>' } else { '<empty>' }))
            $sp.Write("$Password`r"); $sentPass = $true
            Start-Sleep -Milliseconds 800
            continue
        }
        Start-Sleep -Milliseconds 80
    }
    if (-not $loggedIn) {
        Write-Host '[serial] WARNING: no shell prompt; tail follows'
        Get-BoardSerialTail -Session $s -Lines 40 | ForEach-Object { '  | ' + $_ }
        return
    }
    $sp.Write("PS1=\$`r")
    Start-Sleep -Milliseconds 300
    try { $c = $sp.ReadExisting(); if ($c) { [void]$s.Sb.Append($c) } } catch {}

    foreach ($command in $Cmd) {
        $from = $s.Sb.Length
        for ($i = 0; $i -lt $command.Length; $i += 16) {
            $n = [Math]::Min(16, $command.Length - $i)
            $sp.Write($command.Substring($i, $n))
            Start-Sleep -Milliseconds 20
        }
        $sp.Write("`n")
        $end = (Get-Date).AddMilliseconds($WaitMs)
        $done = $false
        while ((Get-Date) -lt $end) {
            try { $c = $sp.ReadExisting(); if ($c) { [void]$s.Sb.Append($c) } } catch {}
            $newClean = ConvertFrom-Ansi ($s.Sb.ToString($from, $s.Sb.Length - $from))
            if ($newClean -match '[\$#]\s*$') { $done = $true; break }
            Start-Sleep -Milliseconds 80
        }
        Start-Sleep -Milliseconds 250
        try { $c = $sp.ReadExisting(); if ($c) { [void]$s.Sb.Append($c) } } catch {}
        $out = ConvertFrom-Ansi ($s.Sb.ToString($from, $s.Sb.Length - $from))
        $out -split "`r?`n" | ForEach-Object { '  | ' + $_ }
        if (-not $done) { Write-Host ('  [serial] timeout after {0} ms' -f $WaitMs) }
    }
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
}
