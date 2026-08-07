#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$scriptPath = Join-Path $root 'install-release-v2.ps1'
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
    'function Get-Sha256Hex',
    '[Security.Cryptography.SHA256]::Create()',
    '.ComputeHash(',
    'SHA-256 mismatch',
    'release-manifest.json',
    'framework-dependent',
    'net10.0',
    'Microsoft.NETCore.App 10.0',
    '15MB',
    'SirkUpdater.Service.exe',
    'SirkUpdater.exe',
    'New-Service',
    'Restore-Backup',
    'SIRK_UPDATER_RELEASE_V2_OK'
)
foreach ($needle in $required) {
    if ($text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Release installer v2 contract is missing: $needle"
    }
}

foreach ($needle in @(
    'Get-FileHash',
    ('AllowSource' + 'Fallback'),
    ('dotnet publish'),
    ('install' + '.ps1')
)) {
    if ($text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "Release installer v2 contains forbidden bootstrap dependency or legacy behavior: $needle"
    }
}

Write-Host 'install-release-contract: OK'
