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

    $dotnet = (Get-Command dotnet.exe -ErrorAction SilentlyContinue).Source
    if (-not $dotnet) {
        Write-Host '=== Install temporary .NET 8 SDK ==='
        $dotnetInstall = Join-Path $WorkRoot 'dotnet-install.ps1'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $dotnetInstall
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dotnetInstall -Channel 8.0 -Quality GA -InstallDir $DotnetRoot
        if ($LASTEXITCODE -ne 0) { throw 'Temporary .NET SDK installation failed.' }
        $dotnet = Join-Path $DotnetRoot 'dotnet.exe'
    }

    Write-Host '=== Download source ==='
    Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/Eris92/SIRK-Updater/zip/refs/heads/$Channel" -OutFile $SourceZip
    Expand-Archive -LiteralPath $SourceZip -DestinationPath $SourceRoot -Force
    $repository = Get-ChildItem $SourceRoot -Directory | Select-Object -First 1
    if (-not $repository) { throw 'Downloaded repository is empty.' }

    Write-Host '=== Build self-contained binaries ==='
    $servicePublish = Join-Path $WorkRoot 'publish-service'
    $cliPublish = Join-Path $WorkRoot 'publish-cli'
    Invoke-CheckedProcess $dotnet @('publish', 'src\SirkUpdater.Service\SirkUpdater.Service.csproj', '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', '-p:PublishSingleFile=true', '-p:DebugType=None', '-p:DebugSymbols=false', '-o', $servicePublish) $repository.FullName
    Invoke-CheckedProcess $dotnet @('publish', 'src\SirkUpdater.Cli\SirkUpdater.Cli.csproj', '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', '-p:PublishSingleFile=true', '-p:DebugType=None', '-p:DebugSymbols=false', '-o', $cliPublish) $repository.FullName

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
    Copy-Item (Join-Path $cliPublish 'SirkUpdater.Cli.exe') (Join-Path $InstallRoot 'SirkUpdater.exe') -Force

    $serviceExe = Join-Path $InstallRoot 'SirkUpdater.Service.exe'
    if (-not (Test-Path $serviceExe)) { throw 'Published service executable is missing.' }

    Write-Host '=== Register Windows service ==='
    & sc.exe create $ServiceName "binPath= `"$serviceExe`"" 'start= auto' 'DisplayName= SIRK Updater' | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create SIRK Updater service.' }
    & sc.exe description $ServiceName 'Transactional update service for SIRK Portal and SIRK Agent.' | Out-Null
    & sc.exe failure $ServiceName 'reset= 86400' 'actions= restart/5000/restart/15000/restart/60000' | Out-Null

    Start-Service $ServiceName
    (Get-Service $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))

    Write-Host ''
    Write-Host 'SIRK_UPDATER_INSTALL_OK'
    Write-Host "CLI: $(Join-Path $InstallRoot 'SirkUpdater.exe')"
    Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" | Select-Object Name, DisplayName, State, StartMode, PathName | Format-List
}
finally {
    Remove-Item $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}
