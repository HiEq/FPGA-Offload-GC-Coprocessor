param(
    [string]$Port = 'auto'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'serial-session.ps1')

function Show-Tail([int]$Lines = 20) {
    Get-BoardSerialTail -Session $script:s -Lines $Lines | ForEach-Object { "  | " + $_ }
}

$script:s = New-BoardSerialSession -Port $Port
Write-Host ("opened {0} @ {1}" -f $script:s.Port, $script:s.Baud)

Read-BoardSerial -Session $script:s -Ms 800
$script:s.Sp.Write("`r")
Read-BoardSerial -Session $script:s -Ms 1200

$tail = $script:s.Sb.ToString()
if ($tail -match 'root@linux') {
    Write-Host "board is already in FOGCCC"
} elseif ($tail -match 'zynq7100 login:') {
    Write-Host "Arch login detected; logging in as root/root"
    Write-BoardSerialLine -Session $script:s -Text "root" -SettleMs 1500
    Read-BoardSerial -Session $script:s -Ms 2500
    if ($script:s.Sb.ToString() -match 'Password:') {
        Write-BoardSerialLine -Session $script:s -Text "root" -SettleMs 1500
        Read-BoardSerial -Session $script:s -Ms 3000
    }
    if (-not (Read-BoardSerialUntil -Session $script:s -Pattern '#\s*$' -MaxMs 20000)) {
        Show-Tail 25
        throw "Arch login failed"
    }

    [void](Invoke-BoardSerialCommand -Session $script:s -Text "mount | grep mmcblk0p1" -WaitMs 8000)
    [void](Invoke-BoardSerialCommand -Session $script:s -Text "touch /boot/use-fogccc && sync" -WaitMs 8000)
    [void](Invoke-BoardSerialCommand -Session $script:s -Text "ls -l /boot/use-fogccc" -WaitMs 8000)
    Write-Host "rebooting into FOGCCC"
    Write-BoardSerialLine -Session $script:s -Text "reboot" -SettleMs 1000
    Read-BoardSerial -Session $script:s -Ms 2000

    if (-not (Read-BoardSerialUntil -Session $script:s -Pattern 'root@linux|linux login:' -MaxMs 180000)) {
        Show-Tail 60
        throw "FOGCCC did not come up after the reboot"
    }
    if ($script:s.Sb.ToString() -match 'linux login:') {
        Write-Host "FOGCCC login prompt; logging in as root with empty password"
        Write-BoardSerialLine -Session $script:s -Text "root" -SettleMs 1000
        Read-BoardSerial -Session $script:s -Ms 2500
        if ($script:s.Sb.ToString() -match 'Password:') {
            $script:s.Sp.Write("`r")
            Read-BoardSerial -Session $script:s -Ms 2500
        }
        if (-not (Read-BoardSerialUntil -Session $script:s -Pattern '#\s*$' -MaxMs 20000)) {
            Show-Tail 40
            throw "FOGCCC login failed"
        }
    }
    Write-Host "FOGCCC prompt detected"
} elseif ($tail -match 'linux login:') {
    Write-Host "FOGCCC login prompt; logging in as root with empty password"
    Write-BoardSerialLine -Session $script:s -Text "root" -SettleMs 1000
    Read-BoardSerial -Session $script:s -Ms 2500
    if ($script:s.Sb.ToString() -match 'Password:') {
        $script:s.Sp.Write("`r")
        Read-BoardSerial -Session $script:s -Ms 2500
    }
    if (-not (Read-BoardSerialUntil -Session $script:s -Pattern '#\s*$' -MaxMs 20000)) {
        Show-Tail 40
        throw "FOGCCC login failed"
    }
} else {
    Write-Host "unknown board state; tail:"
    Show-Tail 25
    throw "cannot determine whether the board is in Arch or FOGCCC"
}

Read-BoardSerial -Session $script:s -Ms 1000
[void](Invoke-BoardSerialCommand -Session $script:s -Text "uname -a" -WaitMs 8000)
[void](Invoke-BoardSerialCommand -Session $script:s -Text "ls /mnt/userdata | head -5" -WaitMs 8000)
[void](Invoke-BoardSerialCommand -Session $script:s -Text "cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || true" -WaitMs 8000)
Close-BoardSerialSession -Session $script:s
Write-Host "RESULT: FOGCCC_READY"