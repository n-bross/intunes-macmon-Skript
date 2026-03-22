#Requires -Version 7.1
$ErrorActionPreference = 'Stop'  # Bei jedem Fehler sofort abbrechen, statt weiterzumachen

# Ermittle den Ordner, in dem dieses Skript liegt, und wechsle dorthin.
# So funktionieren alle relativen Pfade (z.B. .\logs) unabhängig davon, von wo das Skript gestartet wird.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $scriptDir

# Lade gemeinsame Hilfsfunktionen (info, warn, err, fail, Import-Config, ...)
. "$scriptDir\common.ps1"

# Lade die Konfigurationsdatei. Wenn die Umgebungsvariable CONFIG_FILE gesetzt ist,
# wird diese verwendet – sonst die Standard-Datei pipeline_settings.env.
$configFile = if ($env:CONFIG_FILE) { $env:CONFIG_FILE } else { Join-Path $scriptDir 'pipeline_settings.env' }
Import-Config $configFile

# Prüfe, ob alle Pflicht-Variablen aus der Konfiguration gesetzt sind.
# Wenn eine fehlt, bricht das Skript mit einer Fehlermeldung ab.
Assert-Env 'LOG_DIR'
Assert-Env 'MACMON_BASE'
Assert-Env 'MACMON_USER'
Assert-Env 'MACMON_PASSWORD'
Assert-Env 'INTUNE_CSV_PATH'
Assert-Env 'FAILED_DIR'

# Logdatei initialisieren (wird unter LOG_DIR als macmon_upload.log gespeichert)
Initialize-Logger $env:LOG_DIR 'macmon_upload'

# Stoppuhr starten, um am Ende die Gesamtlaufzeit anzuzeigen
$timer = [System.Diagnostics.Stopwatch]::StartNew()

# ── CSV-Datei prüfen ──────────────────────────────────────────────────────────
# Die CSV wurde vorher von intunes_download.ps1 erstellt.
# Wenn sie nicht existiert, macht ein Upload keinen Sinn.
$csvPath = $env:INTUNE_CSV_PATH
if (-not (Test-Path $csvPath)) {
    fail "Datei nicht gefunden: $csvPath. Bitte zuerst .\intunes_download.ps1 oder .\run_all.ps1 ausfuehren."
}

# Erste Zeile der CSV lesen und prüfen ob der Header wie erwartet aussieht.
# Dadurch erkennen wir frühzeitig, wenn Intune das Format geändert hat.
$firstLine = (Get-Content $csvPath -TotalCount 1 -Encoding UTF8).TrimEnd("`r")
$validHeaders = @(
    'Device name,Last check-in,Wi-Fi MAC,EthernetMAC',
    'Device name,Last check-in,Wi-Fi MAC,EthernetMac'
)
if ($firstLine -notin $validHeaders) { fail "Unerwarteter CSV-Header: $firstLine" }
info "CSV-Header validiert."

# ── Authentifizierung vorbereiten ─────────────────────────────────────────────
# macmon erwartet "Basic Auth": Benutzername:Passwort wird Base64-kodiert
# und als Authorization-Header bei jedem Request mitgeschickt.
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:MACMON_USER):$($env:MACMON_PASSWORD)"))
$authHeaders = @{ Authorization = "Basic $b64"; Accept = 'application/json' }

# Timeout aus der Konfiguration lesen, Standardwert 20 Sekunden
$httpTimeoutSeconds = if ($env:MACMON_TIMEOUT_SECONDS -and $env:MACMON_TIMEOUT_SECONDS -match '^\d+$') { [int]$env:MACMON_TIMEOUT_SECONDS } else { 20 }

