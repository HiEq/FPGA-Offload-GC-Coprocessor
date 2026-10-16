param(
    [string]$Port = "COM5",
    [int]$Baud = 115200,
    [string]$Log = "$PSScriptRoot\com5.log"
)

# simple raw serial console: plain scrolling text (easy to read / scroll back)
# keystrokes are forwarded to the board, everything is appended to $Log
$sp = New-Object -TypeName System.IO.Ports.SerialPort -ArgumentList @($Port, $Baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadBufferSize = 65536
$sp.WriteBufferSize = 65536
$sp.ReadTimeout = 100
try { $sp.Open() } catch { Write-Host "Failed to open $Port : $_"; Read-Host "press Enter"; exit 1 }

$sw = New-Object System.IO.StreamWriter($Log, $true)
$sw.AutoFlush = $true

Write-Host "======================================================================"
Write-Host " RAW serial console   $Port @ $Baud"
Write-Host "  - type here and it goes to the board"
Write-Host "  - Ctrl+C to quit"
Write-Host "  - everything is appended to: $Log"
Write-Host "======================================================================"

try {
    while ($true) {
        try {
            $d = $sp.ReadExisting()
            if ($d -and $d.Length -gt 0) { Write-Host $d -NoNewline; $sw.Write($d) }
        } catch {}
        try {
            while ([Console]::KeyAvailable) {
                $k  = [Console]::ReadKey($true)
                $ch = $k.KeyChar
                if     ($k.Key -eq [ConsoleKey]::Enter)     { $sp.Write("`n") }
                elseif ($k.Key -eq [ConsoleKey]::Backspace) { $sp.Write([char]8) }
                elseif ($k.Key -eq [ConsoleKey]::Tab)       { $sp.Write("`t") }
                elseif ($ch -ne [char]0)                    { $sp.Write([string]$ch) }
            }
        } catch {}
        Start-Sleep -Milliseconds 10
    }
}
finally {
    Write-Host ""
    Write-Host "=== console closed.  full log: $Log ==="
    try { $sw.Flush(); $sw.Close() } catch {}
    try { $sp.Close() } catch {}
}
