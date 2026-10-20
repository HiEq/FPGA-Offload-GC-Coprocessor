# Build the two card zips from artifacts/ (Windows tar, same layout as the
# published assets).
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$art  = Join-Path $root 'artifacts'
$tar  = Join-Path $env:SystemRoot 'System32\tar.exe'

$bootZip = Join-Path $art 'card-boot.zip'
$userZip = Join-Path $art 'card-userdata.zip'
Remove-Item $bootZip, $userZip -Force -ErrorAction SilentlyContinue

& $tar -a -c -f $bootZip -C $art boot.scr uEnv.txt mount_data.sh system.dtb
if ($LASTEXITCODE -ne 0) { throw 'card-boot.zip failed' }

& $tar -a -c -f $userZip -C (Join-Path $art 'userdata') `
    --exclude '__pycache__' --exclude '*.pyc' --exclude 'logs' .
if ($LASTEXITCODE -ne 0) { throw 'card-userdata.zip failed' }

foreach ($z in $bootZip, $userZip) {
    $i = Get-Item $z
    $h = (Get-FileHash $z -Algorithm SHA256).Hash.ToLower()
    Write-Host ("{0}  {1}  {2}" -f $i.Name, $i.Length, $h)
}
