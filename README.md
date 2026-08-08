# SIRK Updater

Wspólny transactional updater dla komponentów SIRK Platform.

## Rola

SIRK Updater jest wykonawcą transakcji aktualizacji. Nie jest runtime brokerem GitHub i nie przechowuje GitHub credentials.

Dla bieżącego kontraktu platformy:

- SIRK Central jest jedynym runtime brokerem aktualizacji produktów;
- Agent i Portal otrzymują już zweryfikowany pakiet z Central cache;
- manifest aplikacji używa `updateSource: "sirk-central-cache"`;
- Updater weryfikuje przekazany SHA-256, bezpieczeństwo ZIP i deleguje weryfikację podpisanego payloadu do verifiera komponentu;
- następnie wykonuje backup, maintenance, stop/start usług, instalację, health check oraz rollback przy błędzie.

Updater nie jest osobnym produktem dystrybuowanym przez Central product cache. Jest współdzielonym executorem instalowanym jako zależność bootstrap/runtime.

## Runtime

Aktualna linia `main` jest .NET 10-only i używa framework-dependent binaries.

Kanoniczna linia wersji przed pierwszym świadomie zatwierdzonym `1.0.0` to `0.1.1.X`.

## Docelowe ścieżki Windows

```text
C:\Program Files\SIRK\Updater
C:\ProgramData\SIRK\Updater
C:\ProgramData\SIRK\Updater\applications
```

Usługa Windows:

```text
ServiceName: SirkUpdater
DisplayName: SIRK Updater
```

Na Linux dane runtime są przechowywane pod `/var/lib/sirk-updater`, a instalatory komponentów rejestrują manifesty aplikacji zgodnie z lokalnym lifecycle.

## Transactional update

```text
verify package SHA-256 and ZIP safety
extract staging payload
verify signed payload through component verifier
backup
maintenance.lock
stop watchdog
stop application service
replace files
start application service
health check
commit or rollback
start watchdog
remove maintenance.lock
cleanup
```

Runtime update nie wykonuje direct-GitHub discovery ani downloadu. Publiczny GitHub może być używany wyłącznie przez bootstrap installer zgodnie z kontraktem projektu.