# ── Hilfsfunktion: HTTP-Request an macmon senden ──────────────────────────────
# Kapselt GET und POST Requests. Gibt immer ein Objekt mit StatusCode und Body zurück,
# auch wenn ein Fehler aufgetreten ist (kein unkontrollierter Absturz).
function Invoke-MacmonRequest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET','POST')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Body
    )

    try {
        if ($Method -eq 'POST') {
            $resp = Invoke-WebRequest -UseBasicParsing -SkipCertificateCheck -Method Post -Uri $Uri -Headers $authHeaders -Body $Body -ContentType 'application/json; charset=utf-8' -TimeoutSec $httpTimeoutSeconds -ErrorAction Stop
        } else {
            $resp = Invoke-WebRequest -UseBasicParsing -SkipCertificateCheck -Method Get -Uri $Uri -Headers $authHeaders -TimeoutSec $httpTimeoutSeconds -ErrorAction Stop
        }
        return [PSCustomObject]@{ StatusCode = [int]$resp.StatusCode; Body = [string]$resp.Content }
    } catch {
        $statusCode = 0
        $content = ''

        # PS7: HTTP-Fehler (4xx, 5xx) kommen als HttpResponseException
        if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            $content = $_.ErrorDetails.Message
        } else {
            # Netzwerkfehler (kein Server erreichbar, Timeout, ...)
            $content = [string]$_.Exception.Message
            if ($content -match '\((\d{3})\)') { $statusCode = [int]$Matches[1] }
        }

        # macmon gibt bei "nicht gefunden" manchmal einen speziellen Fehlercode zurück
        if ($statusCode -eq 0 -and $content -match '"code"\s*:\s*1010|not found') { $statusCode = 404 }

        return [PSCustomObject]@{ StatusCode = $statusCode; Body = $content }
    }
}

# ── Hilfsfunktion: MAC-Adresse normalisieren ──────────────────────────────────
# Intune liefert MACs in verschiedenen Formaten (z.B. "AA:BB:CC:DD:EE:FF" oder "AABBCCDDEEFF").
# macmon erwartet das Format "AA-BB-CC-DD-EE-FF".
# Diese Funktion entfernt alle Trennzeichen, prüft ob 12 Hex-Zeichen übrig bleiben,
# und formatiert sie dann mit Bindestrichen.
function Normalize-Mac {
    param([string]$InputText)
    $clean = (($InputText | ForEach-Object { $_ }) -replace '[^0-9a-fA-F]', '').ToUpper()
    if ($clean.Length -ne 12) { return '' }  # Ungültige MAC → leer zurückgeben
    return $clean -replace '^(.{2})(.{2})(.{2})(.{2})(.{2})(.{2})$', '$1-$2-$3-$4-$5-$6'
}

# ── CSV einlesen und MAC-Adressen sammeln ─────────────────────────────────────
# Alle Zeilen der CSV werden durchlaufen. Pro Gerät gibt es bis zu zwei MACs:
# eine für WLAN und eine für Ethernet. Doppelte MACs werden übersprungen.
$csvData = Import-Csv -Path $csvPath -Encoding UTF8
info "Import gestartet. Quelle: $csvPath"

$macList    = [System.Collections.ArrayList]::new()
$uniqueMacs = New-Object System.Collections.Generic.HashSet[string]  # Verhindert Duplikate

foreach ($row in $csvData) {
    $deviceName = [string]$row.'Device name'
    if ([string]::IsNullOrWhiteSpace($deviceName)) { continue }  # Leere Zeilen überspringen

    $wifiMac = Normalize-Mac ([string]$row.'Wi-Fi MAC')

    # Intune exportiert den Ethernet-Spaltenname manchmal unterschiedlich (MAC vs. Mac)
    $ethProp = $row.PSObject.Properties['EthernetMAC']
    $ethMac  = if ($ethProp) { Normalize-Mac ([string]$row.'EthernetMAC') } else { Normalize-Mac ([string]$row.'EthernetMac') }

    # Nur gültige, noch nicht gesehene MACs zur Liste hinzufügen
    if (-not [string]::IsNullOrWhiteSpace($wifiMac)) {
        if ($uniqueMacs.Add($wifiMac)) {
            [void]$macList.Add([PSCustomObject]@{ Mac = $wifiMac; DeviceName = $deviceName; MacType = 'Wi-Fi' })
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ethMac)) {
        if ($uniqueMacs.Add($ethMac)) {
            [void]$macList.Add([PSCustomObject]@{ Mac = $ethMac; DeviceName = $deviceName; MacType = 'Ethernet' })
        }
    }
}

