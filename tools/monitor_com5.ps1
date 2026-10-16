param(
    [string]$Port     = "COM5",
    [int]   $Baud     = 115200,
    [string]$Log      = "$PSScriptRoot\com5.log",
    [switch]$NoInput,
    [switch]$Color,
    [switch]$NoBoardStats,
    [switch]$AlwaysKeys,        # forward keys during boot too (a keypress aborts U-Boot autoboot!)
    [int]   $WaitPortSec = 300, # wait this long for the serial port to appear
    [int]   $RefreshMs = 250,
    [int]   $StatMs    = 2000
)

# ================================================================ ANSI
$ESC     = [char]27
$UseAnsi = $false
if ($Color) {
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
        if ([FogCCC.Native]::GetConsoleMode($h, [ref]$m)) {
            $UseAnsi = [FogCCC.Native]::SetConsoleMode($h, ($m -bor 0x0004))
        }
    } catch { $UseAnsi = $false }
}
$script:AnsiRe = [regex]("$([char]27)\[[0-9;?]*[ -/]*[@-~]")
function VisLen([string]$s) { return $script:AnsiRe.Replace($s, '').Length }

function MakeBar([double]$pct, [int]$w, [string]$rgb) {
    if ($w -lt 1) { $w = 1 }
    $p = [Math]::Max(0.0, [Math]::Min(100.0, $pct))
    $f = [int][Math]::Round($p / 100.0 * $w)
    if ($f -lt 0) { $f = 0 }
    if ($f -gt $w) { $f = $w }
    $e = $w - $f
    if ($UseAnsi) {
        $fill  = "${ESC}[1;${rgb}m|${ESC}[0m"
        $empty = "${ESC}[90m|${ESC}[0m"
        return ('' + ($fill * $f) + ($empty * $e))
    }
    return (('|' * $f) + ('.' * $e))
}
function Gauge([string]$label, [double]$pct, [int]$barW, [string]$rgb, [string]$unit = '%') {
    return (" {0,-4} [" -f $label) + (MakeBar $pct $barW $rgb) + ("] {0,5:N1}{1}" -f $pct, $unit)
}
function PadTo([string]$s, [int]$W) {
    $d = $W - (VisLen $s)
    if ($d -gt 0) { return $s + (' ' * $d) }
    return $s
}

# ================================================================ serial
# ================================================================ port resolve + wait
function Resolve-Port([string]$want) {
    $names = [System.IO.Ports.SerialPort]::GetPortNames()
    if ($want -and $want -ne 'auto' -and ($names -contains $want)) { return $want }
    # look for a CH340 / USB-serial adapter
    try {
        $d = Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
             Where-Object { $_.Name -match '\(COM\d+\)' -and
                            $_.Name -match 'CH340|USB-SERIAL|USB Serial|CP210|FT232|Silicon Labs' } |
             Select-Object -First 1
        if ($d -and $d.Name -match '\((COM\d+)\)') { return $Matches[1] }
    } catch {}
    if ($want -and $want -ne 'auto' -and ($names -contains $want)) { return $want }
    return $null
}

