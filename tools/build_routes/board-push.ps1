param(
    [Parameter(Mandatory=$true)][string]$Src,
    [Parameter(Mandatory=$true)][string]$Dest,
    [string]$Port = 'auto',
    [int]$LoginWaitMs = 20000
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'serial-port.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'serial-session.ps1')

$bytes = [IO.File]::ReadAllBytes($Src)
$localMd5 = (Get-FileHash $Src -Algorithm MD5).Hash.ToLower()
$b64 = [Convert]::ToBase64String($bytes)
Write-Host ("push {0} -> {1}  {2} bytes  md5={3}" -f $Src, $Dest, $bytes.Length, $localMd5)

$Port = Resolve-SerialPort $Port
$sp = New-Object System.IO.Ports.SerialPort $Port, 921600, 'None', 8, 'One'
$sp.ReadBufferSize = 65536
$sp.WriteBufferSize = 65536
$sp.ReadTimeout = 200
$sp.WriteTimeout = 10000
$sp.Open()
$sb = New-Object System.Text.StringBuilder
function Pump([int]$ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$sb.Append($c) } } catch {}
        Start-Sleep -Milliseconds 50
    }
}
function Clean { return (ConvertFrom-Ansi $sb.ToString()) }
function WaitPrompt([int]$ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$sb.Append($c) } } catch {}
        if ((Clean) -match '[\$#]\s*$') { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}
function SendLine([string]$text) {
    for ($i = 0; $i -lt $text.Length; $i += 32) {
        $n = [Math]::Min(32, $text.Length - $i)
        $sp.Write($text.Substring($i, $n))
        Start-Sleep -Milliseconds 8
    }
    $sp.Write("`n")
}
try {
    Start-Sleep -Milliseconds 300
    $sp.Write("`r")
    if (-not (WaitPrompt $LoginWaitMs)) {
        $t = Clean
        if ($t -match 'login:\s*$') {
            SendLine 'root'
            Start-Sleep -Milliseconds 500
            if ((Clean) -match 'Password:\s*$') { SendLine '' }
        }
        if (-not (WaitPrompt 10000)) { throw 'no shell prompt' }
    }
    SendLine 'stty -echo'
    Start-Sleep -Milliseconds 300
    [void](WaitPrompt 5000)
    SendLine 'PS1=\$'
    Start-Sleep -Milliseconds 200

    $sb.Clear() | Out-Null
    SendLine "cat > /tmp/push.b64 <<'PEOF'"
    Start-Sleep -Milliseconds 100
    for ($i = 0; $i -lt $b64.Length; $i += 76) {
        SendLine $b64.Substring($i, [Math]::Min(76, $b64.Length - $i))
    }
    SendLine 'PEOF'
    if (-not (WaitPrompt 60000)) { throw 'no prompt after heredoc' }

    $sb.Clear() | Out-Null
    SendLine ("openssl base64 -d -in /tmp/push.b64 -out {0}; md5sum {0}; rm -f /tmp/push.b64" -f $Dest)
    if (-not (WaitPrompt 30000)) { throw 'no prompt after decode' }
    $t = Clean -replace "`r", ''
    Write-Host $t
    if ($t -match '([0-9a-f]{32})') {
        if ($Matches[1] -eq $localMd5) { Write-Host 'MD5 MATCH' }
        else { throw ("md5 mismatch: remote={0} local={1}" -f $Matches[1], $localMd5) }
    } else {
        throw 'md5 not found in output'
    }
}
finally {
    try { SendLine 'stty echo' } catch {}
    if ($sp.IsOpen) { $sp.Close() }
}