$deviceCount  = ($csvData | Where-Object { -not [string]::IsNullOrWhiteSpace($_.'Device name') }).Count
$totalMacs    = $macList.Count
$skippedCount = ($deviceCount * 2) - $totalMacs  # Geräte * 2 mögliche MACs minus tatsächlich gefundene
$keepCsv      = ($env:KEEP_INTUNE_CSV -eq 'true')

info "Gesammelt: $totalMacs MAC-Adressen von $deviceCount Geraeten (uebersprungen: $skippedCount ohne gueltige MAC)"

# Wenn keine MACs gefunden wurden, gibt es nichts zu tun
if ($totalMacs -eq 0) {
    info "Keine pruefbaren MAC-Adressen gefunden -> ueberspringe API-Login und Upload."
    if ($keepCsv) {
        info "CSV beibehalten (KEEP_INTUNE_CSV=true): $csvPath"
    } else {
        Remove-Item $csvPath -Force
        info "CSV geloescht: $csvPath"
    }
    $timer.Stop()
    info "Laufzeit gesamt: $([math]::Round($timer.Elapsed.TotalSeconds, 1))s"
    exit 0
}

# ── Optionaler Login-Check ────────────────────────────────────────────────────
# Bevor wir hunderte parallele Requests starten, einmal prüfen ob die API
# überhaupt erreichbar und das Passwort korrekt ist. Spart Zeit bei Problemen.
$performLoginCheck = ($env:MACMON_LOGIN_CHECK -eq 'true')
if ($performLoginCheck) {
    info "Pruefe API-Login bei macmon..."
    $login = Invoke-MacmonRequest -Method GET -Uri $env:MACMON_BASE
    if ($login.StatusCode -in 401, 403) { fail "Authentifizierung bei macmon fehlgeschlagen (HTTP $($login.StatusCode))." }
    if ($login.StatusCode -eq 0 -or $login.StatusCode -ge 500) {
        fail "MacMon API derzeit nicht gesund (HTTP $($login.StatusCode)). Lauf wird vor Parallelphase abgebrochen. Details: $($login.Body)"
    }
    if ($login.StatusCode -in 200, 404) { info "API-Login erfolgreich." } else { info "API-Antwort auf Login-Check: HTTP $($login.StatusCode)" }
} else {
    info "Login-Precheck deaktiviert (MACMON_LOGIN_CHECK != true) -> starte direkt mit MAC-Pruefung."
}

# ── Parallel: alle MACs prüfen ────────────────────────────────────────────────
# Für jede MAC-Adresse fragen wir bei macmon: "Kennst du diesen Endpunkt schon?"
# Das passiert gleichzeitig (parallel) für bis zu $parallelLimit MACs auf einmal,
# was die Gesamtdauer drastisch verkürzt (statt nacheinander = Anzahl × Wartezeit).
#
# PS7-Feature: ForEach-Object -Parallel ersetzt den komplexen Runspace-Pool-Code aus PS5.
# Variablen aus dem äußeren Scope werden mit "$using:Variablenname" übergeben.
$parallelLimit  = if ($env:MACMON_PARALLEL) { [int]$env:MACMON_PARALLEL } else { 20 }
info "Starte parallele Verarbeitung mit max $parallelLimit gleichzeitigen Requests..."

$macmonBase     = $env:MACMON_BASE
$timeoutSeconds = $httpTimeoutSeconds

