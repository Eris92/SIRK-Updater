#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$scriptPath = Join-Path $root 'install-release.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Missing installer: $scriptPath" }

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    throw ($errors | ForEach-Object Message | Out-String)
}

$text = Get-Content -LiteralPath $scriptPath -Raw
$required = @(
    'releases/latest',
    '.sha256',
    'Get-FileHash',
    'checksum mismatch',
    'release-manifest.json',
    'SirkUpdater.Service.exe',
    'SirkUpdater.exe',
    'New-Service',
    'SIRK_UPDATER_RELEASE_INSTALL_OK'
)
foreach ($needle in $required) {
    if ($text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Release installer contract is missing: $needle"
    }
}

Write-Host 'install-release-contract: OK'
