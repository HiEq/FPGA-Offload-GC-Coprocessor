param(
    [Parameter(Mandatory=$true)][string]$Src,
    [Parameter(Mandatory=$true)][string]$Dest,
    [int]$ChunkKB = 128,
    [int]$LineDelayMs = 1,
    [string]$Port = 'auto',
    [int]$Baud = 115200
)

$ErrorActionPreference = 'Stop'

# Port auto-detection: the CH340 re-enumerates across reboots.
. (Join-Path $PSScriptRoot 'serial-port.ps1')
$Port = Resolve-SerialPort $Port

$bytes = [System.IO.File]::ReadAllBytes($Src)
$localMd5 = (Get-FileHash $Src -Algorithm MD5).Hash.ToLower()
$chunkSize = $ChunkKB * 1024
$nChunks = [Math]::Ceiling($bytes.Length / $chunkSize)
Write-Host "src=$Src bytes=$($bytes.Length) md5=$localMd5 chunks=$nChunks chunkKB=$ChunkKB"

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 200
$sp.WriteTimeout = 20000
$sp.DtrEnable = $true
$sp.RtsEnable = $true
$sp.Open()
Start-Sleep -Milliseconds 250

$rx = New-Object System.Text.StringBuilder
function Drain { try { $c = $sp.ReadExisting() } catch { $c = '' }; if ($c) { [void]$rx.Append($c) } }
function Send([string]$s) { $sp.Write($s) }
function WaitPrompt([int]$ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end) {
        Start-Sleep -Milliseconds 120
        Drain
        $t = $rx.ToString()
        if ($t -match '(?m)([#$]|login:)\s*$') { return $true }
    }
    return $false
}
function WaitText([string]$pat, [int]$ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end) {
        Start-Sleep -Milliseconds 120
        Drain
        if ($rx.ToString() -match $pat) { return $true }
    }
    return $false
}

try {
    Send "`r"; Start-Sleep -Milliseconds 500; Drain; $rx.Clear() | Out-Null

    # Echo off halves the traffic and removes the input backlog.
    Send "stty -echo`r"
    if (-not (WaitPrompt 8000)) { throw "shell did not answer 'stty -echo'" }
    Write-Host "echo off"

    for ($i = 0; $i -lt $nChunks; $i++) {
        $off = $i * $chunkSize
        $len = [Math]::Min($chunkSize, $bytes.Length - $off)
        $part = New-Object byte[] $len
        [Array]::Copy($bytes, $off, $part, 0, $len)
        $b64 = [Convert]::ToBase64String($part)
        $ms = New-Object System.IO.MemoryStream
        $ms.Write($part, 0, $part.Length)
        $ms.Position = 0
        $b64Md5 = (Get-FileHash -InputStream $ms -Algorithm MD5).Hash.ToLower()
        $ms.Dispose()
        $lines = @()
        for ($k = 0; $k -lt $b64.Length; $k += 76) { $lines += $b64.Substring($k, [Math]::Min(76, $b64.Length - $k)) }

        $ok = $false
        for ($attempt = 1; $attempt -le 2 -and -not $ok; $attempt++) {
            $rx.Clear() | Out-Null
            Send "cat > /tmp/p$i.b64 <<'PEOF'`r"
            Start-Sleep -Milliseconds 80
            $n = 0
            foreach ($l in $lines) {
                Send ($l + "`r"); $n++
                if ($LineDelayMs -gt 0) { Start-Sleep -Milliseconds $LineDelayMs }
                if (($n % 40) -eq 0) { Drain }
            }
            Send "PEOF`r"
            # Do not guess a fixed sleep: wait for the prompt.
            if (-not (WaitPrompt 240000)) { throw "chunk ${i}: no prompt after heredoc" }
            $rx.Clear() | Out-Null
            Send "openssl base64 -d -in /tmp/p$i.b64 -out /tmp/p$i.bin; md5sum /tmp/p$i.bin`r"
            [void](WaitText '([0-9a-f]{32})\s+/tmp/p' 120000)
            Drain
            $t = $rx.ToString() -replace "`r", ''
            $ms2 = [regex]::Matches($t, '([0-9a-f]{32})\s+/tmp/p\d+\.bin')
            $m = if ($ms2.Count -gt 0) { $ms2[$ms2.Count - 1] } else { $null }
            if ($m -and $m.Groups[1].Value -eq $b64Md5) {
                $ok = $true
                Write-Host ("chunk {0}/{1}: {2} bytes ok (attempt {3})" -f ($i + 1), $nChunks, $len, $attempt)
            } else {
                Write-Host ("chunk {0}/{1}: mismatch (attempt {2}), retrying" -f ($i + 1), $nChunks, $attempt)
            }
        }
        if (-not $ok) { throw "chunk ${i} failed twice" }
    }

    $rx.Clear() | Out-Null
    Send "cat /tmp/p*.bin > $Dest; md5sum $Dest; rm -f /tmp/p*.b64 /tmp/p*.bin`r"
    [void](WaitText '([0-9a-f]{32})\s+' 180000)
    Drain
    $t = $rx.ToString() -replace "`r", ''
    $ms3 = [regex]::Matches($t, '([0-9a-f]{32})\s+' + [regex]::Escape($Dest))
    $m = if ($ms3.Count -gt 0) { $ms3[$ms3.Count - 1] } else { $null }
    if ($m -and $m.Groups[1].Value -eq $localMd5) {
        Write-Host "md5 MATCH  $($m.Groups[1].Value)  $Dest"
    } else {
        $remote = if ($m) { $m.Groups[1].Value } else { '(none)' }
        Write-Host "md5 MISMATCH remote=$remote expected=$localMd5"
        exit 1
    }
}
finally {
    try { Send "stty echo`r"; Start-Sleep -Milliseconds 300; Drain } catch { }
    if ($sp.IsOpen) { $sp.Close() }
}
