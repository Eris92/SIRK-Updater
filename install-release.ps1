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
$FrameworkPath = Join-Path $WorkRoot 'SirkInstaller.Console.psm1'
$LogPath = 'C:\ProgramData\SIRK\Logs\Updater-Install.log'
$TotalSteps = 7

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
    if (-not $service) { return }
    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name $ServiceName -Force
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    & sc.exe delete $ServiceName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to delete previous SIRK Updater service.' }
    for ($i = 0; $i -lt 30; $i++) {
        if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Seconds 1
    }
    throw 'SIRK Updater service is pending deletion. Restart Windows and retry.'
}

try {
    New-Item -ItemType Directory -Path $WorkRoot, $DataRoot -Force | Out-Null
    Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/Eris92/SIRK-Updater/main/tools/install/SirkInstaller.Console.psm1?nocache=' + [guid]::NewGuid()) -OutFile $FrameworkPath
    Import-Module $FrameworkPath -Force
    Initialize-SirkInstallerConsole -Component 'SIRK Updater' -Version $(if ($Version) { $Version } else { 'latest' }) -Channel 'stable' -LogPath $LogPath

    Write-SirkStep 1 $TotalSteps 'Resolve release metadata'
    try {
        $release = Get-ReleaseMetadata
        Write-SirkOk "Release resolved: $($release.tag_name)"
    }
    catch {
        if (-not $AllowSourceFallback) { throw }
        Write-SirkWarning 'No usable GitHub release found. Falling back to source bootstrap.'
        $fallback = Join-Path $WorkRoot 'install-source.ps1'
        Invoke-SirkDownload -Uri 'https://raw.githubusercontent.com/Eris92/SIRK-Updater/main/install.ps1' -Destination $fallback -DisplayName 'SIRK Updater source installer'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fallback
        if ($LASTEXITCODE -ne 0) { throw "Source bootstrap failed with ExitCode=$LASTEXITCODE." }
        return
    }

    Write-SirkStep 2 $TotalSteps 'Validate release assets'
    $zipAsset = @($release.assets | Where-Object name -match '^SIRK-Updater-.+-win-x64\.zip$' | Select-Object -First 1)
    $hashAsset = @($release.assets | Where-Object name -eq ($zipAsset.name + '.sha256') | Select-Object -First 1)
    if ($zipAsset.Count -ne 1 -or $hashAsset.Count -ne 1) {
        throw 'Release does not contain exactly one Windows ZIP and matching SHA256 file.'
    }
    Write-SirkOk "Assets validated: $($zipAsset[0].name)"

    Write-SirkStep 3 $TotalSteps 'Download SIRK Updater package'
    $zipPath = Join-Path $WorkRoot $zipAsset[0].name
    $hashPath = Join-Path $WorkRoot $hashAsset[0].name
    Invoke-SirkDownload -Uri $zipAsset[0].browser_download_url -Destination $zipPath -DisplayName 'SIRK Updater'
    Invoke-SirkDownload -Uri $hashAsset[0].browser_download_url -Destination $hashPath -DisplayName 'SHA-256 manifest'

    Write-SirkStep 4 $TotalSteps 'Verify package integrity'
    $expected = ((Get-Content -LiteralPath $hashPath -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not $expected -or $actual -ne $expected) {
        throw "SIRK Updater checksum mismatch. Expected=$expected Actual=$actual"
    }
    Write-SirkOk "SHA-256 verified: $actual"

    Write-SirkStep 5 $TotalSteps 'Extract and validate payload'
    $payload = Join-Path $WorkRoot 'payload'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $payload -Force
    $serviceExe = Join-Path $payload 'SirkUpdater.Service.exe'
    $cliExe = Join-Path $payload 'SirkUpdater.exe'
    $manifest = Join-Path $payload 'release-manifest.json'
    foreach ($required in @($serviceExe, $cliExe, $manifest)) {
        if (-not (Test-Path -LiteralPath $required)) { throw "Release payload is incomplete: $required" }
    }
    Write-SirkOk 'Release payload validated.'

    Write-SirkStep 6 $TotalSteps 'Install Windows service'
    Remove-ExistingService
    if (Test-Path -LiteralPath $InstallRoot) {
        $backup = Join-Path $DataRoot ('installer-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Move-Item -LiteralPath $InstallRoot -Destination $backup -Force
        Write-SirkOk "Previous binaries backed up: $backup"
    }
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    Copy-Item -Path (Join-Path $payload '*') -Destination $InstallRoot -Recurse -Force

    $installedServiceExe = Join-Path $InstallRoot 'SirkUpdater.Service.exe'
    New-Service -Name $ServiceName -BinaryPathName ('"{0}"' -f $installedServiceExe) -DisplayName 'SIRK Updater' -Description 'Transactional update service for SIRK Portal and SIRK Agent.' -StartupType Automatic | Out-Null
    & sc.exe failure $ServiceName 'reset= 86400' 'actions= restart/5000/restart/15000/restart/60000' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to configure SIRK Updater recovery actions.' }
    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    Write-SirkOk 'SIRK Updater service installed and running.'

    Write-SirkStep 7 $TotalSteps 'Verify installation and prepare summary'
    $installedManifest = Get-Content -LiteralPath (Join-Path $InstallRoot 'release-manifest.json') -Raw | ConvertFrom-Json
    $service = Get-Service -Name $ServiceName
    $cliPath = Join-Path $InstallRoot 'SirkUpdater.exe'
    [void](Copy-SirkValue -Value $cliPath -Label 'CLI path')
    Show-SirkInstallationSummary -Values ([ordered]@{
        'Service' = [string]$service.Status
        'Version' = [string]$installedManifest.version
        'CLI' = $cliPath
        'Install root' = $InstallRoot
        'Data root' = $DataRoot
    }) -SuccessCode 'SIRK_UPDATER_RELEASE_INSTALL_OK'
}
catch {
    if (Get-Command Write-SirkError -ErrorAction SilentlyContinue) { Write-SirkError $_.Exception.Message }
    throw
}
finally {
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}
