param(
    [string]$Port = "COM5",
    [int]$Baud = 115200,
    [string]$File = "$PSScriptRoot\gc_test.py",
    [string]$Remote = "/tmp/gc.py",
    [string]$RunArgs = "4096 8 2",
    [string]$Log = "$PSScriptRoot\com5.log",
    [int]$LineDelayMs = 18,
    [switch]$Color,
    [switch]$PushOnly,
    [int]$AfterSec = 8
)

# ================================================================ ANSI
$ESC = [char]27
$UseAnsi = $false
if (-not $NoColor) {
    try {
        if (-not ([System.Management.Automation.PSTypeName]'FogCCC.Native').Type) {
            Add-Type -Namespace FogCCC -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleMode(IntPtr h, uint m);
'@
        }
        $h = [FogCCC.Native]::GetStdHandle(-11)
        $m = [uint32]0
        if ([FogCCC.Native]::GetConsoleMode($h, [ref]$m)) { $UseAnsi = [FogCCC.Native]::SetConsoleMode($h, ($m -bor 0x0004)) }
    } catch { $UseAnsi = $false }
}
$AnsiRe = [regex]("\x1b\[[0-9;<=>?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[\x30-\x7e]")
function VisLen([string]$s) { return $AnsiRe.Replace($s, '').Length }
function MakeBar([double]$pct, [int]$w, [string]$rgb) {
    if ($w -lt 1) { $w = 1 }
    $p = [Math]::Max(0.0, [Math]::Min(100.0, $pct))
    $f = [int][Math]::Round($p / 100.0 * $w)
    if ($f -lt 0) { $f = 0 }; if ($f -gt $w) { $f = $w }
    $e = $w - $f
    if ($UseAnsi) {
        $fill  = "${ESC}[1;${rgb}m|${ESC}[0m"
        $empty = "${ESC}[90m|${ESC}[0m"
        return ('' + ($fill * $f) + ($empty * $e))
    }
    return (('|' * $f) + ('.' * $e))
}
function Gauge([string]$l, [double]$p, [int]$w, [string]$rgb) {
    return (" {0,-4} [" -f $l) + (MakeBar $p $w $rgb) + ("] {0,5:N1}%" -f $p)
}
function PadTo([string]$s, [int]$W) { $d = $W - (VisLen $s); if ($d -gt 0) { return $s + (' ' * $d) }; return $s }

# ================================================================ state
$script:lines   = New-Object System.Collections.Generic.List[string]
$script:lbuf    = New-Object 'char[]' 1024
$script:lcol    = 0
$script:llen    = 0
$script:rxBytes = 0
$script:cpuPct  = @(0.0, 0.0)
$script:memPct  = 0.0
$script:taskPct = 0.0
$script:taskLab = 'starting'
$script:prevCpu = @{}
$script:memTot  = 0.0
$script:promptOk = $false
$script:status  = 'push'
$script:prevFrame = @()
$script:lastPrompt = ''
$script:injecting  = $false
$script:injectAt   = [datetime]::MinValue

$STAT_CMD = "{ head -3 /proc/stat; grep -E 'MemTotal|MemAvailable' /proc/meminfo; } | sed 's/^/@@S /'"

function Looks-Noise([string]$line) {
    if ($line -like '*@@S*' -or $line -like '*@@TASK*') { return $true }
    if ($line -like '*base64 -d*' -or $line -like '*B64EOF*') { return $true }
    $t = $line.Trim()
    if ($t.Length -ge 56 -and $t -match '^[A-Za-z0-9+/=]+$') { return $true }   # base64 echo
    return $false
}

function Note-Prompt([string]$line) {
    $t = $line.TrimEnd()
    if ($t.Length -gt 0) {
        $c = $t.Substring($t.Length - 1)
        $script:promptOk = ($c -eq '#' -or $c -eq '$')
        if ($script:promptOk) { $script:lastPrompt = $line; $script:injecting = $false }
    }
}

