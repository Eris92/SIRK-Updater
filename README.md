# SIRK Updater

Wspólny transactional updater dla komponentów SIRK Platform.

## Cel

Jedna usługa Windows obsługuje aktualizacje wielu aplikacji:

- SIRK Portal
- SIRK Agent
- w przyszłości SIRK Central

Instalatory aplikacji nie zawierają własnego silnika aktualizacji. Sprawdzają, czy `SIRK Updater` jest zainstalowany i zgodny, instalują go tylko wtedy, gdy go brakuje albo jest starszy niż wymagana wersja, a następnie rejestrują manifest aplikacji.

## Docelowe ścieżki

```text
C:\Program Files\SIRK\Updater
C:\ProgramData\SIRK\Updater
C:\ProgramData\SIRK\Updater\applications
```

## Usługa

```text
ServiceName: SirkUpdater
DisplayName: SIRK Updater
```

## Transactional update

```text
download
verify signature and SHA256
backup
maintenance.lock
stop watchdog
stop application service
replace files
run migrations
start application service
health check
commit or rollback
start watchdog
remove maintenance.lock
cleanup
```

## Stan projektu

Wersja początkowa rozwijana jest jako .NET 8 Windows Service z biblioteką Core i CLI.
