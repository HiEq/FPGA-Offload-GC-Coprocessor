# Generate artifacts/SHA256SUMS for the binaries that ship on the card.
#
#   powershell -ExecutionPolicy Bypass -File tools/make_manifest.ps1
#   powershell -ExecutionPolicy Bypass -File tools/make_manifest.ps1 -Check
#
# The binaries are rebuilt on Linux; this manifest pins what is committed so a
# a stale binary is visible in a diff.
# CI runs -Check and fails when the manifest does not match the tree.
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $root 'artifacts/SHA256SUMS'
$files = @(
    'artifacts/userdata/bin/test_main',
    'artifacts/userdata/py/libfogccc.so',
    'artifacts/userdata/cmark'
)

$lines = @()
foreach ($rel in $files) {
    $abs = Join-Path $root $rel
    if (-not (Test-Path $abs)) { throw "missing: $rel" }
    $h = (Get-FileHash $abs -Algorithm SHA256).Hash.ToLower()
    $lines += "$h  $rel"
}
$text = ($lines -join "`n") + "`n"

if ($Check) {
    if (-not (Test-Path $out)) { Write-Host "manifest missing: $out"; exit 1 }
    $have = [System.IO.File]::ReadAllText($out) -replace "`r", ''
    if ($have -ne $text) {
        Write-Host "manifest is stale; rerun tools/make_manifest.ps1"
        Write-Host "--- expected ---"
        Write-Host $text
        Write-Host "--- found ---"
        Write-Host $have
        exit 1
    }
    Write-Host "SHA256SUMS matches the tree"
    exit 0
}

[System.IO.File]::WriteAllText($out, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "wrote $out"
Write-Host $text