$checkResults = $macList | ForEach-Object -Parallel {
    $entry = $_
    $uri   = "$using:macmonBase/$($entry.Mac)"  # z.B. https://macmon/api/v1.1/endpoints/AA-BB-CC-DD-EE-FF

    try {
        $resp = Invoke-WebRequest -UseBasicParsing -SkipCertificateCheck -Method Get -Uri $uri -Headers $using:authHeaders -TimeoutSec $using:timeoutSeconds -ErrorAction Stop
        # HTTP 200 → MAC existiert bereits
        [PSCustomObject]@{ MacEntry = $entry; StatusCode = [int]$resp.StatusCode; Body = $resp.Content; Action = 'exists' }
    } catch {
        $statusCode = 0
        $content    = ''

        if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            $content    = $_.ErrorDetails.Message
        } else {
            $content = [string]$_.Exception.Message
            if ($content -match '\((\d{3})\)') { $statusCode = [int]$Matches[1] }
            elseif ($content -match '\b([1-5]\d{2})\b') { $statusCode = [int]$Matches[1] }
        }

        if ($statusCode -eq 0 -and $content -match '"code"\s*:\s*1010|not found') { $statusCode = 404 }

        # HTTP 404 → MAC unbekannt → muss angelegt werden. Alles andere → Fehler.
        $action = if ($statusCode -eq 404) { 'create' } else { 'error' }
        [PSCustomObject]@{ MacEntry = $entry; StatusCode = $statusCode; Body = $content; Action = $action }
    }
} -ThrottleLimit $parallelLimit

# ── Ergebnisse der Prüfung auswerten ─────────────────────────────────────────
$existsCount       = 0
$errorCount        = 0
$transportErrorCount = 0
$authErrorCount    = 0
$serverErrorCount  = 0
$otherErrorCount   = 0
$toCreate          = [System.Collections.ArrayList]::new()

foreach ($r in $checkResults) {
    $entry = $r.MacEntry
    switch ($r.Action) {
        'exists' {
            $existsCount++
            info "[$($entry.MacType)] Bereits vorhanden: $($entry.Mac)"
        }
        'create' {
            # Diese MAC wird in der nächsten Phase neu angelegt
            [void]$toCreate.Add($entry)
            info "[$($entry.MacType)] Nicht gefunden: $($entry.Mac) -> wird angelegt"
        }
        'error' {
            # Fehler kategorisieren für die spätere Zusammenfassung
            $errorCount++
            if ($r.StatusCode -eq 0) { $transportErrorCount++ }        # kein HTTP = Netzwerkfehler
            elseif ($r.StatusCode -in 401, 403) { $authErrorCount++ }  # falsches Passwort o.ä.
            elseif ($r.StatusCode -ge 500) { $serverErrorCount++ }      # macmon-Server hat ein Problem
            else { $otherErrorCount++ }
            err "[$($entry.MacType)] Fehler beim Pruefen $($entry.Mac) (HTTP $($r.StatusCode))"
            if ($r.Body) { err "  Details: $($r.Body)" }
        }
    }
}

info "Pruefung abgeschlossen: $existsCount vorhanden, $($toCreate.Count) neu anzulegen, $errorCount Fehler"

# ── Parallel: fehlende Endpunkte anlegen ──────────────────────────────────────
# Alle MACs die noch nicht in macmon sind, werden jetzt per POST-Request angelegt.
# Auch das passiert parallel für schnellere Verarbeitung.
$createdCount = 0

