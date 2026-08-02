#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$manifest = Get-Content -LiteralPath (Join-Path $root 'src\SirkUpdater.Core\ApplicationManifest.cs') -Raw
$engine = Get-Content -LiteralPath (Join-Path $root 'src\SirkUpdater.Core\TransactionalUpdateEngine.cs') -Raw

$requiredManifest = @(
    'signatureVerifierPath',
    'signatureVerifierArguments',
    'signatureVerifierPath must be located below installRoot',
    'signatureVerifierArguments must include the {payload} placeholder'
)
foreach ($needle in $requiredManifest) {
    if ($manifest.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) {
        throw "Application manifest delegated signature contract is missing: $needle"
    }
}

$requiredEngine = @(
    'VerifySignedPayload(manifest, payloadRoot)',
    'Application signature verification failed',
    'Update was rejected before the installed application was modified',
    'installationTouched',
    'backupReady',
    'applicationStopped',
    'watchdogStopped'
)
foreach ($needle in $requiredEngine) {
    if ($engine.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) {
        throw "Transactional engine delegated signature contract is missing: $needle"
    }
}

$verificationPosition = $engine.IndexOf('VerifySignedPayload(manifest, payloadRoot)', [StringComparison]::Ordinal)
$backupPosition = $engine.IndexOf('CopyDirectory(manifest.InstallRoot, backupRoot)', [StringComparison]::Ordinal)
$stopPosition = $engine.IndexOf('StopService(manifest.ServiceName', [StringComparison]::Ordinal)
if ($verificationPosition -lt 0 -or $backupPosition -lt 0 -or $stopPosition -lt 0 -or
    $verificationPosition -gt $backupPosition -or $verificationPosition -gt $stopPosition) {
    throw 'Signed payload verification must happen before backup and before stopping the application service.'
}

Write-Host 'delegated-signature-contract: OK'
