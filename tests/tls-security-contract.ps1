#requires -Version 7.4
$ErrorActionPreference = 'Stop'

$source = Get-Content 'src/SirkUpdater.Core/TransactionalUpdateEngine.cs' -Raw
foreach ($forbidden in @(
    'DangerousAcceptAnyServerCertificateValidator',
    'ServerCertificateCustomValidationCallback',
    'RemoteCertificateValidationCallback'
)) {
    if ($source.Contains($forbidden, [StringComparison]::Ordinal)) {
        throw "Forbidden TLS bypass remains: $forbidden"
    }
}

foreach ($required in @(
    'handler ??= new HttpClientHandler()',
    'ValidateHealthUri(manifest.HealthUrl)',
    'Application health URL must use HTTPS unless it targets localhost or a loopback address',
    'IPAddress.IsLoopback'
)) {
    if (-not $source.Contains($required, [StringComparison]::Ordinal)) {
        throw "Strict TLS/health URI contract is missing: $required"
    }
}

Write-Host 'tls-security-contract: OK'
