<p align="center">
  <img src="https://raw.githubusercontent.com/n-bross/n-bross/main/assets/logos/intune-macmon-pipeline.png" width="120" alt="Intune MacMon Pipeline Logo" />
</p>

<h1 align="center">Intune → MacMon NAC Sync Pipeline</h1>

<p align="center">
  <strong>Automatisierte Synchronisation verwalteter Endgeräte aus Microsoft Intune (Graph API) in ein MacMon NAC-System mit PowerShell 7 Parallelverarbeitung, Preflight-Diagnose und detaillierter Transportfehler-Klassifizierung.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/PowerShell-7.1+-5391FE?style=flat-square&logo=powershell&logoColor=white" alt="PowerShell 7.1+" />
  <img src="https://img.shields.io/badge/Microsoft_Graph-API_v1.0-0078D4?style=flat-square&logo=microsoftazure&logoColor=white" alt="Microsoft Graph API" />
  <img src="https://img.shields.io/badge/MacMon-NAC_REST_API-0F766E?style=flat-square" alt="MacMon NAC" />
</p>

---

## Überblick & Problemstellung

In Unternehmensnetzwerken mit **Network Access Control (MacMon NAC)** müssen sowohl WLAN- als auch Ethernet-MAC-Adressen neu eingerollter oder aktualisierter **Microsoft Intune Managed Devices** zuverlässig als autorisierte Endpunkte hinterlegt werden.

Diese Pipeline automatisiert den gesamten Synchronisationsprozess End-to-End:

1. **Inkrementeller oder vollständiger Export (`intunes_download.ps1`):**
   - Authentifizierung über einen Azure Service Principal (`DeviceManagementManagedDevices.Read.All`).
   - Abruf verwalteter Geräte über die Microsoft Graph API (`v1.0/deviceManagement/managedDevices`) inklusive automatischem Paging (`@odata.nextLink`).
   - **Ethernet-MAC-Enrichment:** Da der Listen-Endpunkt der Graph API bei vielen Geräten `ethernetMacAddress` leer lässt, zieht die Pipeline fehlende Ethernet-MACs gezielt über den Einzelgeräte-Endpunkt nach.
2. **Paralleler Abgleich & Anlage in MacMon (`macmon_upload.ps1`):**
   - Normalisierung sämtlicher MAC-Formate (`AA:BB:CC:DD:EE:FF`, `AABBCCDDEEFF`) auf das kanonische MacMon-Format (`AA-BB-CC-DD-EE-FF`) und Deduplizierung über ein `HashSet`.
   - **High-Throughput Parallelisierung (`ForEach-Object -Parallel`):** Gleichzeitige Prüfung und Anlage mit konfigurierbarem `ThrottleLimit` (Standard: 20 parallele Worker).
   - **Granulare Transport- & Fehlerklassifizierung:** Unterscheidung zwischen DNS-, TLS-, Timeout-, Connection-Refused-, Auth- (`401/403`), Conflict- (`409`) und Server-Fehlern (`5xx`). Bei Teilfehlern wird der CSV-Snapshot automatisch mit Zeitstempel unter `failed_uploads/` zur Nachanalyse gesichert.
3. **7-Stufen Preflight- & Stress-Diagnose (`preflight_diagnose.ps1`):**
   - Prüft vor dem Produktivlauf Konfiguration, DNS/Port 443, TLS-Handshake, MacMon-API-Login, Microsoft Graph Token/Endpoint, CSV-Struktur sowie einen parallelen Kurz-Stresstest mit definierten Exit-Codes (`0`, `10`–`80`).

---

## Architektur & Skript-Struktur

```text
intunes-macmon-Skript/
├── run_all.ps1                      # End-to-End Orchestrierung (Download -> Upload + Laufzeitmessung)
├── intunes_download.ps1             # Microsoft Graph Export inkl. Paging & Ethernet-MAC-Enrichment
├── macmon_upload.ps1                # Paralleler MacMon REST-Abgleich & Endpunkt-Erstellung
├── preflight_diagnose.ps1           # 7-stufige System-, TLS-, Auth- & Stress-Diagnose
├── test_ethernet_mac_download.ps1   # Analyse-Tool für List-vs-Detail Ethernet-MAC-Abdeckung
├── common.ps1                       # Zentrales Logging, Config-Parser & Azure-CLI-Wrapper
├── pipeline_settings.env.example    # Dokumentierte Beispielkonfiguration
└── ANLEITUNG_KUNDE.md               # Ausführliche Betriebs- und Einrichtungsdokumentation
```

---

## Schnellstart

### 1. Voraussetzungen

- **PowerShell 7.1+** (`pwsh`)
- **Azure CLI** (`az`)
- Azure App Registration (Service Principal) mit `DeviceManagementManagedDevices.Read.All` (Application Permission)

### 2. Konfiguration anlegen

```powershell
Copy-Item .\pipeline_settings.env.example .\pipeline_settings.env
```

Anschließend in `pipeline_settings.env` die Endpunkte und Service-Principal-Zugangsdaten eintragen (die Datei `.env` ist über `.gitignore` vom Versionsverlauf ausgeschlossen).

### 3. Preflight-Check & Pipeline starten

```powershell
# 1. Verbindung, Zertifikate, Berechtigungen & API-Stabilität prüfen
pwsh -File .\preflight_diagnose.ps1

# 2. Gesamte Pipeline ausführen
pwsh -File .\run_all.ps1
```

Eine detaillierte Schritt-für-Schritt-Dokumentation zur Einrichtung der Azure-Berechtigungen, Diagnose-Modi und Aufgabenplanung (Task Scheduler) befindet sich in [**`ANLEITUNG_KUNDE.md`**](ANLEITUNG_KUNDE.md).
