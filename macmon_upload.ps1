#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $scriptDir
. "$scriptDir\common.ps1"

$configFile = if ($env:CONFIG_FILE) { $env:CONFIG_FILE } else { Join-Path $scriptDir 'pipeline_settings.env' }
Import-Config $configFile

Assert-Env 'LOG_DIR'
Assert-Env 'MACMON_BASE'
Assert-Env 'MACMON_USER'
Assert-Env 'MACMON_PASSWORD'
Assert-Env 'INTUNE_CSV_PATH'
Assert-Env 'FAILED_DIR'

Initialize-Logger $env:LOG_DIR 'macmon_upload'

$timer = [System.Diagnostics.Stopwatch]::StartNew()

if (-not ('ServerCertificateValidationCallback' -as [type])) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

$csvPath = $env:INTUNE_CSV_PATH
if (-not (Test-Path $csvPath)) {
    fail "Datei nicht gefunden: $csvPath. Bitte zuerst .\intunes_download.ps1 oder .\run_all.ps1 ausfuehren."
}

$firstLine = (Get-Content $csvPath -TotalCount 1 -Encoding UTF8).TrimEnd("`r")
$validHeaders = @(
    'Device name,Last check-in,Wi-Fi MAC,EthernetMAC',
    'Device name,Last check-in,Wi-Fi MAC,EthernetMac'
)
if ($firstLine -notin $validHeaders) { fail "Unerwarteter CSV-Header: $firstLine" }
info "CSV-Header validiert."

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:MACMON_USER):$($env:MACMON_PASSWORD)"))
$authHeaders = @{ Authorization = "Basic $b64"; Accept = 'application/json' }
$httpTimeoutSeconds = if ($env:MACMON_TIMEOUT_SECONDS -and $env:MACMON_TIMEOUT_SECONDS -match '^\d+$') { [int]$env:MACMON_TIMEOUT_SECONDS } else { 20 }

function Invoke-MacmonRequest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET','POST')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Body
    )

    try {
        if ($Method -eq 'POST') {
            $resp = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Uri -Headers $authHeaders -Body $Body -ContentType 'application/json; charset=utf-8' -TimeoutSec $httpTimeoutSeconds -ErrorAction Stop
        } else {
            $resp = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $Uri -Headers $authHeaders -TimeoutSec $httpTimeoutSeconds -ErrorAction Stop
        }
        return [PSCustomObject]@{ StatusCode = [int]$resp.StatusCode; Body = [string]$resp.Content }
    } catch {
        $statusCode = 0
        $content = ''
        
        # Try to extract response from WebException
        if ($_.Exception -is [System.Net.WebException]) {
            $webEx = [System.Net.WebException]$_.Exception
            if ($webEx.Response) {
                $httpResp = [System.Net.HttpWebResponse]$webEx.Response
                $statusCode = [int]$httpResp.StatusCode
                try {
                    $stream = $httpResp.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $content = $reader.ReadToEnd()
                    $reader.Close()
                    $stream.Close()
                } catch { }
            }
        }
        
        # Fallback: Parse ErrorRecord for HTTP status
        if ($statusCode -eq 0) {
            $errMsg = [string]$_.Exception.Message
            if ($errMsg -match '\((\d{3})\)') {
                $statusCode = [int]$Matches[1]
            }
            if ([string]::IsNullOrEmpty($content)) {
                $content = $errMsg
            }
        }
        
        # Check response body for "not found" pattern (macmon API code 1010)
        if ($statusCode -eq 0 -and $content -match '"code"\s*:\s*1010|not found') {
            $statusCode = 404
        }
        
        return [PSCustomObject]@{ StatusCode = $statusCode; Body = $content }
    }
}

function Normalize-Mac {
    param([string]$InputText)
    $clean = (($InputText | ForEach-Object { $_ }) -replace '[^0-9a-fA-F]', '').ToUpper()
    if ($clean.Length -ne 12) { return '' }
    return $clean -replace '^(.{2})(.{2})(.{2})(.{2})(.{2})(.{2})$', '$1-$2-$3-$4-$5-$6'
}

$csvData = Import-Csv -Path $csvPath -Encoding UTF8
info "Import gestartet. Quelle: $csvPath"

