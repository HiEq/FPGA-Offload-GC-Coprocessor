<#
  serial-monitor.ps1 —— LINUX-FPGA / FOGCCC2 共用的统一串口控制台
  ================================================================
  这份文件在两个工程里同名同内容，改动后请把另一份覆盖成同样的字节：

    LINUX-FPGA\scripts\serial-monitor.ps1     （由 watch-serial.bat 调用）
    FOGCCC2\tools\serial-monitor.ps1          （由 fogccc.bat 调用）

  两处不同的默认值交给调用方（.bat）传参，脚本本身只有一套：
    日志     LINUX-FPGA 用默认 ..\logs\serial-<时间>.log；
             FOGCCC2 传 -Log logs\serial.log（固定名，log.bat 看它）
    等端口   LINUX-FPGA 默认 -WaitPortSec 0（没端口立刻退出）；
             FOGCCC2 传 300（控制台先开、板子后上电）

  功能：
    收 / 发 / 落盘日志 / 可选时间戳 / 可选本地回显 / 定时退出
    开机阶段不转发按键（防手抖打断 U-Boot 自启动），见到 login: 或提示符后解锁
    宿主 -> 板子 时钟同步：板上没有 RTC 也没有网络，每次上电都退回 2018-03-09。
      见到 shell 提示符且控制台空闲时，用宿主 UTC 时间发一次 date -s

  用法：
    watch-serial.bat / fogccc.bat         默认端口自动识别 921600
    ... COM5                              指定端口
    ... -Port COM5 -Baud 921600
    ... -TimeStamp                        每行加 [+秒] 时间戳（测启动耗时）
    ... -NoInput                          只看不发
    ... -Log D:\x.log                     自定义日志文件
    ... -WaitPortSec 300                  等端口出现（板子还没上电时）
    ... -NoTimeSync                       不自动同步宿主时间
    ... -AlwaysKeys                       开机阶段也转发按键（按一下会打断 U-Boot 自启动）
    ... -Duration 20                      跑 20 秒自动退出

  键盘：
    普通字符直接发；Enter=CR；Backspace=BS；方向键=ESC[A/B
    Ctrl+C 作为 0x03 发给板子（用于打断 U-Boot / 内核日志）
    退出本程序：Ctrl+]

  维护提示：PowerShell 5.1 按 ANSI 代码页读 .ps1，所以这份文件带 UTF-8 BOM。
  改完请确认 BOM 还在（无 BOM + 中文 = 解析器丢 token，2026-10 已经踩过一次）。
