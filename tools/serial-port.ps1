# Resolve the ZYNQ board's USB-serial port.
#
# Why this file exists: the CH340 adapter (VID_1A86 / PID_7523) re-enumerates to a
# different COM number when the USB socket, the driver install or the Windows
# device instance changes (COM3 -> COM5 -> ...). Every script that hardcodes a
# port number breaks when that happens.
#
# Scripts default to -Port 'auto' and dot-source this file:
#     . (Join-Path $PSScriptRoot 'serial-port.ps1')
#     $Port = Resolve-SerialPort $Port
#
# Resolution order:
#   1. an explicit -Port COMx that really exists in the system
#   2. exactly one USB-serial (CH340) adapter present  -> that one
#   3. exactly one serial port at all                  -> that one
#   4. otherwise throw, listing what is present
#
# ASCII only on purpose: PowerShell 5.1 reads .ps1 files using the ANSI code page,
# so non-ASCII source bytes can corrupt the token stream (see serial-monitor.ps1
# history: UTF-8 without a BOM made the parser lose a Try/Catch pair).
# Keep every .ps1 ASCII-only or UTF-8 *with* a BOM.

function Resolve-SerialPort {
    param([string]$Requested = 'auto')

    $have = @([System.IO.Ports.SerialPort]::GetPortNames())

    # 1) explicit request wins if it is really there
    if ($Requested -and ($Requested -match '^COM\d+$')) {
        if ($have -contains $Requested) { return $Requested }
        Write-Host ("[serial] {0} is not present; auto-detecting (ports now: {1})" -f $Requested, ($have -join ', '))
    }

    # 2) the CH340 that the ZYNQ card uses
    $usb = @()
    foreach ($d in @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue)) {
        if ($d.DeviceID -match 'VID_1A86&PID_7523' -or $d.Name -match 'CH340|USB-SERIAL') {
            if ($d.Name -match '\((COM\d+)\)') {
                $p = $Matches[1]
                if (($have -contains $p) -and ($usb -notcontains $p)) { $usb += $p }
            }
        }
    }

    if ($usb.Count -eq 1) { return $usb[0] }
    if ($usb.Count -gt 1) {
        throw ("[serial] several USB-serial ports found: {0} - pass -Port COMx" -f ($usb -join ', '))
    }

    # 3) only one port on the machine at all
    if ($have.Count -eq 1) { return $have[0] }

    # 4) nothing usable
    $list = 'none'
    if ($have.Count -gt 0) { $list = ($have -join ', ') }
    throw ("[serial] no USB-serial port found (ports: {0})" -f $list)
}
