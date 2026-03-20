# Intune → MacMon Pipeline (Kundenanleitung)

Diese Anleitung beschreibt die Einrichtung und den Betrieb der Pipeline:

1. Intune-Geräte aus Microsoft Graph exportieren
2. CSV mit MAC-Adressen erzeugen
3. MAC-Adressen parallel in MacMon prüfen und anlegen

---

## 1) Enthaltene Skripte

| Skript                  | Beschreibung                                    |
| ----------------------- | ----------------------------------------------- |
| `run_all.ps1`           | End-to-End Pipeline (empfohlen)                 |
| `intunes_download.ps1`  | Nur Intune-Export                               |
| `macmon_upload.ps1`     | Nur MacMon-Import (mit paralleler Verarbeitung) |
| `common.ps1`            | Gemeinsame Hilfsfunktionen                      |
| `pipeline_settings.env` | Zentrale Konfiguration                          |

---

## 2) Voraussetzungen

### 2.1 System

- **Windows PowerShell 5.1**
- **Azure CLI** (`az`)

### 2.2 Azure CLI installieren

**Option A: winget**

```powershell
winget install --id Microsoft.AzureCLI -e
```

**Option B: MSI-Installer**

1. Download: https://aka.ms/installazurecliwindows
2. MSI als Administrator ausführen
3. Neues Terminal öffnen und prüfen:

```powershell
az version
```

---

## 3) Berechtigungen

### 3.1 Azure / Microsoft Graph

Die App-Registration benötigt:

- `DeviceManagementManagedDevices.Read.All` (Application Permission)
- Optional: `Device.Read.All`

**Wichtig:**

- **Admin Consent** muss erteilt sein
- `AZURE_CLIENT_SECRET` = **Secret Value** (nicht Secret-ID!)

### 3.2 MacMon API

- API-Endpunkt erreichbar
- API-User mit Rechten für GET und POST auf `/endpoints`

---

## 4) Konfiguration

Alle Einstellungen erfolgen in `pipeline_settings.env`:

```dotenv
# Pfade
LOG_DIR="./logs"
INTUNE_CSV_PATH="./intune_devices.csv"
FAILED_DIR="./failed_uploads"

# Export-Einstellungen
FIRST_RUN="false"
HOURS_DEFAULT="24"

# MacMon API
MACMON_BASE="https://srv-macmon.example.com/api/v1.1/endpoints"
MACMON_USER="macmon_api"
MACMON_PASSWORD="<PASSWORT>"
MACMON_PARALLEL="20"

# Azure App Registration
AZURE_CLIENT_ID="<APP_CLIENT_ID>"
AZURE_TENANT_ID="<TENANT_ID>"
AZURE_CLIENT_SECRET="<CLIENT_SECRET_VALUE>"
```

### Wichtige Parameter

| Variable          | Beschreibung                                                            |
| ----------------- | ----------------------------------------------------------------------- |
| `FIRST_RUN`       | `true` = Vollexport aller Geräte, `false` = Delta der letzten X Stunden |
| `HOURS_DEFAULT`   | Zeitfenster für Delta-Export (Standard: 24h)                            |
| `MACMON_PARALLEL` | Anzahl gleichzeitiger API-Requests (Standard: 20)                       |

**Sicherheitshinweis:** Keine echten Secrets in Git einchecken!

---

## 5) Ausführung

### 5.1 Ins Projektverzeichnis wechseln

```powershell
cd C:\Users\<USER>\Programming\Skripte\intunes-macmon_skript
```

### 5.2 Gesamtlauf (empfohlen)

```powershell
.\run_all.ps1
```

**Ablauf:**

1. Intune-Geräte exportieren → CSV
2. MACs parallel in MacMon prüfen (bis zu 20 gleichzeitig)
3. Fehlende MACs parallel anlegen
4. CSV bei Erfolg löschen

**Laufzeit-Ausgabe (neu):**

- `run_all.ps1` schreibt am Ende eine Übersicht mit Dauer je Teilskript und Gesamtlaufzeit.
- `intunes_download.ps1` schreibt `Laufzeit gesamt: ...s` ins Log.
- `macmon_upload.ps1` schreibt `Laufzeit gesamt: ...s` (bzw. bei Fehler `Laufzeit bis Fehler: ...s`).

Beispiel im Log:

```text
Laufzeit Uebersicht:
- intunes_download.ps1: 12.4s
- macmon_upload.ps1: 38.7s
- Gesamt (run_all.ps1): 51.5s
```

### 5.3 Einzelschritte

```powershell
# Nur Intune-Export
.\intunes_download.ps1

# Nur MacMon-Upload
.\macmon_upload.ps1
```

### 5.4 Alternative Config-Datei

```powershell
$env:CONFIG_FILE = "C:\Pfad\zur\config.env"
.\run_all.ps1
```

---

## 6) Performance

Das MacMon-Skript nutzt **parallele Verarbeitung**:

- Alle MAC-Adressen werden zuerst gesammelt
- Dann parallel geprüft (GET-Requests)
- Fehlende werden parallel angelegt (POST-Requests)

Die Anzahl gleichzeitiger Requests wird über `MACMON_PARALLEL` gesteuert.

**Beispiel:** Bei 200 MACs und `MACMON_PARALLEL=20` laufen 20 Requests parallel → ~10x schneller als sequentiell.

---

## 7) Logs und Ergebnisse

| Pfad                   | Inhalt                                        |
| ---------------------- | --------------------------------------------- |
| `./logs/`              | Log-Dateien                                   |
| `./intune_devices.csv` | Exportierte Geräte (wird bei Erfolg gelöscht) |
| `./failed_uploads/`    | CSVs bei Fehlern zur Analyse                  |

---

## 8) Typische Fehler

### `az: command not found`

→ Azure CLI installieren, Terminal neu starten

### `AADSTS7000215 Invalid client secret`

→ **Secret Value** statt Secret-ID in `AZURE_CLIENT_SECRET` eintragen

### `Insufficient privileges` / HTTP 403

→ `DeviceManagementManagedDevices.Read.All` hinzufügen + Admin Consent erteilen

### MacMon HTTP 0 / Timeout

→ Netzwerk prüfen:

```powershell
Test-NetConnection srv-macmon.example.com -Port 443
```

---

## 9) Erstinbetriebnahme

1. Azure CLI installieren: `az version`
2. `pipeline_settings.env` befüllen
3. Graph-Berechtigungen + Admin Consent prüfen
4. MacMon-API-User testen
5. `FIRST_RUN="true"` setzen
6. `.\run_all.ps1` starten
7. Nach Erstlauf: `FIRST_RUN="false"` setzen

---

## 10) Automatisierung (Task Scheduler)

Für täglichen Betrieb:

```
FIRST_RUN="false"
HOURS_DEFAULT="24"
```

Task Scheduler Befehl:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Pfad\run_all.ps1"
```

---

## 11) Support

Bei Störungen bitte mitsenden:

- Genaue Fehlermeldung inkl. HTTP-Statuscode
- `pipeline_settings.env` (Secrets anonymisiert)
- Letzte Logzeilen:

```powershell
Get-Content .\logs\macmon_upload.log -Tail 50
Get-Content .\logs\intune_download.log -Tail 50
```