# ── Collect all MACs first ───────────────────────────────────────────────────
$macList = [System.Collections.ArrayList]::new()
$uniqueMacs = New-Object System.Collections.Generic.HashSet[string]
foreach ($row in $csvData) {
    $deviceName = [string]$row.'Device name'
    if ([string]::IsNullOrWhiteSpace($deviceName)) { continue }

    $wifiMac = Normalize-Mac ([string]$row.'Wi-Fi MAC')
    $ethProp = $row.PSObject.Properties['EthernetMAC']
    $ethMac = if ($ethProp) { Normalize-Mac ([string]$row.'EthernetMAC') } else { Normalize-Mac ([string]$row.'EthernetMac') }

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

$deviceCount = ($csvData | Where-Object { -not [string]::IsNullOrWhiteSpace($_.'Device name') }).Count
$totalMacs = $macList.Count
$skippedCount = ($deviceCount * 2) - $totalMacs
$keepCsv = ($env:KEEP_INTUNE_CSV -eq 'true')

info "Gesammelt: $totalMacs MAC-Adressen von $deviceCount Geraeten (uebersprungen: $skippedCount ohne gueltige MAC)"

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

# ── Parallel Processing Setup ────────────────────────────────────────────────
$parallelLimit = if ($env:MACMON_PARALLEL) { [int]$env:MACMON_PARALLEL } else { 20 }
info "Starte parallele Verarbeitung mit max $parallelLimit gleichzeitigen Requests..."

# Script block for parallel execution
$checkMacScript = {
    param($MacEntry, $BaseUrl, $AuthHeaders, $TimeoutSec)
    
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
    
    $uri = "$BaseUrl/$($MacEntry.Mac)"
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $uri -Headers $AuthHeaders -TimeoutSec $TimeoutSec -ErrorAction Stop
        return [PSCustomObject]@{ MacEntry = $MacEntry; StatusCode = [int]$resp.StatusCode; Body = $resp.Content; Action = 'exists' }
    } catch {
        $statusCode = 0
        $content = ''
        if ($_.Exception -is [System.Net.WebException] -and $_.Exception.Response) {
            $httpResp = [System.Net.HttpWebResponse]$_.Exception.Response
            $statusCode = [int]$httpResp.StatusCode
            try {
                $stream = $httpResp.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $content = $reader.ReadToEnd()
                $reader.Close()
            } catch { }
        }
        if ($statusCode -eq 0) {
            $errMsg = [string]$_.Exception.Message
            if ($errMsg -match '\((\d{3})\)') { $statusCode = [int]$Matches[1] }
            elseif ($errMsg -match '\b([1-5]\d{2})\b') { $statusCode = [int]$Matches[1] }
            if ([string]::IsNullOrEmpty($content)) { $content = $errMsg }
        }
        if ($statusCode -eq 0 -and $content -match '"code"\s*:\s*1010|not found') { $statusCode = 404 }
        
        $action = if ($statusCode -eq 404) { 'create' } else { 'error' }
        return [PSCustomObject]@{ MacEntry = $MacEntry; StatusCode = $statusCode; Body = $content; Action = $action }
    }
}

# Create runspace pool
$runspacePool = [RunspaceFactory]::CreateRunspacePool(1, $parallelLimit)
$runspacePool.Open()

# Start all check tasks
$jobs = [System.Collections.ArrayList]::new()
foreach ($entry in $macList) {
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $runspacePool
    [void]$ps.AddScript($checkMacScript).AddArgument($entry).AddArgument($env:MACMON_BASE).AddArgument($authHeaders).AddArgument($httpTimeoutSeconds)
    $handle = $ps.BeginInvoke()
    [void]$jobs.Add([PSCustomObject]@{ PowerShell = $ps; Handle = $handle })
}

# Collect results
$checkResults = [System.Collections.ArrayList]::new()
foreach ($job in $jobs) {
    $result = $job.PowerShell.EndInvoke($job.Handle)
    [void]$checkResults.Add($result)
    $job.PowerShell.Dispose()
}
$runspacePool.Close()
$runspacePool.Dispose()

# Process results
$existsCount = 0
$errorCount = 0
$transportErrorCount = 0
$authErrorCount = 0
$serverErrorCount = 0
$otherErrorCount = 0
$toCreate = [System.Collections.ArrayList]::new()

foreach ($r in $checkResults) {
    $entry = $r.MacEntry
    switch ($r.Action) {
        'exists' {
            $existsCount++
            info "[$($entry.MacType)] Bereits vorhanden: $($entry.Mac)"
        }
        'create' {
            [void]$toCreate.Add($entry)
            info "[$($entry.MacType)] Nicht gefunden: $($entry.Mac) -> wird angelegt"
        }
        'error' {
            $errorCount++
            if ($r.StatusCode -eq 0) { $transportErrorCount++ }
            elseif ($r.StatusCode -in 401, 403) { $authErrorCount++ }
            elseif ($r.StatusCode -ge 500) { $serverErrorCount++ }
            else { $otherErrorCount++ }
            err "[$($entry.MacType)] Fehler beim Pruefen $($entry.Mac) (HTTP $($r.StatusCode))"
            if ($r.Body) { err "  Details: $($r.Body)" }
        }
    }
}

