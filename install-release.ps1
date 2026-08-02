#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$Version,
    [switch]$AllowSourceFallback
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$InstallRoot = Join-Path $env:ProgramFiles 'SIRK\Updater'
$DataRoot = Join-Path $env:ProgramData 'SIRK\Updater'
$ServiceName = 'SirkUpdater'
$WorkRoot = Join-Path $env:TEMP ('SIRK-Updater-Release-' + [guid]::NewGuid().ToString('N'))

function Get-ReleaseMetadata {
    $headers = @{ 'User-Agent' = 'SIRK-Updater-Installer' }
    if ($Version) {
        $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
        return Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/Eris92/SIRK-Updater/releases/tags/$tag"
    }
    return Invoke-RestMethod -Headers $headers -Uri 'https://api.github.com/repos/Eris92/SIRK-Updater/releases/latest'
}

function Remove-ExistingService {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service) {
        if ($service.Status -ne 'Stopped') {
            Stop-Service -Name $ServiceName -Force
            $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }
        & sc.exe delete $ServiceName | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to delete previous SIRK Updater service.' }
        Start-Sleep -Seconds 2
    }
}

try {
    New-Item -ItemType Directory -Path $WorkRoot, $DataRoot -Force | Out-Null

    try {
        $release = Get-ReleaseMetadata
    }
    catch {
        if (-not $AllowSourceFallback) { throw }
        Write-Warning 'No usable GitHub release found. Falling back to source bootstrap.'
        $fallback = Join-Path $WorkRoot 'install-source.ps1'
        Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/Eris92/SIRK-Updater/main/install.ps1?nocache=' + [guid]::NewGuid()) -OutFile $fallback
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fallback
        if ($LASTEXITCODE -ne 0) { throw "Source bootstrap failed with ExitCode=$LASTEXITCODE." }
        return
    }

    $zipAsset = @($release.assets | Where-Object name -match '^SIRK-Updater-.+-win-x64\.zip$' | Select-Object -First 1)
    $hashAsset = @($release.assets | Where-Object name -eq ($zipAsset.name + '.sha256') | Select-Object -First 1)
    if ($zipAsset.Count -ne 1 -or $hashAsset.Count -ne 1) {
        throw 'Release does not contain exactly one Windows ZIP and matching SHA256 file.'
    }

    $zipPath = Join-Path $WorkRoot $zipAsset[0].name
    $hashPath = Join-Path $WorkRoot $hashAsset[0].name
    Invoke-WebRequest -UseBasicParsing -Uri $zipAsset[0].browser_download_url -OutFile $zipPath
    Invoke-WebRequest -UseBasicParsing -Uri $hashAsset[0].browser_download_url -OutFile $hashPath

    $expected = ((Get-Content -LiteralPath $hashPath -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not $expected -or $actual -ne $expected) {
        throw "SIRK Updater checksum mismatch. Expected=$expected Actual=$actual"
    }

    $payload = Join-Path $WorkRoot 'payload'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $payload -Force
    $serviceExe = Join-Path $payload 'SirkUpdater.Service.exe'
    $cliExe = Join-Path $payload 'SirkUpdater.exe'
    $manifest = Join-Path $payload 'release-manifest.json'
    foreach ($required in @($serviceExe, $cliExe, $manifest)) {
        if (-not (Test-Path -LiteralPath $required)) { throw "Release payload is incomplete: $required" }
    }

    Remove-ExistingService

    if (Test-Path -LiteralPath $InstallRoot) {
        $backup = Join-Path $DataRoot ('installer-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Move-Item -LiteralPath $InstallRoot -Destination $backup -Force
        Write-Host "Previous binaries: $backup"
    }
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    Copy-Item -Path (Join-Path $payload '*') -Destination $InstallRoot -Recurse -Force

    $installedServiceExe = Join-Path $InstallRoot 'SirkUpdater.Service.exe'
    New-Service -Name $ServiceName -BinaryPathName ('"{0}"' -f $installedServiceExe) -DisplayName 'SIRK Updater' -Description 'Transactional update service for SIRK Portal and SIRK Agent.' -StartupType Automatic | Out-Null
    & sc.exe failure $ServiceName 'reset= 86400' 'actions= restart/5000/restart/15000/restart/60000' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to configure SIRK Updater recovery actions.' }

    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))

    Write-Host 'SIRK_UPDATER_RELEASE_INSTALL_OK'
    Get-Content -LiteralPath (Join-Path $InstallRoot 'release-manifest.json') -Raw
}
finally {
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}
