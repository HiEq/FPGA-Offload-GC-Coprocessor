# Regenerate artifacts/SHA256SUMS.release from the release assets in artifacts/.
# BOOT.BIN / image.ub are gitignored, so this file is the only in-repo record of
# their hashes; users compare it after downloading from the GitHub Release.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$art  = Join-Path $root 'artifacts'
$out  = Join-Path $art 'SHA256SUMS.release'

$names = @('BOOT.BIN', 'image.ub', 'card-boot.zip', 'card-userdata.zip')
$lines = @()
foreach ($n in $names) {
    $p = Join-Path $art $n
    if (-not (Test-Path $p)) { Write-Host "skip (missing): $n"; continue }
    $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower()
    $lines += "$h  $n"
}
if ($lines.Count -eq 0) { throw 'no release assets found in artifacts/' }
[IO.File]::WriteAllLines($out, $lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "wrote $out"
$lines | ForEach-Object { Write-Host "  $_" }
