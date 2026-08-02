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
$InstallSucceeded = $false

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

function Invoke-SourceFallback {
    param([Parameter(Mandatory)][string]$InstallerPath)

    Write-SirkWarning 'No release ZIP is available. Building SIRK Updater from source.'
    Write-SirkWarning 'This can take several minutes on a fresh Windows installation.'

    $stdoutPath = Join-Path $WorkRoot 'source-build.stdout.log'
    $stderrPath = Join-Path $WorkRoot 'source-build.stderr.log'
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $InstallerPath)
    )

    $process = Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList $arguments `
        -PassThru `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath

    $started = Get-Date
    while (-not $process.HasExited) {
        Start-Sleep -Seconds 5
        $process.Refresh()
        $elapsed = (Get-Date) - $started
        $cpu = try { [Math]::Round($process.TotalProcessorTime.TotalSeconds, 1) } catch { 0 }
        $phase = 'working'
        if (Test-Path -LiteralPath $stdoutPath) {
            $lastLine = Get-Content -LiteralPath $stdoutPath -Tail 1 -ErrorAction SilentlyContinue
            if ($lastLine) { $phase = ($lastLine -replace '\s+', ' ').Trim() }
            if ($phase.Length -gt 80) { $phase = $phase.Substring(0, 80) + '...' }
        }
        Write-Host ("[BUILD] {0:hh\:mm\:ss} | CPU {1:N1}s | {2}" -f $elapsed, $cpu, $phase) -ForegroundColor DarkCyan
    }

    $process.WaitForExit()
    $process.Refresh()
    $exitCode = [int]$process.ExitCode

    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue } else { '' }

    if ($exitCode -ne 0) {
        Write-SirkError "Source bootstrap failed with ExitCode=$exitCode."
        if ($stdout) {
            Write-Host "`n--- source build stdout (last 80 lines) ---" -ForegroundColor Yellow
            Get-Content -LiteralPath $stdoutPath -Tail 80 | Out-Host
        }
        if ($stderr) {
            Write-Host "`n--- source build stderr (last 80 lines) ---" -ForegroundColor Red
            Get-Content -LiteralPath $stderrPath -Tail 80 | Out-Host
        }
        throw "Source bootstrap failed with ExitCode=$exitCode. Work directory retained: $WorkRoot"
    }

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $cli = Join-Path $InstallRoot 'SirkUpdater.exe'
    if (-not $service -or $service.Status -ne 'Running' -or -not (Test-Path -LiteralPath $cli)) {
        if ($stdout) {
            Write-Host "`n--- source build stdout (last 80 lines) ---" -ForegroundColor Yellow
            Get-Content -LiteralPath $stdoutPath -Tail 80 | Out-Host
        }
        if ($stderr) {
            Write-Host "`n--- source build stderr (last 80 lines) ---" -ForegroundColor Red
            Get-Content -LiteralPath $stderrPath -Tail 80 | Out-Host
        }
        throw "Source bootstrap returned success, but SIRK Updater is not healthy. Work directory retained: $WorkRoot"
    }

    Write-SirkOk 'SIRK Updater source build completed and service is running.'
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
        $fallback = Join-Path $WorkRoot 'install-source.ps1'
        Invoke-SirkDownload -Uri 'https://raw.githubusercontent.com/Eris92/SIRK-Updater/main/install.ps1' -Destination $fallback -DisplayName 'SIRK Updater source installer'
        Invoke-SourceFallback -InstallerPath $fallback
        $InstallSucceeded = $true
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
    $InstallSucceeded = $true
}
catch {
    if (Get-Command Write-SirkError -ErrorAction SilentlyContinue) { Write-SirkError $_.Exception.Message }
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
