#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('main','develop')]
    [string]$Channel = 'main'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$InstallRoot = Join-Path $env:ProgramFiles 'SIRK\Updater'
$DataRoot = Join-Path $env:ProgramData 'SIRK\Updater'
$WorkRoot = Join-Path $env:TEMP ('SIRK-Updater-Install-' + [Guid]::NewGuid().ToString('N'))
$SourceZip = Join-Path $WorkRoot 'source.zip'
$SourceRoot = Join-Path $WorkRoot 'source'
$DotnetRoot = Join-Path $WorkRoot 'dotnet'
$NugetConfig = Join-Path $WorkRoot 'NuGet.Config'
$ServiceName = 'SirkUpdater'

function Invoke-CheckedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [string]$WorkingDirectory = $PWD.Path
    )

    $stdout = Join-Path $WorkRoot ([Guid]::NewGuid().ToString('N') + '.stdout.log')
    $stderr = Join-Path $WorkRoot ([Guid]::NewGuid().ToString('N') + '.stderr.log')
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $outText = if (Test-Path $stdout) { Get-Content $stdout -Raw } else { '' }
    $errText = if (Test-Path $stderr) { Get-Content $stderr -Raw } else { '' }
    if ($process.ExitCode -ne 0) {
        throw "$FilePath failed with ExitCode=$($process.ExitCode).`n$outText`n$errText"
    }
    if ($outText) { Write-Host $outText.TrimEnd() }
    if ($errText) { Write-Verbose $errText.TrimEnd() }
}