function Parse-Stat([string]$line) {
    if ($line -match '^@@S\s+(cpu0|cpu1|cpu)\s') {
        $name = $Matches[1]
        $nums = ($line -replace '^@@S\s+\S+\s+', '') -split '\s+' | Where-Object { $_ -ne '' }
        if ($nums.Count -ge 4) {
            $tot = 0.0; foreach ($x in $nums) { $tot += [double]$x }
            $idle = [double]$nums[3]; if ($nums.Count -ge 5) { $idle += [double]$nums[4] }
            if ($script:prevCpu.ContainsKey($name)) {
                $dt = $tot - $script:prevCpu[$name][0]; $di = $idle - $script:prevCpu[$name][1]
                if ($dt -gt 0) {
                    $pct = (($dt - $di) / $dt) * 100.0
                    if ($name -eq 'cpu0') { $script:cpuPct[0] = $pct }
                    elseif ($name -eq 'cpu1') { $script:cpuPct[1] = $pct }
                }
            }
            $script:prevCpu[$name] = @($tot, $idle)
        }
    }
    elseif ($line -match '^@@S\s+MemTotal:\s+(\d+)') { $script:memTot = [double]$Matches[1] }
    elseif ($line -match '^@@S\s+MemAvailable:\s+(\d+)') {
        if ($script:memTot -gt 0) { $script:memPct = (1.0 - ([double]$Matches[1]) / $script:memTot) * 100.0 }
    }
    elseif ($line -match '^@@TASK\s+(\d+)\s*(.*)$') { $script:taskPct = [double]$Matches[1]; $script:taskLab = $Matches[2].Trim() }
}

function Get-CurLine {
    if ($script:llen -le 0) { return '' }
    return (-join $script:lbuf[0..($script:llen - 1)])
}

function Add-Serial([string]$chunk) {
    if (-not $chunk) { return }
    $script:rxBytes += $chunk.Length
    $clean = $AnsiRe.Replace($chunk, '')
    foreach ($c in $clean.ToCharArray()) {
        if ($c -eq "`n") {
            $line = Get-CurLine
            $script:lcol = 0; $script:llen = 0
            if (Looks-Noise $line) {
                Parse-Stat $line
            } elseif ($line.Length -gt 0) {
                $script:lines.Add($line)
                while ($script:lines.Count -gt 3000) { $script:lines.RemoveAt(0) }
                Note-Prompt $line
            }
        }
        elseif ($c -eq "`r") { $script:lcol = 0 }
        elseif ($c -eq [char]8) { if ($script:lcol -gt 0) { $script:lcol-- } }
        elseif ($c -eq "`t") {
            $n = 4 - ($script:lcol % 4)
            for ($k = 0; $k -lt $n -and $script:lcol -lt 1024; $k++) { $script:lbuf[$script:lcol] = ' '; $script:lcol++ }
            if ($script:lcol -gt $script:llen) { $script:llen = $script:lcol }
        }
        elseif ([int]$c -ge 32) {
            if ($script:lcol -lt 1024) {
                $script:lbuf[$script:lcol] = $c
                $script:lcol++
                if ($script:lcol -gt $script:llen) { $script:llen = $script:lcol }
            }
        }
    }
}

