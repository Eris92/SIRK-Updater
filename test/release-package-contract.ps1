#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServicePublish,
    [Parameter(Mandatory)][string]$CliPublish,
    [Parameter(Mandatory)][string]$PackagePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($path in @($ServicePublish, $CliPublish, $PackagePath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing test input: $path"
    }
}

$serviceRuntime = Get-Content -LiteralPath (Join-Path $ServicePublish 'SirkUpdater.Service.runtimeconfig.json') -Raw | ConvertFrom-Json
$cliRuntime = Get-Content -LiteralPath (Join-Path $CliPublish 'SirkUpdater.Cli.runtimeconfig.json') -Raw | ConvertFrom-Json

foreach ($runtime in @($serviceRuntime, $cliRuntime)) {
    if ($runtime.runtimeOptions.tfm -ne 'net10.0') {
        throw "Unexpected target framework: $($runtime.runtimeOptions.tfm)"
    }

    $framework = $runtime.runtimeOptions.framework
    if (-not $framework) {
        $framework = @($runtime.runtimeOptions.frameworks | Where-Object name -eq 'Microsoft.NETCore.App' | Select-Object -First 1)
    }

    if (-not $framework -or -not ([string]$framework.version).StartsWith('10.0')) {
        throw 'Package does not require Microsoft.NETCore.App 10.0.'
    }
}

$forbiddenRuntimeFiles = @(
    'coreclr.dll',
    'hostfxr.dll',
    'hostpolicy.dll',
    'clrjit.dll',
    'System.Private.CoreLib.dll'
)

foreach ($root in @($ServicePublish, $CliPublish)) {
    foreach ($file in $forbiddenRuntimeFiles) {
        if (Test-Path -LiteralPath (Join-Path $root $file)) {
            throw "Self-contained runtime file detected: $file"
        }
    }
}

$sizeMb = [Math]::Round((Get-Item -LiteralPath $PackagePath).Length / 1MB, 2)
if ($sizeMb -gt 15) {
    throw "Release package exceeds 15 MB: $sizeMb MB"
}

$extract = Join-Path $env:RUNNER_TEMP ('sirk-updater-contract-' + [guid]::NewGuid().ToString('N'))
try {
    Expand-Archive -LiteralPath $PackagePath -DestinationPath $extract -Force

    $required = @(
        'SirkUpdater.Service.exe',
        'SirkUpdater.Service.dll',
        'SirkUpdater.Service.runtimeconfig.json',
        'SirkUpdater.exe',
        'SirkUpdater.Cli.dll',
        'SirkUpdater.Cli.runtimeconfig.json',
        'SirkUpdater.Core.dll',
        'release-manifest.json'
    )

    foreach ($file in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $extract $file))) {
            throw "Release package is missing: $file"
        }
    }

    $manifest = Get-Content -LiteralPath (Join-Path $extract 'release-manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.deploymentMode -ne 'framework-dependent') {
        throw "Invalid deploymentMode: $($manifest.deploymentMode)"
    }
    if ($manifest.targetFramework -ne 'net10.0') {
        throw "Invalid targetFramework: $($manifest.targetFramework)"
    }
    if ($manifest.requiredRuntime -ne 'Microsoft.NETCore.App 10.0') {
        throw "Invalid requiredRuntime: $($manifest.requiredRuntime)"
    }
}
finally {
    Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "SIRK_UPDATER_RELEASE_CONTRACT_OK size=$sizeMb MB"