if ($toCreate.Count -gt 0) {
    info "Lege $($toCreate.Count) neue Endpunkte an..."

    $createResults = $toCreate | ForEach-Object -Parallel {
        $entry   = $_
        # JSON-Objekt mit MAC, Status "aktiv" und einem Kommentar (Gerätename + Typ)
        $payload = @{ mac = $entry.Mac; active = $true; comment = "$($entry.DeviceName) ($($entry.MacType))" } | ConvertTo-Json -Compress

        try {
            # POST an die macmon-API → neuen Endpunkt anlegen
            $resp = Invoke-WebRequest -UseBasicParsing -SkipCertificateCheck -Method Post -Uri $using:macmonBase -Headers $using:authHeaders -Body $payload -ContentType 'application/json; charset=utf-8' -TimeoutSec $using:timeoutSeconds -ErrorAction Stop
            [PSCustomObject]@{ MacEntry = $entry; StatusCode = [int]$resp.StatusCode; Body = $resp.Content; Success = $true }
        } catch {
            $statusCode = 0
            $content    = ''

            if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
                $statusCode = [int]$_.Exception.Response.StatusCode
                $content    = $_.ErrorDetails.Message
            } else {
                $content = [string]$_.Exception.Message
                if ($content -match '\((\d{3})\)') { $statusCode = [int]$Matches[1] }
                elseif ($content -match '\b([1-5]\d{2})\b') { $statusCode = [int]$Matches[1] }
            }

            [PSCustomObject]@{ MacEntry = $entry; StatusCode = $statusCode; Body = $content; Success = $false }
        }
    } -ThrottleLimit $parallelLimit

    # Ergebnisse des Anlegens auswerten
    foreach ($result in $createResults) {
        $entry = $result.MacEntry
        if ($result.Success -or $result.StatusCode -in 200, 201) {
            $createdCount++
            info "[$($entry.MacType)] Angelegt: $($entry.Mac)"
        } elseif ($result.StatusCode -eq 409) {
            # 409 Conflict = MAC wurde zwischenzeitlich von woanders angelegt → kein Fehler
            $existsCount++
            warn "[$($entry.MacType)] Bereits vorhanden (409 Conflict): $($entry.Mac)"
        } else {
            $errorCount++
            if ($result.StatusCode -eq 0) { $transportErrorCount++ }
            elseif ($result.StatusCode -in 401, 403) { $authErrorCount++ }
            elseif ($result.StatusCode -ge 500) { $serverErrorCount++ }
            else { $otherErrorCount++ }
            err "[$($entry.MacType)] Fehler beim Anlegen $($entry.Mac) (HTTP $($result.StatusCode))"
            if ($result.Body) { err "  Details: $($result.Body)" }
        }
    }
}

# ── Abschlussmeldung ─────────────────────────────────────────────────────────
$checkedCount = $totalMacs
info "Import beendet. Geraete=$deviceCount, Geprueft=$checkedCount, Uebersprungen=$skippedCount, Vorhanden=$existsCount, Neu=$createdCount, Fehler=$errorCount"
if ($errorCount -gt 0) {
    info "Fehlerzusammenfassung: Transport(HTTP0)=$transportErrorCount, Auth(401/403)=$authErrorCount, Server(5xx)=$serverErrorCount, Sonstige=$otherErrorCount"
}

if ($createdCount -eq 0) {
    info "Keine Aenderungen in macmon vorgenommen (0 neue Eintraege)."
    if     ($checkedCount -eq 0)               { warn "Keine pruefbaren MAC-Adressen in der CSV gefunden." }
    elseif ($errorCount -gt 0)                 { warn "Keine neuen Endpunkte angelegt, weil API-Fehler aufgetreten sind." }
    elseif ($existsCount -eq $checkedCount)    { warn "Keine neuen Endpunkte angelegt, alle geprueften MACs existieren bereits." }
}

# ── CSV aufräumen oder bei Fehler sichern ────────────────────────────────────
if ($errorCount -eq 0) {
    # Alles gut → CSV löschen (oder behalten wenn KEEP_INTUNE_CSV=true)
    if ($keepCsv) {
        info "CSV beibehalten (KEEP_INTUNE_CSV=true): $csvPath"
    } else {
        Remove-Item $csvPath -Force
        info "CSV geloescht: $csvPath"
    }
    $timer.Stop()
    info "Laufzeit gesamt: $([math]::Round($timer.Elapsed.TotalSeconds, 1))s"
} else {
    # Fehler aufgetreten → CSV mit Zeitstempel in FAILED_DIR kopieren zur späteren Analyse
    New-Item -ItemType Directory -Force -Path $env:FAILED_DIR | Out-Null
    $timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $failedFile = Join-Path $env:FAILED_DIR "intune_devices_failed_$timestamp.csv"

    try {
        Copy-Item $csvPath $failedFile
        err "Upload war nicht vollstaendig erfolgreich."
        err "CSV zur Analyse gespeichert unter: $failedFile"
    } catch {
        err "Upload war nicht vollstaendig erfolgreich."
        err "CSV konnte nicht kopiert werden, Original liegt unter: $csvPath"
    }

    $timer.Stop()
    err "Laufzeit bis Fehler: $([math]::Round($timer.Elapsed.TotalSeconds, 1))s"

    exit 1
}
