param(
    [string]$Port     = "COM5",
    [int]   $Baud     = 115200,
    [string]$Log      = "$PSScriptRoot\logs\serial.log",
    [switch]$NoInput,
    [switch]$Color,
    [switch]$NoBoardStats,
    [switch]$AlwaysKeys,        # forward keys during boot too (a keypress aborts U-Boot autoboot!)
    [switch]$Plain,             # no dashboard, serial passes straight through (fast typing)
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
$script:AnsiRe = [regex]("\x1b\[[0-9;<=>?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[\x30-\x7e]")
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
# AutoFlush=true 会让每一小段串口数据都触发一次磁盘 flush, 输入/粘贴时明显卡顿.
# 改成按渲染节奏统一 flush (见主循环), 退出时也 flush.
$sw.AutoFlush = $false

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
$script:curSeen    = ''
$script:lastRxAt   = [datetime]::Now
$script:kbErrShown = $false

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
    # 不要每帧复制整份 3000 行历史 (那样每 250ms 就是几千次分配, 输入会发卡),
    # 直接按下标取末尾几行即可
    $cl = Get-CurLine
    if ($script:injecting) { $cl = $script:lastPrompt }   # keep the prompt steady while our stats command echoes
    $histN = $script:lines.Count
    $total = $histN
    if ($cl.Length -gt 0) { $total++ }
    $start = [Math]::Max(0, $total - $ioH)

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add($line0); $out.Add($line1); $out.Add($div)
    $lastLen = 0
    for ($i = $start; $i -lt $total; $i++) {
        $s = if ($i -lt $histN) { [string]$script:lines[$i] } else { $cl }
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
# 让 Ctrl+C 作为普通按键被读取: 否则 PowerShell 会直接中断脚本, 而且没法用它
# 把板子 shell 从 '>' 续行态(PS2)里救出来
try { [Console]::TreatControlCAsInput = $true } catch {}
try { [Console]::Clear() } catch {}

Write-Host "======================================================================"
Write-Host " FOGCCC console   $Port @ $Baud   ->  $Log"
Write-Host " boot phase: keystrokes are NOT forwarded yet"
Write-Host "             (this prevents a stray key aborting U-Boot autoboot)"
Write-Host "             keys start working once Linux reaches 'login:'"
Write-Host "             override with -AlwaysKeys if you must talk to U-Boot"
Write-Host " TIP: if typing does nothing -> set the input method to EN (US).  A"
Write-Host "      Chinese IME swallows keystrokes before the console sees them."
if ($Plain) { Write-Host " PLAIN mode: no dashboard, serial passes straight through (fast typing)" }
Write-Host "======================================================================"

$lastRender = [datetime]::MinValue
$lastFlush  = [datetime]::MinValue
try {
    while ($true) {
        $now     = [datetime]::Now
        $gotData = $false
        $typed   = $false

        # --- serial in ---
        try {
            if ($sp.BytesToRead -gt 0) {
                $chunk = $sp.ReadExisting()
                # 必须用 Write-Host: [Console]::Out.Write 在这个 PowerShell 宿主里
                # 不会显示到屏幕 (日志里却有数据) —— 见笔记 F18
                if ($script:phase -eq 'raw' -or $Plain) { Write-Host $chunk -NoNewline }
                Add-Serial $chunk
                $gotData = $true
                $script:lastRxAt = [datetime]::Now
            }
        } catch {}

        # --- keyboard out (suppressed during boot unless -AlwaysKeys, so a stray
        #     keypress cannot abort U-Boot autoboot) ---
        if (-not $NoInput -and ($AlwaysKeys -or $script:phase -eq 'dash')) {
            try {
                # 把一次循环里所有待发按键攒成一个字符串再写一次:
                #   - 粘贴长命令不再逐字符发起系统调用 (那是卡顿的主因)
                #   - Enter/退格/Tab 与普通字符按原顺序拼在一起, 顺序也更稳
                
                $kb = New-Object System.Text.StringBuilder
                while ([Console]::KeyAvailable) {
                    $k  = [Console]::ReadKey($true)
                    $script:lastKey = [datetime]::Now
                    if     ($k.Key -eq [ConsoleKey]::Enter)     { [void]$kb.Append("`n") }
                    elseif ($k.Key -eq [ConsoleKey]::Backspace) { [void]$kb.Append([char]8) }
                    elseif ($k.Key -eq [ConsoleKey]::Tab)       { [void]$kb.Append("`t") }
                    elseif ($k.KeyChar -ne [char]0)             { [void]$kb.Append($k.KeyChar) }
                }
                if ($kb.Length -gt 0) {
                    $typed = $true
                    $sp.Write($kb.ToString())
                }
            } catch {
                # 原来这里是空的 catch{}, 键盘读失败时完全无声 —— 加一次可见的报错
                if (-not $script:kbErrShown) {
                    $script:kbErrShown = $true
                    Write-Host ""
                    Write-Host "[monitor] KEYBOARD READ FAILED -> typing cannot work"
                    Write-Host "          $($_.Exception.Message)"
                    Write-Host "          try: run fogccc.bat from a plain console, and keep the"
                    Write-Host "          input method on EN (US)"
                }
            }
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

        # --- track the CURRENT (possibly still incomplete) line.  Prompts like
        #     "linux login: " and "root@linux:~# " have no trailing newline, so
        #     they never arrive as a completed line. ---
        $cl = Get-CurLine
        if ($cl -ne $script:curSeen) {
            $script:curSeen    = $cl
            $script:lastLineAt = $now
            if ($cl.Length -gt 0) {
                $script:lastLine = $cl
                if ($cl -match '[#$]\s*$') { $script:promptOk = $true }
                # 看到 '>' 说明板子进了 PS2 续行态(命令没写完) —— 此时绝不能再注入,
                # 否则会在坏的输入上继续叠加, 越弄越乱
                elseif ($cl -match '^\s*>\s*$') { $script:promptOk = $false }
            }
        }

        # --- raw -> dashboard, once Linux / the shell is really up.  No key must
        #     become live before that, so autoboot can never be interrupted. ---
        if ($script:phase -eq 'raw' -and ($now - $script:lastRxAt).TotalSeconds -gt 10) {
            # 10 s of serial silence => the board is already booted (or off), so it
            # cannot still be inside the ~3 s U-Boot autoboot window.  Unlock keys,
            # otherwise a console started after boot can never be typed into.
            $script:phase = 'dash'
            $script:prevFrame = @()
            Write-Host ("`n[monitor] no serial data for 10s -> keyboard unlocked (board is probably already booted)")
        }
        if ($script:phase -eq 'raw') {
            if ($script:lastLine -match 'login:' -or $script:lastLine -match '[#$]\s*$') {
                $script:phase = 'dash'
                $script:prevFrame = @()
                try { [Console]::Clear() } catch {}
            }
            elseif ($script:lastLine -match '^\s*(Zynq>|=>)' -and
                    (($now - $script:lastLineAt).TotalSeconds -gt 3)) {
                # board is sitting at a U-Boot prompt -> unlock so you can type 'boot'
                $script:phase = 'dash'
                $script:prevFrame = @()
                try { [Console]::Clear() } catch {}
            }
        }

        # --- render (dashboard only once Linux is up) ---
        # 有串口数据或有按键时立刻重绘 (最快 40ms 一帧), 空闲时才按 RefreshMs;
        # 这样打字/粘贴的回显不再最多滞后 250ms.
        $gap = if ($gotData -or $typed) { 40 } else { $RefreshMs }
        if (-not $Plain -and $script:phase -eq 'dash' -and (($now - $lastRender).TotalMilliseconds -ge $gap)) {
            $lastRender = $now
            Render
        }
        # 日志按秒刷盘 (AutoFlush 已关)
        if (($now - $lastFlush).TotalMilliseconds -ge 1000) {
            $lastFlush = $now
            try { $sw.Flush() } catch {}
        }
        Start-Sleep -Milliseconds 3
    }
}
finally {
    try { [Console]::CursorVisible = $true } catch {}
    Write-Host ""
    Write-Host "=== stopped. Full log: $Log  (ansi=$UseAnsi) ==="
    try { $sw.Flush(); $sw.Close() } catch {}
    try { $sp.Close() } catch {}
}
