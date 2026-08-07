$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $root 'src/SirkUpdater.Core/ApplicationManifest.cs'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'ApplicationManifest.cs is missing.' }
$text = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
if (-not $text.Contains('CentralCacheSource = "sirk-central-cache"')) {
    throw 'SIRK Updater must recognize the explicit Central cache source.'
}
if (-not $text.Contains('UpdateSource == CentralCacheSource')) {
    throw 'SIRK Updater manifest validation must allow only the explicit Central cache marker or HTTPS bootstrap sources.'
}

$runtimeSources = Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -File -Include '*.cs' |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }
$joined = [string]::Join("`n", $runtimeSources)
foreach ($forbidden in @('api.github.com', 'raw.githubusercontent.com', 'github.com/Eris92/')) {
    if ($joined.Contains($forbidden, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Installed SIRK Updater runtime must not contain direct GitHub update source: $forbidden"
    }
}

Write-Host 'SIRK_UPDATER_CENTRAL_CACHE_CONTRACT_OK'
