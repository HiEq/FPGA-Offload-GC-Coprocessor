param(
    [Parameter(Mandatory=$true)][string]$Src,
    [Parameter(Mandatory=$true)][string]$Dest,
    [int]$ChunkKB = 64,
    [string]$Port = 'auto',
    [int]$Baud = 115200
)

# Resumable large-file push: every chunk is verified, moved to a part file on the
# card, and the completed index is recorded. A dropped shell or a power cycle only
# costs the chunk in flight; re-running the same command continues where it left off.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'serial-session.ps1')
$Port = Resolve-SerialPort $Port

$bytes = [System.IO.File]::ReadAllBytes($Src)
$localMd5 = (Get-FileHash $Src -Algorithm MD5).Hash.ToLower()
$chunkSize = $ChunkKB * 1024
$nChunks = [int][Math]::Ceiling($bytes.Length / [double]$chunkSize)
$base = Split-Path -Leaf $Dest
$partDir = '/mnt/userdata/parts'
Write-Host "src=$Src bytes=$($bytes.Length) md5=$localMd5 chunks=$nChunks chunkKB=$ChunkKB"

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 200
$sp.WriteTimeout = 20000
$sp.DtrEnable = $true
$sp.RtsEnable = $true

$script:rx = New-Object System.Text.StringBuilder
function OpenPort {
    if (-not $sp.IsOpen) { $sp.Open(); Start-Sleep -Milliseconds 300 }
}
function ClosePort {
    try { if ($sp.IsOpen) { $sp.Close() } } catch { }
}
function Drain { try { $c = $sp.ReadExisting() } catch { $c = '' }; if ($c) { [void]$script:rx.Append($c) } }
function Send([string]$s) { $sp.Write($s) }
function WaitPrompt([int]$ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end) {
        Start-Sleep -Milliseconds 100
        Drain
        if ($script:rx.ToString() -match '(?m)[#$]\s*$') { return $true }
    }
    return $false
}
function Run([string]$cmd, [int]$ms = 8000) {
    $script:rx.Clear() | Out-Null
    Send ($cmd + "`r")
    if (-not (WaitPrompt $ms)) { throw "no prompt after: $cmd" }
    return $script:rx.ToString()
}
function EnsureShell {
    OpenPort
    $script:rx.Clear() | Out-Null
    Send "`r"; Start-Sleep -Milliseconds 700; Drain
    if ($script:rx.ToString() -match 'login:') {
        Send "root`r"; Start-Sleep -Milliseconds 1200; Send "`r"; Start-Sleep -Milliseconds 1500; Drain
    }
    if (-not (WaitPrompt 5000)) { throw "no shell prompt" }
    [void](Run "stty -echo" 8000)
}

try {
    EnsureShell
    Write-Host "shell ready"

    [void](Run "mkdir -p $partDir" 8000)
    $prog = Run "cat $partDir/$base.progress 2>/dev/null || echo 0" 8000
    $done = 0
    if ($prog -match '(?m)^\s*(\d+)\s*$') { $done = [int]$Matches[1] }
    Write-Host "resume after chunk $done"

    for ($i = $done; $i -lt $nChunks; $i++) {
        $off = $i * $chunkSize
        $len = [Math]::Min($chunkSize, $bytes.Length - $off)
        $part = New-Object byte[] $len
        [Array]::Copy($bytes, $off, $part, 0, $len)
        $b64 = [Convert]::ToBase64String($part)
        $ms = New-Object System.IO.MemoryStream
        $ms.Write($part, 0, $part.Length); $ms.Position = 0
        $b64Md5 = (Get-FileHash -InputStream $ms -Algorithm MD5).Hash.ToLower()
        $ms.Dispose()

        $ok = $false
        for ($attempt = 1; $attempt -le 3 -and -not $ok; $attempt++) {
            try {
                EnsureShell
                [void](Run "rm -f /tmp/p.b64 /tmp/p.bin" 8000)
                $script:rx.Clear() | Out-Null
                Send "cat > /tmp/p.b64 <<'PEOF'`r"
                Start-Sleep -Milliseconds 80
                for ($k = 0; $k -lt $b64.Length; $k += 76) {
                    Send ($b64.Substring($k, [Math]::Min(76, $b64.Length - $k)) + "`r")
                }
                Send "PEOF`r"
                if (-not (WaitPrompt 240000)) { throw "no prompt after heredoc" }
                $out = Run "openssl base64 -d -in /tmp/p.b64 -out /tmp/p.bin; md5sum /tmp/p.bin" 120000
                $m = [regex]::Matches($out, '([0-9a-f]{32})\s+/tmp/p\.bin')
                if ($m.Count -eq 0 -or $m[$m.Count - 1].Groups[1].Value -ne $b64Md5) {
                    throw "chunk md5 mismatch"
                }
                [void](Run ("mv /tmp/p.bin " + $partDir + "/" + $base + ".part." + $i.ToString('0000')) 30000)
                [void](Run ("echo " + $i + " > " + $partDir + "/" + $base + ".progress") 30000)
                $sync = if (($i % 16) -eq 0) { "; sync" } else { "" }
                if ($sync) { [void](Run $sync.TrimStart(';').Trim() 60000) }
                Write-Host ("chunk {0}/{1} ok" -f ($i + 1), $nChunks)
                $ok = $true
            } catch {
                Write-Host ("chunk {0} attempt {1} failed: {2}" -f $i, $attempt, $_.Exception.Message)
                ClosePort
                Start-Sleep -Seconds 3
            }
        }
        if (-not $ok) { throw "chunk $i failed three times" }
    }

    EnsureShell
    $out = Run ("cat " + $partDir + "/" + $base + ".part.* > " + $Dest + "; md5sum " + $Dest + "; rm -f " + $partDir + "/" + $base + ".*; sync") 300000
    $m = [regex]::Matches($out, '([0-9a-f]{32})\s+' + [regex]::Escape($Dest))
    if ($m.Count -gt 0 -and $m[$m.Count - 1].Groups[1].Value -eq $localMd5) {
        Write-Host "md5 MATCH  $localMd5  $Dest"
    } else {
        Write-Host "md5 MISMATCH expected=$localMd5"
        exit 1
    }
}
finally {
    try { if ($sp.IsOpen) { Send "stty echo`r"; Start-Sleep -Milliseconds 300 } } catch { }
    ClosePort
}