info "Pruefung abgeschlossen: $existsCount vorhanden, $($toCreate.Count) neu anzulegen, $errorCount Fehler"

# ── Create missing endpoints (parallel) ──────────────────────────────────────
$createdCount = 0

if ($toCreate.Count -gt 0) {
    info "Lege $($toCreate.Count) neue Endpunkte an..."
    
    $createMacScript = {
        param($MacEntry, $BaseUrl, $AuthHeaders, $TimeoutSec)
        
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
        
        $payload = @{ mac = $MacEntry.Mac; active = $true; comment = "$($MacEntry.DeviceName) ($($MacEntry.MacType))" } | ConvertTo-Json -Compress
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $BaseUrl -Headers $AuthHeaders -Body $payload -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutSec -ErrorAction Stop
            return [PSCustomObject]@{ MacEntry = $MacEntry; StatusCode = [int]$resp.StatusCode; Body = $resp.Content; Success = $true }
        } catch {
            $statusCode = 0
            $content = ''
            if ($_.Exception -is [System.Net.WebException] -and $_.Exception.Response) {
                $httpResp = [System.Net.HttpWebResponse]$_.Exception.Response
                $statusCode = [int]$httpResp.StatusCode
                try {
                    $stream = $httpResp.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $content = $reader.ReadToEnd()
                    $reader.Close()
                } catch { }
            }
            if ($statusCode -eq 0) {
                $errMsg = [string]$_.Exception.Message
                if ($errMsg -match '\((\d{3})\)') { $statusCode = [int]$Matches[1] }
                elseif ($errMsg -match '\b([1-5]\d{2})\b') { $statusCode = [int]$Matches[1] }
                if ([string]::IsNullOrEmpty($content)) { $content = $errMsg }
            }
            return [PSCustomObject]@{ MacEntry = $MacEntry; StatusCode = $statusCode; Body = $content; Success = $false }
        }
    }
    
    $runspacePool2 = [RunspaceFactory]::CreateRunspacePool(1, $parallelLimit)
    $runspacePool2.Open()
    
    $createJobs = [System.Collections.ArrayList]::new()
    foreach ($entry in $toCreate) {
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $runspacePool2
        [void]$ps.AddScript($createMacScript).AddArgument($entry).AddArgument($env:MACMON_BASE).AddArgument($authHeaders).AddArgument($httpTimeoutSeconds)
        $handle = $ps.BeginInvoke()
        [void]$createJobs.Add([PSCustomObject]@{ PowerShell = $ps; Handle = $handle })
    }
    
    foreach ($job in $createJobs) {
        $result = $job.PowerShell.EndInvoke($job.Handle)
        $entry = $result.MacEntry
        if ($result.Success -or $result.StatusCode -in 200, 201) {
            $createdCount++
            info "[$($entry.MacType)] Angelegt: $($entry.Mac)"
        } elseif ($result.StatusCode -eq 409) {
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
        $job.PowerShell.Dispose()
    }
    $runspacePool2.Close()
    $runspacePool2.Dispose()
}

$checkedCount = $totalMacs
info "Import beendet. Geraete=$deviceCount, Geprueft=$checkedCount, Uebersprungen=$skippedCount, Vorhanden=$existsCount, Neu=$createdCount, Fehler=$errorCount"
if ($errorCount -gt 0) {
    info "Fehlerzusammenfassung: Transport(HTTP0)=$transportErrorCount, Auth(401/403)=$authErrorCount, Server(5xx)=$serverErrorCount, Sonstige=$otherErrorCount"
}

# ── Ergebnis-Handling ─────────────────────────────────────────────────────────

if ($createdCount -eq 0) {
    info "Keine Aenderungen in macmon vorgenommen (0 neue Eintraege)."
    if     ($checkedCount -eq 0)               { warn "Keine pruefbaren MAC-Adressen in der CSV gefunden." }
    elseif ($errorCount -gt 0)                 { warn "Keine neuen Endpunkte angelegt, weil API-Fehler aufgetreten sind." }
    elseif ($existsCount -eq $checkedCount)    { warn "Keine neuen Endpunkte angelegt, alle geprueften MACs existieren bereits." }
}

if ($errorCount -eq 0) {
    if ($keepCsv) {
        info "CSV beibehalten (KEEP_INTUNE_CSV=true): $csvPath"
    } else {
        Remove-Item $csvPath -Force
        info "CSV geloescht: $csvPath"
    }
    $timer.Stop()
    info "Laufzeit gesamt: $([math]::Round($timer.Elapsed.TotalSeconds, 1))s"
} else {
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
