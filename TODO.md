# TODO Intune -> MacMon

## Prioritaet Hoch

- [ ] `preflight_diagnose.ps1` im Kundentermin als ersten Schritt fest etablieren.
- [ ] `run_all.ps1` optional um Preflight-Aufruf erweitern (`RUN_PREFLIGHT=true`).
- [ ] `macmon_upload.ps1`: Retry mit Backoff fuer HTTP 0 / 429 / 5xx implementieren.
- [ ] `macmon_upload.ps1`: Default fuer `MACMON_PARALLEL` auf 5 pruefen und ggf. umstellen.

## Prioritaet Mittel

- [ ] `intunes_download.ps1`: Exportfilter per ENV umschaltbar machen (`INTUNE_FILTER_FIELD=enrolledDateTime|lastSyncDateTime`).
- [ ] `intunes_download.ps1`: Missing-MAC-Report optional in `failed_uploads/` statt Projektwurzel schreiben.
- [ ] `macmon_upload.ps1`: Fehlerdetails um Exception-Typ erweitern (Transport/TLS klarer sichtbar).

## Prioritaet Niedrig

- [ ] `ANLEITUNG_KUNDE.md`: Abschnitt "Schnelltest vor Lauf" mit Exit-Code-Tabelle dokumentieren.
- [ ] `pipeline_settings.env`: neue Diagnose-/Retry-Parameter kommentieren.
- [ ] Optional: kurzer "Quick Mode" fuer Diagnose (ohne Stresstest, Laufzeit < 60s).
