#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$Version
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$InstallRoot = Join-Path $env:ProgramFiles 'SIRK\Updater'
$DataRoot = Join-Path $env:ProgramData 'SIRK\Updater'
$LogRoot = Join-Path $env:ProgramData 'SIRK\Logs'
$ServiceName = 'SirkUpdater'
$WorkRoot = Join-Path $env:TEMP ('SIRK-Updater-Release-v2-' + [guid]::NewGuid().ToString('N'))
$BackupRoot = Join-Path $DataRoot 'installer-backups'
$LogPath = Join-Path $LogRoot 'Updater-Install.log'
$InstallSucceeded = $false
$BackupPath = $null

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','OK','WARNING','ERROR')][string]$Level = 'INFO',
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    $line = "{0:o} [{1}] {2}" -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Host "[$Level] $Message" -ForegroundColor $Color
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha256.ComputeHash($stream)
            return (-join @($hashBytes | ForEach-Object { $_.ToString('x2') }))
        }
        finally {
            $sha256.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-GitHubApiHeaders {
    $headers = @{
        'User-Agent' = 'SIRK-Updater-Installer-v2'
        'Accept' = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    $token = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $env:GITHUB_TOKEN.Trim()
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        $env:GH_TOKEN.Trim()
    }
    else {
        ''
    }
    if ($token) { $headers.Authorization = "Bearer $token" }
    return $headers
}

function Get-ReleaseMetadata {
    $headers = Get-GitHubApiHeaders
    if ($Version) {
        $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
        return Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/Eris92/SIRK-Updater/releases/tags/$tag"
    }
    return Invoke-RestMethod -Headers $headers -Uri 'https://api.github.com/repos/Eris92/SIRK-Updater/releases/latest'
}

function Assert-DotNet10Runtime {
    $dotnet = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if (-not $dotnet) { throw 'dotnet.exe is unavailable. Install Microsoft .NET 10 Runtime or SDK.' }

    $runtimes = & $dotnet.Source --list-runtimes
    if ($LASTEXITCODE -ne 0) { throw 'Unable to query installed .NET runtimes.' }
    if (-not ($runtimes | Where-Object { $_ -match '^Microsoft\.NETCore\.App 10\.0\.' })) {
        throw 'Microsoft.NETCore.App 10.0 runtime is required.'
    }
    Write-Log 'Microsoft.NETCore.App 10.0 runtime detected.' 'OK' Green
}

function Remove-ServiceRegistration {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) { return }

    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name $ServiceName -Force -ErrorAction Stop
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

function Install-ServiceFromRoot {
    param([Parameter(Mandatory)][string]$Root)

    $serviceExe = Join-Path $Root 'SirkUpdater.Service.exe'
    if (-not (Test-Path -LiteralPath $serviceExe)) {
        throw "Service executable is missing: $serviceExe"
    }

    New-Service `
        -Name $ServiceName `
        -BinaryPathName ('"{0}"' -f $serviceExe) `
        -DisplayName 'SIRK Updater' `
        -Description 'Transactional update service for SIRK Portal and SIRK Agent.' `
        -StartupType Automatic | Out-Null

    & sc.exe failure $ServiceName 'reset= 86400' 'actions= restart/5000/restart/15000/restart/60000' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to configure SIRK Updater recovery actions.' }

    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
}

function Restore-Backup {
    if (-not $BackupPath -or -not (Test-Path -LiteralPath $BackupPath)) { return }

    Write-Log "Restoring previous Updater binaries from $BackupPath" 'WARNING' Yellow
    Remove-ServiceRegistration
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $BackupPath -Destination $InstallRoot -Force
    Install-ServiceFromRoot -Root $InstallRoot
    Write-Log 'Previous SIRK Updater version restored and running.' 'OK' Green
}

try {
    New-Item -ItemType Directory -Path $WorkRoot, $DataRoot, $BackupRoot, $LogRoot -Force | Out-Null

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ' SIRK Updater Release Installer v2' -ForegroundColor Cyan
    Write-Host ' Verified package only | .NET 10 | Transactional rollback' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan

    Assert-DotNet10Runtime

    Write-Log 'Resolving GitHub Release metadata.' 'INFO' Cyan
    $release = Get-ReleaseMetadata
    Write-Log "Release resolved: $($release.tag_name)" 'OK' Green

    $zipAssets = @($release.assets | Where-Object name -match '^SIRK-Updater-.+-win-x64\.zip$')
    if ($zipAssets.Count -ne 1) {
        throw "Release must contain exactly one Windows ZIP. Found=$($zipAssets.Count)"
    }
    $zipAsset = $zipAssets[0]

    $hashAssets = @($release.assets | Where-Object name -eq ($zipAsset.name + '.sha256'))
    if ($hashAssets.Count -ne 1) {
        throw 'Release does not contain a matching SHA-256 manifest.'
    }
    $hashAsset = $hashAssets[0]

    if ([int64]$zipAsset.size -gt 15MB) {
        throw "Release package exceeds 15 MB: $([Math]::Round([int64]$zipAsset.size / 1MB, 2)) MB"
    }

    $zipPath = Join-Path $WorkRoot $zipAsset.name
    $hashPath = Join-Path $WorkRoot $hashAsset.name
    Write-Log "Downloading $($zipAsset.name) ($([Math]::Round([int64]$zipAsset.size / 1MB, 2)) MB)." 'INFO' Cyan
    Invoke-WebRequest -UseBasicParsing -Uri $zipAsset.browser_download_url -OutFile $zipPath
    Invoke-WebRequest -UseBasicParsing -Uri $hashAsset.browser_download_url -OutFile $hashPath

    $expectedHash = ((Get-Content -LiteralPath $hashPath -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $actualHash = Get-Sha256Hex -Path $zipPath
    if ([string]::IsNullOrWhiteSpace($expectedHash) -or $actualHash -ne $expectedHash) {
        throw "SHA-256 mismatch. Expected=$expectedHash Actual=$actualHash"
    }
    Write-Log "SHA-256 verified: $actualHash" 'OK' Green

    $payload = Join-Path $WorkRoot 'payload'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $payload -Force

    $requiredFiles = @(
        'SirkUpdater.Service.exe',
        'SirkUpdater.Service.dll',
        'SirkUpdater.Service.runtimeconfig.json',
        'SirkUpdater.exe',
        'SirkUpdater.Cli.dll',
        'SirkUpdater.Cli.runtimeconfig.json',
        'SirkUpdater.Core.dll',
        'release-manifest.json'
    )
    foreach ($file in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $payload $file))) {
            throw "Release payload is missing: $file"
        }
    }

    foreach ($forbidden in @('coreclr.dll','hostfxr.dll','hostpolicy.dll','clrjit.dll','System.Private.CoreLib.dll')) {
        if (Test-Path -LiteralPath (Join-Path $payload $forbidden)) {
            throw "Self-contained runtime file is forbidden: $forbidden"
        }
    }

    $manifest = Get-Content -LiteralPath (Join-Path $payload 'release-manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.applicationId -ne 'sirk-updater') { throw 'Invalid release applicationId.' }
    if ($manifest.architecture -ne 'win-x64') { throw 'Invalid release architecture.' }
    if ($manifest.deploymentMode -ne 'framework-dependent') { throw 'Only framework-dependent releases are supported.' }
    if ($manifest.targetFramework -ne 'net10.0') { throw 'Only net10.0 releases are supported.' }
    if ($manifest.requiredRuntime -ne 'Microsoft.NETCore.App 10.0') { throw 'Invalid requiredRuntime in release manifest.' }
    Write-Log "Payload validated: version $($manifest.version)." 'OK' Green

    Remove-ServiceRegistration

    if (Test-Path -LiteralPath $InstallRoot) {
        $BackupPath = Join-Path $BackupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
        Move-Item -LiteralPath $InstallRoot -Destination $BackupPath -Force
        Write-Log "Previous binaries backed up: $BackupPath" 'OK' Green
    }

    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    Copy-Item -Path (Join-Path $payload '*') -Destination $InstallRoot -Recurse -Force

    Install-ServiceFromRoot -Root $InstallRoot

    $cliPath = Join-Path $InstallRoot 'SirkUpdater.exe'
    if (-not (Test-Path -LiteralPath $cliPath)) { throw 'Installed CLI is missing.' }
    & $cliPath list | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Installed CLI self-test failed. ExitCode=$LASTEXITCODE" }

    $service = Get-Service -Name $ServiceName
    if ($service.Status -ne 'Running') { throw 'SIRK Updater service is not running.' }

    $InstallSucceeded = $true
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host ' SIRK UPDATER INSTALLATION COMPLETED' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host "Version : $($manifest.version)" -ForegroundColor Cyan
    Write-Host "Service : $($service.Status)" -ForegroundColor Green
    Write-Host "CLI     : $cliPath" -ForegroundColor Cyan
    Write-Host 'SIRK_UPDATER_RELEASE_V2_OK' -ForegroundColor Green
}
catch {
    Write-Log $_.Exception.Message 'ERROR' Red
    try { Restore-Backup } catch { Write-Log "Rollback failed: $($_.Exception.Message)" 'ERROR' Red }
    throw
}
finally {
    if ($InstallSucceeded) {
        Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    elseif (Test-Path -LiteralPath $WorkRoot) {
        Write-Host "[DIAGNOSTICS] Work directory retained: $WorkRoot" -ForegroundColor Yellow
    }
}
