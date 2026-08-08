$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $root 'src/SirkUpdater.Core/ApplicationManifest.cs'
$enginePath = Join-Path $root 'src/SirkUpdater.Core/TransactionalUpdateEngine.cs'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'ApplicationManifest.cs is missing.' }
if (-not (Test-Path -LiteralPath $enginePath)) { throw 'TransactionalUpdateEngine.cs is missing.' }
$text = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
$engine = Get-Content -LiteralPath $enginePath -Raw -Encoding UTF8
if (-not $text.Contains('CentralCacheSource = "sirk-central-cache"')) {
    throw 'SIRK Updater must recognize the explicit Central cache source.'
}
if (-not $text.Contains('string.Equals(UpdateSource, CentralCacheSource, StringComparison.Ordinal)')) {
    throw 'SIRK Updater manifest validation must explicitly recognize only the canonical Central cache marker.'
}
if (-not $text.Contains('source.Scheme != Uri.UriSchemeHttps')) {
    throw 'SIRK Updater manifest validation must reject non-HTTPS external bootstrap sources.'
}
if (-not $text.Contains('[JsonPropertyName("preserveFiles")]') -or
    -not $text.Contains('preserveFiles contains an invalid top-level relative file path.')) {
    throw 'SIRK Updater manifest must validate explicitly declared top-level mutable install files.'
}
if (-not $engine.Contains('ValidatePreservedFiles(payloadRoot, manifest.PreserveFiles);') -or
    -not $engine.Contains('MirrorDirectory(payloadRoot, manifest.InstallRoot, manifest.PreserveFiles);') -or
    -not $engine.Contains('MirrorDirectory(backupRoot, manifest.InstallRoot, manifest.PreserveFiles);') -or
    -not $engine.Contains('Update payload must not contain preserved install file:')) {
    throw 'SIRK Updater must leave mutable install files untouched and reject signed payload collisions.'
}
if (-not $engine.Contains('DeleteManagedEntry(entry);') -or
    -not $engine.Contains('FileAttributes.ReadOnly') -or
    -not $engine.Contains('CopyManagedFile(file, target);')) {
    throw 'SIRK Updater must normalize read-only managed payload files before replacement.'
}
if (-not $engine.Contains('if (!OperatingSystem.IsWindows())') -or
    -not $engine.Contains('FileMode.CreateNew') -or
    -not $engine.Contains('FileOptions.WriteThrough') -or
    -not $engine.Contains('input.CopyTo(output);')) {
    throw 'SIRK Updater Windows copies must create target files in place so they inherit the destination ACL instead of copying staging security descriptors.'
}
if (-not $engine.Contains('Run("sc.exe", ["queryex", name])') -or
    -not $engine.Contains('WaitForWindowsProcessExit(processId, TimeSpan.FromMinutes(2));') -or
    -not $engine.Contains('Process.GetProcessById(processId)')) {
    throw 'SIRK Updater must wait for the captured Windows service process to exit before replacing binaries.'
}
if (-not $engine.Contains('WindowsManagedDeleteRetryTimeout = TimeSpan.FromSeconds(10)') -or
    -not $engine.Contains('error is IOException or UnauthorizedAccessException') -or
    -not $engine.Contains('Thread.Sleep(100);')) {
    throw 'SIRK Updater must bound retries for transient Windows managed-file delete contention.'
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