# ================================================================ render
function Render {
    $W = 100; $H = 30
    try { $W = [int][Console]::WindowWidth; $H = [int][Console]::WindowHeight } catch {}
    if ($W -lt 40 -or $W -gt 400) { $W = 100 }
    if ($H -lt 10) { $H = 30 }

    $lab = $script:taskLab
    if ($lab.Length -gt ($W - 24)) { $lab = $lab.Substring(0, [Math]::Max(0, $W - 24)) }
    $tbw = $W - 17 - $lab.Length; if ($tbw -lt 6) { $tbw = 6 }
    $line0 = PadTo ((Gauge 'TASK' $script:taskPct $tbw '93') + ' ' + $lab) $W

    $bw = [int](($W - 51) / 3); if ($bw -lt 6) { $bw = 6 }
    $line1 = PadTo ((Gauge 'CPU0' $script:cpuPct[0] $bw '96') + '   ' + (Gauge 'CPU1' $script:cpuPct[1] $bw '96') + '   ' + (Gauge 'MEM' $script:memPct $bw '92')) $W

    $info = " PetaLinux  $Port @ $Baud  ${W}x${H}  RX=$($script:rxBytes)B  $([datetime]::Now.ToString('HH:mm:ss')) "
    if ($info.Length -gt $W) { $info = $info.Substring(0, $W) }
    $l = [int][Math]::Floor(($W - $info.Length) / 2); $r = $W - $info.Length - $l
    $div = ('-' * [Math]::Max(0,$l)) + $info + ('-' * [Math]::Max(0,$r))

    $ioH = $H - 3; if ($ioH -lt 1) { $ioH = 1 }
    $io = New-Object System.Collections.Generic.List[string]
    foreach ($x in $script:lines) { $io.Add($x) }
    $cl = Get-CurLine
    if ($script:injecting) { $cl = $script:lastPrompt }
    if ($cl.Length -gt 0) { $io.Add($cl) }
    $start = [Math]::Max(0, $io.Count - $ioH)

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add($line0); $out.Add($line1); $out.Add($div)
    $lastLen = 0
    for ($i = $start; $i -lt $io.Count; $i++) {
        $s = [string]$io[$i]; if ($s.Length -gt $W) { $s = $s.Substring(0, $W) }
        $out.Add($s.PadRight($W))
        $lastLen = $s.Length
    }
    $contentCount = $out.Count
    while ($out.Count -lt $H) { $out.Add(' ' * $W) }

    $top = 0
    try { $top = [Console]::WindowTop } catch { $top = 0 }
    try {
        if ($script:prevFrame.Count -ne $out.Count) { $script:prevFrame = @() }
        for ($i = 0; $i -lt $out.Count; $i++) {
            if ($i -ge $script:prevFrame.Count -or $script:prevFrame[$i] -ne $out[$i]) {
                [Console]::SetCursorPosition(0, $top + $i)
                [Console]::Out.Write($out[$i])
            }
        }
    } catch {}
    $script:prevFrame = $out.ToArray()

    # blinking cursor right after the last CONTENT line (shell prompt / input)
    $lastIdx = $contentCount - 1
    if ($lastIdx -lt 2) { $lastIdx = 2 }
    if ($lastIdx -ge $out.Count) { $lastIdx = $out.Count - 1 }
    $col = $lastLen
    if ($col -gt ($W - 1)) { $col = $W - 1 }
    if ($col -lt 0) { $col = 0 }
    try { [Console]::SetCursorPosition($col, $top + $lastIdx); [Console]::CursorVisible = $true } catch {}
}

# ================================================================ serial + pump
$sp = New-Object -TypeName System.IO.Ports.SerialPort -ArgumentList @($Port, $Baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadBufferSize  = 65536
$sp.WriteBufferSize = 65536
$sp.ReadTimeout  = 50
$sp.WriteTimeout = 2000
try { $sp.Open() } catch { Write-Host "Failed to open $Port : $_"; exit 1 }
$sw = New-Object System.IO.StreamWriter($Log, $true)
$sw.AutoFlush = $true

$script:lastRender = [datetime]::MinValue
function Pump([int]$ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end) {
        try { if ($sp.BytesToRead -gt 0) { $chunk = $sp.ReadExisting(); $sw.Write($chunk); Add-Serial $chunk } } catch {}
        $now = [datetime]::Now
        if (($now - $script:lastRender).TotalMilliseconds -ge 200) { $script:lastRender = $now; Render }
        Start-Sleep -Milliseconds 8
    }
}
function Tx([string]$s) { $sp.Write($s) }

# ================================================================ main
try { [Console]::CursorVisible = $false } catch {}
try { [Console]::Clear() } catch {}

# --- guard: refuse to run if the board is still sitting at the login prompt ---
$script:taskPct = 0; $script:taskLab = "checking board prompt"
Tx("`n"); Pump 1200
$tail = ($script:lines | Select-Object -Last 15) -join " | "
if ($tail -match 'Password:' -or $tail -match 'login:') {
    try { [Console]::CursorVisible = $true } catch {}
    Write-Host ""
    Write-Host "================================================================"
    Write-Host " ABORT: the board is still at the LOGIN prompt, not a shell."
    Write-Host ""
    Write-Host " Please log in FIRST in the serial window:"
    Write-Host "     linux login: petalinux"
    Write-Host "     Password:    <press Enter, it is empty, then set a new one>"
    Write-Host "     petalinux@linux:~$ sudo -i"
    Write-Host "     password:    <your new password>"
    Write-Host " and only then re-run this script."
    Write-Host "================================================================"
    try { $sw.Flush(); $sw.Close() } catch {}
    try { $sp.Close() } catch {}
    exit 2
}