try {
    Write-Host '=== SIRK Updater test installation ==='
    New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null

    $dotnetCommand = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    $dotnet = if ($dotnetCommand) { $dotnetCommand.Source } else { $null }
    if (-not $dotnet) {
        Write-Host '=== Install temporary .NET 8 SDK ==='
        $dotnetInstall = Join-Path $WorkRoot 'dotnet-install.ps1'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $dotnetInstall
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dotnetInstall -Channel 8.0 -Quality GA -InstallDir $DotnetRoot
        if ($LASTEXITCODE -ne 0) { throw 'Temporary .NET SDK installation failed.' }
        $dotnet = Join-Path $DotnetRoot 'dotnet.exe'
    }

    @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />
  </packageSources>
  <disabledPackageSources>
    <clear />
  </disabledPackageSources>
  <packageSourceMapping>
    <clear />
  </packageSourceMapping>
</configuration>
'@ | Set-Content -LiteralPath $NugetConfig -Encoding UTF8

    Write-Host '=== Download source ==='
    Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/Eris92/SIRK-Updater/zip/refs/heads/$Channel" -OutFile $SourceZip
    Expand-Archive -LiteralPath $SourceZip -DestinationPath $SourceRoot -Force
    $repository = Get-ChildItem $SourceRoot -Directory | Select-Object -First 1
    if (-not $repository) { throw 'Downloaded repository is empty.' }

    Write-Host '=== Restore from isolated NuGet source ==='
    $serviceProject = 'src\SirkUpdater.Service\SirkUpdater.Service.csproj'
    $cliProject = 'src\SirkUpdater.Cli\SirkUpdater.Cli.csproj'

    Invoke-CheckedProcess $dotnet @(
        'restore', $serviceProject,
        '--runtime', 'win-x64',
        '--configfile', $NugetConfig,
        '-p:PublishSingleFile=true'
    ) $repository.FullName

    Invoke-CheckedProcess $dotnet @(
        'restore', $cliProject,
        '--runtime', 'win-x64',
        '--configfile', $NugetConfig,
        '-p:PublishSingleFile=true'
    ) $repository.FullName

    Write-Host '=== Build self-contained binaries ==='
    $servicePublish = Join-Path $WorkRoot 'publish-service'
    $cliPublish = Join-Path $WorkRoot 'publish-cli'

    Invoke-CheckedProcess $dotnet @(
        'publish', $serviceProject,
        '-c', 'Release',
        '-r', 'win-x64',
        '--self-contained', 'true',
        '--no-restore',
        '-p:PublishSingleFile=true',
        '-p:DebugType=None',
        '-p:DebugSymbols=false',
        '-o', $servicePublish
    ) $repository.FullName

    Invoke-CheckedProcess $dotnet @(
        'publish', $cliProject,
        '-c', 'Release',
        '-r', 'win-x64',
        '--self-contained', 'true',
        '--no-restore',
        '-p:PublishSingleFile=true',
        '-p:DebugType=None',
        '-p:DebugSymbols=false',
        '-o', $cliPublish
    ) $repository.FullName

    Write-Host '=== Stop previous service ==='
    Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
    & sc.exe delete $ServiceName 2>$null | Out-Null
    Start-Sleep -Seconds 2

    if (Test-Path $InstallRoot) {
        $backup = Join-Path $DataRoot ('installer-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Move-Item $InstallRoot $backup -Force
        Write-Host "Previous binaries: $backup"
    }

    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    Copy-Item (Join-Path $servicePublish '*') $InstallRoot -Recurse -Force

    $cliCandidates = @(
        @(
            (Join-Path $cliPublish 'SirkUpdater.exe'),
            (Join-Path $cliPublish 'SirkUpdater.Cli.exe')
        ) | Where-Object { Test-Path $_ }
    )

    if ($cliCandidates.Count -eq 0) {
        $cliCandidates = @(
            Get-ChildItem -LiteralPath $cliPublish -Filter '*.exe' -File |
                Where-Object Name -ne 'SirkUpdater.Service.exe' |
                Select-Object -ExpandProperty FullName
        )
    }

    if ($cliCandidates.Count -ne 1) {
        $found = @(
            Get-ChildItem -LiteralPath $cliPublish -File |
                Select-Object -ExpandProperty Name
        )
        throw "Unable to identify exactly one published CLI executable. Found: $($found -join ', ')"
    }

    $cliPath = Join-Path $InstallRoot 'SirkUpdater.exe'
    Copy-Item $cliCandidates[0] $cliPath -Force

    $serviceExe = Join-Path $InstallRoot 'SirkUpdater.Service.exe'
    if (-not (Test-Path $serviceExe)) { throw 'Published service executable is missing.' }

    Write-Host '=== Register Windows service ==='
    New-Service `
        -Name $ServiceName `
        -BinaryPathName ('"{0}"' -f $serviceExe) `
        -DisplayName 'SIRK Updater' `
        -Description 'Transactional update service for SIRK Portal and SIRK Agent.' `
        -StartupType Automatic | Out-Null

    & sc.exe failure $ServiceName 'reset= 86400' 'actions= restart/5000/restart/15000/restart/60000' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to configure SIRK Updater recovery actions.' }

    Start-Service $ServiceName
    $service = Get-Service $ServiceName -ErrorAction Stop
    $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    $service.Refresh()

    if ($service.Status -ne 'Running') {
        throw "SIRK Updater service is not running. Status=$($service.Status)"
    }
    if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
        throw "SIRK Updater CLI is missing: $cliPath"
    }

    $startMode = 'Automatic'
    try {
        $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
        if ($serviceInfo -and $serviceInfo.StartMode) { $startMode = [string]$serviceInfo.StartMode }
    }
    catch {
        Write-Warning "CIM service report unavailable: $($_.Exception.Message)"
        $qc = & sc.exe qc $ServiceName 2>&1
        if ($LASTEXITCODE -eq 0 -and ($qc -match 'AUTO_START')) { $startMode = 'Automatic' }
    }

    if ($startMode -notmatch 'Auto') {
        throw "SIRK Updater service startup mode is not Automatic. StartMode=$startMode"
    }

    Write-Host ''
    Write-Host 'SIRK_UPDATER_INSTALL_OK' -ForegroundColor Green
    Write-Host "CLI: $cliPath"
    Write-Host "Service: $ServiceName"
    Write-Host "State: $($service.Status)"
    Write-Host "StartMode: $startMode"
    exit 0
}
finally {
    Remove-Item $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}
