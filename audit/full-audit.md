# Full product audit

Repository: `Eris92/SIRK-Updater`
Commit: `a0df8f29dfd2e421603d4446e6d473d71b8a573b`

## Summary

```json
{
  "files": 25,
  "textFiles": 24,
  "lines": 1695,
  "extensions": {
    ".cs": 7,
    ".csproj": 3,
    ".json": 3,
    ".md": 1,
    ".props": 1,
    ".ps1": 4,
    ".psm1": 1,
    ".sln": 1,
    ".yml": 4
  },
  "projects": 3,
  "nodeArtifacts": 0,
  "legacyPaths": 0,
  "findingsBySeverity": {
    "critical": 1,
    "high": 0,
    "medium": 1,
    "low": 0,
    "info": 1
  }
}
```

## Highest severity findings

- **CRITICAL** `accept-any-server-certificate` — `src/SirkUpdater.Core/TransactionalUpdateEngine.cs:28` — ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
- **MEDIUM** `incomplete-implementation` — `src/SirkUpdater.Core/ApplicationManifest.cs:75` — throw new InvalidDataException("signatureVerifierArguments must include the {payload} placeholder.");
- **INFO** `incomplete-implementation` — `tests/delegated-signature-contract.ps1:13` — 'signatureVerifierArguments must include the {payload} placeholder'
