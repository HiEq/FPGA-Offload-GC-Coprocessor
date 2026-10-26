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

$lines = @{}
foreach ($z in $bootZip, $userZip) {
    $i = Get-Item $z
    $h = (Get-FileHash $z -Algorithm SHA256).Hash.ToLower()
    Write-Host ("{0}  {1}  {2}" -f $i.Name, $i.Length, $h)
    $lines[$i.Name] = $h
}

# Keep the release manifest in step with the zips: a rebuilt zip with a stale
# hash in SHA256SUMS.release is indistinguishable from a corrupted download.
$manifest = Join-Path $art 'SHA256SUMS.release'
$want = @('BOOT.BIN', 'image.ub', 'card-boot.zip', 'card-userdata.zip')
$existing = @{}
if (Test-Path $manifest) {
    foreach ($line in Get-Content $manifest) {
        if ($line -match '^([0-9a-f]{64})\s+(\S+)$') { $existing[$Matches[2]] = $Matches[1] }
    }
}
foreach ($name in $lines.Keys) {
    if (-not $existing.ContainsKey($name) -or $existing[$name] -ne $lines[$name]) {
        $existing[$name] = $lines[$name]
    }
}
$out = foreach ($name in $want) {
    if (-not $existing.ContainsKey($name)) { throw "SHA256SUMS.release has no hash for $name" }
    '{0}  {1}' -f $existing[$name], $name
}
[IO.File]::WriteAllText($manifest, ($out -join "`n") + "`n", (New-Object Text.UTF8Encoding $false))
Write-Host 'SHA256SUMS.release refreshed'