#>
param(
  [Parameter(Position = 0)]
  [string]$Port = 'auto',
  [Parameter(Position = 1)]
  [int]   $Baud = 921600,
  [string]$Log,
  [switch]$TimeStamp,
  [switch]$NoInput,
  [switch]$Echo,
  [switch]$Append,
  [int]   $Duration    = 0,
  [int]   $WaitPortSec = 0,
  [switch]$NoTimeSync,
  [switch]$AlwaysKeys
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- helpers
$script:AnsiRe = [regex]("\x1b\[[0-9;<=>?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[\x30-\x7e]")
function Strip-Ansi([string]$s) { return $script:AnsiRe.Replace($s, '') }

# 串口流的尾巴是不是停在 shell 提示符上（"root@linux:~# " / "[root@host ~]$ " 之类）
function Test-PromptTail([string]$s) {
  $t = Strip-Ansi $s
  $i = $t.LastIndexOf("`n")
  if ($i -ge 0) { $t = $t.Substring($i + 1) }
  if ($t.Length -gt 120) { return $false }
  return ($t -match '[#$]\s*$')
}
# 尾巴是不是停在 login:/Password: 上（板子刚起来，或刚退出登录）
function Test-LoginTail([string]$s) {
  $t = Strip-Ansi $s
  return ($t -match '(login:|Password:)\s*$')
}

# ---------------------------------------------------------------- port
# 端口自动识别：CH340 换 USB 口/重启后会重排（COM3 -> COM5 ...）。
. (Join-Path $PSScriptRoot 'serial-port.ps1')

# ---------------------------------------------------------------- log file
if (-not $Log) {
  $logDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\logs'))
  if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
  $Log = Join-Path $logDir ("serial-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
} else {
  $logDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($Log))
  if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
}

$sp = New-Object System.IO.Ports.SerialPort
$sp.BaudRate  = $Baud
$sp.Parity    = [System.IO.Ports.Parity]::None
$sp.DataBits  = 8
$sp.StopBits  = [System.IO.Ports.StopBits]::One
$sp.Handshake = [System.IO.Ports.Handshake]::None
$sp.DtrEnable = $false
$sp.RtsEnable = $false
$sp.ReadTimeout = 200
$sp.Encoding  = New-Object System.Text.UTF8Encoding $false

$deadline = (Get-Date).AddSeconds([Math]::Max(0, $WaitPortSec))
$busySince = $null
while ($true) {
  try {
    $Port = Resolve-SerialPort $Port
    $sp.PortName = $Port
    $sp.Open()
    break
  } catch {
    $msg = $_.Exception.Message
    # "port is not there yet" (keep waiting) and "port is there but busy"
    # (another window holds it - waiting will not help) are different problems.
    $found = ($sp.PortName -and ([System.IO.Ports.SerialPort]::GetPortNames() -contains $sp.PortName))
    if ($found) {
      if (-not $busySince) { $busySince = Get-Date }
      if (((Get-Date) - $busySince).TotalSeconds -gt 5) {
        Write-Host ("{0} 存在但打不开（多半被其它程序占用）：{1}" -f $sp.PortName, $msg) -ForegroundColor Red
        Write-Host "关掉 putty / SecureCRT / 另一个 watch-serial / fogccc.bat 再试。" -ForegroundColor Yellow
        exit 1
      }
    } else {
      $busySince = $null
    }
    if ((Get-Date) -ge $deadline) {
      Write-Host ("无法打开串口：{0}" -f $msg) -ForegroundColor Red
      Write-Host ("当前系统端口：{0}。检查 USB 线/驱动，或用 -Port COMx 指定。" -f ([System.IO.Ports.SerialPort]::GetPortNames() -join ', ')) -ForegroundColor Yellow
      exit 1
    }
    Start-Sleep -Milliseconds 500
  }
}

$sw = New-Object System.IO.StreamWriter($Log, $Append.IsPresent, (New-Object System.Text.UTF8Encoding $false))
# AutoFlush=true 会让每一小段串口数据都触发一次磁盘 flush，粘贴时明显卡顿；
# 改成每秒 flush（见主循环），退出时也 flush。
$sw.AutoFlush = $false

# Ctrl+C 交给目标板，不杀本脚本；退出用 Ctrl+]
$ctrlCAsInput = $false
if (-not $NoInput) {
  try { [Console]::TreatControlCAsInput = $true; $ctrlCAsInput = $true } catch { }
}

# 启动只留一行：当前串口号 + 波特率。其余提示（模式/时钟/按键/日志路径/分隔线）
# 按用户要求全部去掉；出错时照旧报错（见上面的端口等待与打开失败分支）。
Write-Host ("{0} @ {1}" -f $Port, $Baud) -ForegroundColor DarkGray

# ---------------------------------------------------------------- state
$clock     = [System.Diagnostics.Stopwatch]::StartNew()
$lineBuf   = New-Object System.Text.StringBuilder   # -TimeStamp 用
$tail      = New-Object System.Text.StringBuilder   # 提示符 / login 检测用的尾部窗口
$canInput  = $true
$quit      = $false
$lastRxAt  = [datetime]::Now
$lastKeyAt = [datetime]::MinValue
$lastFlush = [datetime]::Now

$timeSyncOn = -not $NoTimeSync
$timeArmed  = $timeSyncOn      # 每次开机/登录后重新武装
$timeDone   = $false
$promptOk   = $false           # 尾巴停在 shell 提示符上
$keysOn     = [bool]$AlwaysKeys

try {
  while (-not $quit) {
    if ($Duration -gt 0 -and $clock.Elapsed.TotalSeconds -ge $Duration) { break }
    $now = [datetime]::Now

    # ---------------- serial in ----------------
    $chunk = ''
    try { $chunk = $sp.ReadExisting() } catch { }
    if ($chunk.Length -gt 0) {
      $lastRxAt = $now

      if ($TimeStamp) {
        foreach ($c in $chunk.ToCharArray()) {
          if ($c -eq "`n" -or $c -eq "`r") {
            if ($lineBuf.Length -gt 0) {
              $ts = ('[+{0,8:N3}s] ' -f $clock.Elapsed.TotalSeconds)
              [Console]::Write($ts + $lineBuf.ToString() + "`r`n")
              $sw.Write($ts + $lineBuf.ToString() + "`n")
              [void]$lineBuf.Clear()
            }
          } else { [void]$lineBuf.Append($c) }
        }
      } else {
        [Console]::Write($chunk)
        $sw.Write($chunk)
      }

      [void]$tail.Append($chunk)
      if ($tail.Length -gt 400) { [void]$tail.Remove(0, $tail.Length - 400) }
      $tailS = $tail.ToString()

      if (Test-LoginTail $tailS) {
        # 板子刚起来（或刚退出登录）：键盘解锁，时钟同步重新武装
        $promptOk  = $false
        $keysOn    = $true
        $timeArmed = $timeSyncOn
        $timeDone  = $false
      } elseif (Test-PromptTail $tailS) {
        $promptOk = $true
        if (-not $keysOn) { $keysOn = $true }
      }
    }

    # ---------------- keyboard out ----------------
    if (-not $NoInput -and $canInput -and $keysOn) {
      try {
        while ([Console]::KeyAvailable) {
          $k = [Console]::ReadKey($true)
          $lastKeyAt = [datetime]::Now

          if ($k.KeyChar -eq [char]0x1D) { $quit = $true; break }   # Ctrl+]

          switch ($k.Key) {
            'Enter'      { $sp.Write("`r");            if ($Echo) { [Console]::Write("`r`n") } }
            'Backspace'  { $sp.Write([string][char]8); if ($Echo) { [Console]::Write("`b `b") } }
            'Escape'     { $sp.Write([string][char]27) }
            'UpArrow'    { $sp.Write("`e[A");          if ($Echo) { [Console]::Write('<up>') } }
            'DownArrow'  { $sp.Write("`e[B");          if ($Echo) { [Console]::Write('<down>') } }
            'LeftArrow'  { $sp.Write("`e[D") }
            'RightArrow' { $sp.Write("`e[C") }
            'Tab'        { $sp.Write([string][char]9);  if ($Echo) { [Console]::Write("`t") } }
            default {
              if ($k.KeyChar -ne [char]0) {
                $sp.Write([string]$k.KeyChar)
                if ($Echo) { [Console]::Write($k.KeyChar) }
              }
            }
          }
        }
      } catch [System.InvalidOperationException] { $canInput = $false }
    }

    # 开机阶段不转发按键，免得手一抖打断 U-Boot 自启动；
    # 但如果控制台是在板子起来之后才启动的（串口一直没数据），10 秒后也得解锁，
    # 否则就永远敲不进去了（和 fogccc.bat 的旧行为一致）。解锁本身不出提示。
    if (-not $keysOn -and -not $NoInput -and ($now - $lastRxAt).TotalSeconds -gt 10) {
      $keysOn = $true
    }

    # ---------------- host clock -> board ----------------
    # 只在“确认处于 shell 提示符”+“本地键盘和串口都空闲”时发一次；
    # 绝不往 login: 或 U-Boot 提示符里打字。
    if ($timeArmed -and -not $timeDone -and $promptOk -and
        ($now - $lastKeyAt).TotalMilliseconds -gt 1500 -and
        ($now - $lastRxAt).TotalMilliseconds  -gt 800) {
      $utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
      $timeDone  = $true
      $timeArmed = $false
      $sp.Write("date -s '$utc'`r")   # 静默注入：不打印任何提示
    }

    # ---------------- log flush ----------------
    if (($now - $lastFlush).TotalMilliseconds -ge 1000) {
      $lastFlush = $now
      try { $sw.Flush() } catch { }
    }

    Start-Sleep -Milliseconds 12
  }
} finally {
  if ($lineBuf.Length -gt 0) {
    [Console]::Write($lineBuf.ToString() + "`r`n")
    $sw.Write($lineBuf.ToString() + "`n")
  }
  $sw.Flush(); $sw.Close()
  if ($sp.IsOpen) { $sp.Close() }
  if ($ctrlCAsInput) { try { [Console]::TreatControlCAsInput = $false } catch { } }
  $sp.Dispose()
}