if (-not (Test-Path $File)) { Write-Host "no such file: $File"; exit 1 }
$bytes = [System.IO.File]::ReadAllBytes($File)
$b64   = [Convert]::ToBase64String($bytes)
$md5   = (Get-FileHash -Algorithm MD5 -Path $File).Hash.ToLower()
$bl = @(); for ($i = 0; $i -lt $b64.Length; $i += 76) { $bl += $b64.Substring($i, [Math]::Min(76, $b64.Length - $i)) }

$script:taskPct = 0; $script:taskLab = "reset target shell"
Tx("`n"); Pump 500
Tx([char]3); Pump 300; Tx("B64EOF`n"); Pump 200; Tx([char]3); Pump 300; Tx("`n"); Pump 600

# sample board CPU/MEM (two samples) before we hog the link
$script:taskPct = 2; $script:taskLab = "sampling board cpu/mem"
Tx($STAT_CMD + "`n"); Pump 1500
Tx($STAT_CMD + "`n"); Pump 1500

if (-not $PushOnly) { }

# --- send file (echo off so the base64 lines do not flood the console) ---
$script:taskPct = 5; $script:taskLab = "sending base64 ($($bl.Count) lines)"
Tx("stty -echo`n"); Pump 300
Tx("base64 -d > $Remote << 'B64EOF'`n"); Pump 150
$nSent = 0
foreach ($l in $bl) {
    Tx($l + "`n"); $nSent++
    if (($nSent % 4) -eq 0) { Pump $LineDelayMs } else { Start-Sleep -Milliseconds $LineDelayMs }
    $script:taskPct = 5 + 55.0 * $nSent / $bl.Count
    $script:taskLab = "sending base64  $nSent / $($bl.Count)"
}
Tx("B64EOF`n"); Pump 400
Tx("stty echo`n"); Pump 400

# --- verify ---
$script:taskPct = 62; $script:taskLab = "verifying md5"
Tx("sync; wc -c $Remote; md5sum $Remote`n"); Pump 4000
$ok = $false
foreach ($x in $script:lines) { if ($x -match [regex]::Escape($md5)) { $ok = $true } }
$script:taskLab = if ($ok) { "MD5 OK" } else { "MD5 NOT found!" }
$script:taskPct = 68
Pump 800

if ($PushOnly) { Pump 1500; try { [Console]::CursorVisible = $true } catch {}; exit 0 }

# --- run test ---
$script:taskPct = 70; $script:taskLab = "running python3 $Remote $RunArgs"
$script:promptOk = $false
Tx("python3 $Remote $RunArgs`n")
$testEnd = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $testEnd) {
    Pump 250
    if ($script:taskPct -ge 100) { break }
    if ($script:promptOk) { break }
}

# --- post: keep the dashboard live (real-time board cpu/mem) until Ctrl+C ---
$script:taskPct = 100; $script:taskLab = "done"
$doneAt = [datetime]::Now
$script:lastStat = [datetime]::MinValue
Tx("`n"); Pump 400
try {
    while ($true) {
        Pump 250
        $now = [datetime]::Now
        if (($now - $doneAt).TotalSeconds -gt 6) {
            $script:taskPct = 0
            $script:taskLab = "idle - live monitor (Ctrl+C to quit)"
        }
        if ($script:promptOk -and (($now - $script:lastStat).TotalMilliseconds -gt 2000)) {
            $script:lastStat = $now
            $script:injecting = $true
            $script:injectAt  = $now
            Tx($STAT_CMD + "`n")
        }
        if ($script:injecting -and (($now - $script:injectAt).TotalSeconds -gt 3)) { $script:injecting = $false }
    }
}
finally {
    try { [Console]::CursorVisible = $true } catch {}
    Write-Host ""
    Write-Host "=== stopped.  md5 $md5  ->  $Remote ==="
    Write-Host "=== full raw log: $Log ==="
    try { $sw.Flush(); $sw.Close() } catch {}
    try { $sp.Close() } catch {}
}