$sp = New-Object -TypeName System.IO.Ports.SerialPort -ArgumentList @('COM1', $Baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadBufferSize  = 65536
$sp.WriteBufferSize = 65536
$sp.ReadTimeout  = 50
$sp.WriteTimeout = 1000

Write-Host ("waiting for a serial port (looking for $Port / CH340), up to $WaitPortSec s ...")
$deadline = (Get-Date).AddSeconds($WaitPortSec)
$opened = $false
while ((Get-Date) -lt $deadline) {
    $use = Resolve-Port $Port
    if ($use) {
        try {
            $sp.PortName = $use
            $sp.Open()
            $opened = $true
            $Port = $use
            Write-Host ("connected to $use")
            break
        } catch { }
    }
    Start-Sleep -Milliseconds 500
}
if (-not $opened) {
    Write-Host "timed out waiting for the serial port.  Plug/power the board and re-run."
    Write-Host "If it is not COM5, pass the right one:  -Port COM7   (or -Port auto)"
    exit 1
}

$sw = New-Object System.IO.StreamWriter($Log, $true)
$sw.AutoFlush = $true

$script:lines   = New-Object System.Collections.Generic.List[string]
$script:lbuf    = New-Object 'char[]' 1024      # terminal-style line buffer
$script:lcol    = 0
$script:llen    = 0
$script:rxBytes = 0

# ---- board metrics ----
$script:cpuPct  = @(0.0, 0.0)          # core0, core1
$script:memPct  = 0.0
$script:tempC   = -1.0
$script:taskPct = 0.0
$script:taskLab = 'idle'
$script:prevCpu = @{}                  # name -> @(total, idle)
$script:memTot  = 0.0
$script:promptOk = $false
$script:lastKey  = [datetime]::MinValue
$script:lastStat = [datetime]::MinValue
$script:nudges   = 0
$script:prevFrame = @()
$script:lastTask  = [datetime]::MinValue
$script:lastPrompt = ''
$script:injecting  = $false
$script:injectAt   = [datetime]::MinValue
$script:phase      = 'raw'      # 'raw' while booting, 'dash' once Linux/login is up
$script:lastLine   = ''
$script:lastLineAt = [datetime]::MinValue

$STAT_CMD = (@'
{ head -3 /proc/stat; grep -E 'MemTotal|MemAvailable' /proc/meminfo; T=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null); [ -z "$T" ] && T=$(cat /sys/class/hwmon/hwmon0/temp1_input 2>/dev/null); [ -z "$T" ] && T=$(awk '{printf "%d",$1*503.975/4096*1000-273150}' /sys/bus/iio/devices/iio:device0/in_temp0_raw 2>/dev/null); [ -z "$T" ] && T=-1; echo TEMP $T; } | sed 's/^/@@S /'
'@).Trim()

function Note-Prompt([string]$line) {
    $t = $line.TrimEnd()
    if ($t.Length -gt 0) {
        $c = $t.Substring($t.Length - 1)
        $script:promptOk = ($c -eq '#' -or $c -eq '$')
        if ($script:promptOk) { $script:lastPrompt = $line; $script:injecting = $false }
    }
    # if we are at a login/password prompt, stop poking the board with newlines
    if ($line -match 'Password:' -or $line -match 'login:') { $script:nudges = 99 }
    # raw -> dashboard ONLY when Linux has really come up (login: or a shell prompt).
    # Deliberately NOT on the U-Boot prompt: no key must become live before login.
    if ($script:phase -eq 'raw') {
        if ($line -match 'login:' -or $script:promptOk) {
            $script:phase = 'dash'
            $script:prevFrame = @()
            try { [Console]::Clear() } catch {}
        }
    }
}

function Parse-Stat([string]$line) {
    # "@@S cpu0  111 0 222 3333 44 0 5 0 0 0"
    if ($line -match '^@@S\s+cpu0?\s+(.+)$') {
        $name = if ($line -match '^@@S\s+(cpu0|cpu1|cpu)\s') { $Matches[1] } else { 'cpu' }
        $nums = ($line -replace '^@@S\s+\S+\s+', '') -split '\s+' | Where-Object { $_ -ne '' }
        if ($nums.Count -ge 4) {
            $tot = 0.0; foreach ($x in $nums) { $tot += [double]$x }
            $idle = [double]$nums[3]
            if ($nums.Count -ge 5) { $idle += [double]$nums[4] }
            if ($script:prevCpu.ContainsKey($name)) {
                $pt = $script:prevCpu[$name][0]; $pi = $script:prevCpu[$name][1]
                $dt = $tot - $pt; $di = $idle - $pi
                if ($dt -gt 0) {
                    $pct = (($dt - $di) / $dt) * 100.0
                    if ($name -eq 'cpu0') { $script:cpuPct[0] = $pct }
                    elseif ($name -eq 'cpu1') { $script:cpuPct[1] = $pct }
                    elseif ($name -eq 'cpu' -and $script:cpuPct[0] -eq 0.0 -and $script:cpuPct[1] -eq 0.0) { $script:cpuPct[0] = $pct }
                }
            }
            $script:prevCpu[$name] = @($tot, $idle)
        }
    }
    elseif ($line -match '^@@S\s+MemTotal:\s+(\d+)') { $script:memTot = [double]$Matches[1] }
    elseif ($line -match '^@@S\s+MemAvailable:\s+(\d+)') {
        $av = [double]$Matches[1]
        if ($script:memTot -gt 0) { $script:memPct = (1.0 - $av / $script:memTot) * 100.0 }
    }
    elseif ($line -match '^@@S\s+TEMP\s+(-?\d+)') {
        $m = [double]$Matches[1]
        $script:tempC = if ($m -lt 0) { -1.0 } else { $m / 1000.0 }
    }
    elseif ($line -match '^@@TASK\s+(\d+)\s*(.*)$') {
        $script:taskPct = [double]$Matches[1]
        $script:taskLab = $Matches[2].Trim()
        $script:lastTask = [datetime]::Now
    }
}

function Get-CurLine {
    if ($script:llen -le 0) { return '' }
    return (-join $script:lbuf[0..($script:llen - 1)])
}

function Add-Serial([string]$chunk) {
    if (-not $chunk) { return }
    $sw.Write($chunk)
    $script:rxBytes += $chunk.Length
    $clean = $script:AnsiRe.Replace($chunk, '')
    foreach ($c in $clean.ToCharArray()) {
        if ($c -eq "`n") {
            $line = Get-CurLine
            $script:lcol = 0; $script:llen = 0
            if ($line.Length -gt 0) { $script:lastLine = $line; $script:lastLineAt = [datetime]::Now }
            if ($line -like '*@@S*' -or $line -like '*@@TASK*') {
                Parse-Stat $line          # control line: parse, do NOT show in io pane
            } elseif ($line.Length -gt 0) {
                Push-Line $line
                Note-Prompt $line
            }
        }
        elseif ($c -eq "`r") { $script:lcol = 0 }                        # CR -> column 0 (readline redraw)
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

function Push-Line([string]$s) {
    $script:lines.Add($s)
    while ($script:lines.Count -gt 3000) { $script:lines.RemoveAt(0) }
}

# ================================================================ render
function Render {
    $W = 100; $H = 30
    try { $W = [int][Console]::WindowWidth; $H = [int][Console]::WindowHeight } catch {}
    if ($W -lt 40 -or $W -gt 400) { $W = 100 }
    if ($H -lt 10) { $H = 30 }

    # TASK
    $lab = $script:taskLab
    if ($lab.Length -gt ($W - 24)) { $lab = $lab.Substring(0, [Math]::Max(0, $W - 24)) }
    $tbw = $W - 17 - $lab.Length
    if ($tbw -lt 6) { $tbw = 6 }
    $line0 = PadTo (((Gauge 'TASK' $script:taskPct $tbw '93') + ' ' + $lab)) $W

    # CPU0 CPU1 MEM TEMP
    $bw = [int](($W - 66) / 4)
    if ($bw -lt 6) { $bw = 6 }
    $tp = $script:tempC
    if ($tp -lt 0) { $tp = 0 }
    $line1 = PadTo (((Gauge 'CPU0' $script:cpuPct[0] $bw '96') + '  ' +
                     (Gauge 'CPU1' $script:cpuPct[1] $bw '96') + '  ' +
                     (Gauge 'MEM'  $script:memPct  $bw '92') + '  ' +
                     (Gauge 'TEMP' $tp $bw '91' 'C'))) $W

    # divider
    $info = " PetaLinux  $Port @ $Baud  ${W}x${H}  RX=$($script:rxBytes)B  $([datetime]::Now.ToString('HH:mm:ss')) "
    if ($info.Length -gt $W) { $info = $info.Substring(0, $W) }
    $l = [int][Math]::Floor(($W - $info.Length) / 2)
    $r = $W - $info.Length - $l
    $div = ('-' * [Math]::Max(0,$l)) + $info + ('-' * [Math]::Max(0,$r))

    # io pane
    $ioH = $H - 3
    if ($ioH -lt 1) { $ioH = 1 }
    $io = New-Object System.Collections.Generic.List[string]
    foreach ($x in $script:lines) { $io.Add($x) }
    $cl = Get-CurLine
    if ($script:injecting) { $cl = $script:lastPrompt }   # keep the prompt steady while our stats command echoes
    if ($cl.Length -gt 0) { $io.Add($cl) }
    $start = [Math]::Max(0, $io.Count - $ioH)

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add($line0); $out.Add($line1); $out.Add($div)
    $lastLen = 0
    for ($i = $start; $i -lt $io.Count; $i++) {
        $s = [string]$io[$i]
        if ($s.Length -gt $W) { $s = $s.Substring(0, $W) }
        $out.Add($s.PadRight($W))
        $lastLen = $s.Length
    }
    $contentCount = $out.Count          # 3 header rows + io rows (before padding)
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

    # blinking cursor right after the last CONTENT line (i.e. the shell prompt / input)
    $lastIdx = $contentCount - 1
    if ($lastIdx -lt 2) { $lastIdx = 2 }
    if ($lastIdx -ge $out.Count) { $lastIdx = $out.Count - 1 }
    $col = $lastLen
    if ($col -gt ($W - 1)) { $col = $W - 1 }
    if ($col -lt 0) { $col = 0 }
    try { [Console]::SetCursorPosition($col, $top + $lastIdx); [Console]::CursorVisible = $true } catch {}
}

# ================================================================ main loop
try { [Console]::CursorVisible = $false } catch {}
try { [Console]::Clear() } catch {}

Write-Host "======================================================================"
Write-Host " FOGCCC console   $Port @ $Baud   ->  $Log"
Write-Host " boot phase: keystrokes are NOT forwarded yet"
Write-Host "             (this prevents a stray key aborting U-Boot autoboot)"
Write-Host "             keys start working once Linux reaches 'login:'"
Write-Host "             override with -AlwaysKeys if you must talk to U-Boot"
Write-Host "======================================================================"

$lastRender = [datetime]::MinValue
try {
    while ($true) {
        $now = [datetime]::Now

        # --- serial in ---
        try {
            if ($sp.BytesToRead -gt 0) {
                $chunk = $sp.ReadExisting()
                if ($script:phase -eq 'raw') { Write-Host $chunk -NoNewline }   # boot: plain scroll
                Add-Serial $chunk
            }
        } catch {}

        # --- keyboard out (suppressed during boot unless -AlwaysKeys, so a stray
        #     keypress cannot abort U-Boot autoboot) ---
        if (-not $NoInput -and ($AlwaysKeys -or $script:phase -eq 'dash')) {
            try {
                while ([Console]::KeyAvailable) {
                    $k  = [Console]::ReadKey($true)
                    $ch = $k.KeyChar
                    $script:lastKey = [datetime]::Now
                    if     ($k.Key -eq [ConsoleKey]::Enter)     { $sp.Write("`n") }
                    elseif ($k.Key -eq [ConsoleKey]::Backspace) { $sp.Write([char]8) }
                    elseif ($k.Key -eq [ConsoleKey]::Tab)       { $sp.Write("`t") }
                    elseif ($ch -ne [char]0)                    { $sp.Write([string]$ch) }
                }
            } catch {}
        }

        # --- inject board stats (only when idle at a shell prompt) ---
        if (-not $NoBoardStats) {
            $idleKey  = ($now - $script:lastKey).TotalMilliseconds
            $idleStat = ($now - $script:lastStat).TotalMilliseconds
            # NEVER poke the board while we are unsure: a stray newline interrupts
            # U-Boot autoboot.  Only inject once we have REALLY seen a shell prompt.
            if ($script:promptOk -and $script:phase -eq 'dash' -and
                $idleKey -gt 2000 -and $idleStat -gt $StatMs) {
                $script:lastStat  = $now
                $script:injecting = $true
                $script:injectAt  = $now
                $sp.Write($STAT_CMD + "`n")
            }
        }

        # --- safety: if the board never returns a prompt, unlock the display ---
        if ($script:injecting -and ($now - $script:injectAt).TotalSeconds -gt 3) { $script:injecting = $false }

        # --- task marker went stale -> show idle again ---
        if ($script:taskPct -gt 0 -and ($now - $script:lastTask).TotalSeconds -gt 6) {
            $script:taskPct = 0
            $script:taskLab = 'idle'
        }

        # --- safety unlock: if the board has been SITTING at a U-Boot prompt for 3s
        #     (i.e. autoboot really is not coming), enable the keyboard so you can
        #     type 'boot' by hand. ---
        if ($script:phase -eq 'raw' -and
            $script:lastLine -match '^\s*(Zynq>|=>)' -and
            (($now - $script:lastLineAt).TotalSeconds -gt 3)) {
            $script:phase = 'dash'
            $script:prevFrame = @()
            try { [Console]::Clear() } catch {}
        }

        # --- render (dashboard only once Linux is up) ---
        if ($script:phase -eq 'dash' -and (($now - $lastRender).TotalMilliseconds -ge $RefreshMs)) {
            $lastRender = $now
            Render
        }
        Start-Sleep -Milliseconds 10
    }
}
finally {
    try { [Console]::CursorVisible = $true } catch {}
    Write-Host ""
    Write-Host "=== stopped. Full log: $Log  (ansi=$UseAnsi) ==="
    try { $sw.Flush(); $sw.Close() } catch {}
    try { $sp.Close() } catch {}
}
