#Requires -Version 7.1
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $scriptDir

$configFile = if ($env:CONFIG_FILE) { $env:CONFIG_FILE } else { Join-Path $scriptDir 'pipeline_settings.env' }

$requiredEnv = @(
    'LOG_DIR',
    'MACMON_BASE',
    'MACMON_USER',
    'MACMON_PASSWORD',
    'AZURE_CLIENT_ID',
    'AZURE_CLIENT_SECRET',
    'AZURE_TENANT_ID',
    'INTUNE_CSV_PATH'
)

$validHeaders = @(
    'Device name,Last check-in,Wi-Fi MAC,EthernetMAC',
    'Device name,Last check-in,Wi-Fi MAC,EthernetMac'
)

$EXIT_OK = 0
$EXIT_CONFIG = 10
$EXIT_NETWORK = 20
$EXIT_TLS = 30
$EXIT_AUTH = 40
$EXIT_API = 50
$EXIT_GRAPH = 60
$EXIT_DATA = 70
$EXIT_STRESS = 80

$stressRequests = if ($env:DIAG_STRESS_REQUESTS -and $env:DIAG_STRESS_REQUESTS -match '^\d+$') { [int]$env:DIAG_STRESS_REQUESTS } else { 20 }
$stressParallel = if ($env:DIAG_STRESS_PARALLEL -and $env:DIAG_STRESS_PARALLEL -match '^\d+$') { [int]$env:DIAG_STRESS_PARALLEL } else { 10 }
$stressTimeoutSeconds = if ($env:DIAG_STRESS_TIMEOUT_SECONDS -and $env:DIAG_STRESS_TIMEOUT_SECONDS -match '^\d+$') { [int]$env:DIAG_STRESS_TIMEOUT_SECONDS } else { 12 }
$stressFailThresholdPct = if ($env:DIAG_STRESS_FAIL_THRESHOLD_PCT -and $env:DIAG_STRESS_FAIL_THRESHOLD_PCT -match '^\d+$') { [int]$env:DIAG_STRESS_FAIL_THRESHOLD_PCT } else { 20 }
$diagWarnEthMissingPct = if ($env:DIAG_WARN_ETH_MISSING_PCT -and $env:DIAG_WARN_ETH_MISSING_PCT -match '^\d+$') { [int]$env:DIAG_WARN_ETH_MISSING_PCT } else { 90 }

$summary = [System.Collections.ArrayList]::new()

function Write-Check {
    param(
        [string]$Status,
        [string]$Name,
        [string]$Message
    )

    $color = switch ($Status) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'White' }
    }

    $line = "[{0}] {1} - {2}" -f $Status, $Name, $Message
    Write-Host $line -ForegroundColor $color
    [void]$summary.Add($line)
}

function Stop-WithCode {
    param(
        [int]$Code,
        [string]$Name,
        [string]$Message
    )

    Write-Check -Status 'FAIL' -Name $Name -Message $Message
    Write-Host "Exit-Code: $Code" -ForegroundColor Red
    exit $Code
}

function Import-ConfigFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Stop-WithCode -Code $EXIT_CONFIG -Name 'Config' -Message "Konfiguration nicht gefunden: $Path"
    }

    Get-Content $Path | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_]\w*)\s*=\s*"?([^"]*)"?\s*$') {
            Set-Item -Path "env:$($Matches[1])" -Value $Matches[2]
        }
    }
}

function Get-MacmonAuthHeader {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:MACMON_USER):$($env:MACMON_PASSWORD)"))
    return @{ Authorization = "Basic $b64"; Accept = 'application/json' }
}

function Test-TlsMessage {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    return ($Message -match 'SSL|TLS|secure channel|trust relationship|zertifikat|certificate|Authentication failed')
}

function Invoke-Az {
    param([string[]]$AzArgs)

    $azCmd = Get-Command az -ErrorAction SilentlyContinue
    if (-not $azCmd) {
        return [PSCustomObject]@{ Success = $false; Output = 'Azure CLI (az) nicht gefunden.' }
    }

    $output = & $azCmd.Source @AzArgs 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    return [PSCustomObject]@{ Success = $ok; Output = ($output | Out-String).Trim() }
}

function Invoke-MacmonLogin {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [int]$TimeoutSec
    )

    try {
        $resp = Invoke-WebRequest -UseBasicParsing -SkipCertificateCheck -Method Get -Uri $Uri -Headers $Headers -TimeoutSec $TimeoutSec -ErrorAction Stop
        return [PSCustomObject]@{ StatusCode = [int]$resp.StatusCode; Message = '' }
    } catch {
        $statusCode = 0
        $msg = [string]$_.Exception.Message
        if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        } elseif ($msg -match '\((\d{3})\)') {
            $statusCode = [int]$Matches[1]
        }
        return [PSCustomObject]@{ StatusCode = $statusCode; Message = $msg }
    }
}

Write-Host '=== Preflight Diagnose Start ===' -ForegroundColor Cyan

# Check 1: Config
Import-ConfigFile -Path $configFile
foreach ($k in $requiredEnv) {
    $item = Get-Item -Path "env:$k" -ErrorAction SilentlyContinue
    if (-not $item -or [string]::IsNullOrWhiteSpace($item.Value)) {
        Stop-WithCode -Code $EXIT_CONFIG -Name 'Config' -Message "Pflichtvariable fehlt oder leer: $k"
    }
}
Write-Check -Status 'OK' -Name 'Config' -Message 'Konfiguration und Pflichtvariablen sind gesetzt.'

# Check 2: DNS + Port 443
try {
    $uriObj = [System.Uri]$env:MACMON_BASE
    $hostName = $uriObj.Host
} catch {
    Stop-WithCode -Code $EXIT_CONFIG -Name 'Config' -Message "MACMON_BASE ist keine gueltige URL: $($env:MACMON_BASE)"
}

try {
    [void][System.Net.Dns]::GetHostAddresses($hostName)
} catch {
    Stop-WithCode -Code $EXIT_NETWORK -Name 'Network' -Message "DNS-Aufloesung fehlgeschlagen fuer $hostName"
}

$tnc = Test-NetConnection -ComputerName $hostName -Port 443 -WarningAction SilentlyContinue
if (-not $tnc.TcpTestSucceeded) {
    Stop-WithCode -Code $EXIT_NETWORK -Name 'Network' -Message "Port 443 nicht erreichbar fuer $hostName"
}
Write-Check -Status 'OK' -Name 'Network' -Message "DNS und Port 443 erreichbar fuer $hostName"

# Check 3: TLS/HTTPS handshake
try {
    $null = Invoke-WebRequest -UseBasicParsing -SkipCertificateCheck -Method Head -Uri $env:MACMON_BASE -TimeoutSec 10 -ErrorAction Stop
} catch {
    if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
        # TLS ok, HTTP status may still be 401/403/404
    } else {
        $msg = [string]$_.Exception.Message
        if (Test-TlsMessage -Message $msg) {
            Stop-WithCode -Code $EXIT_TLS -Name 'TLS' -Message "TLS/HTTPS Fehler: $msg"
        }
        Stop-WithCode -Code $EXIT_NETWORK -Name 'Network' -Message "HTTPS Verbindung fehlgeschlagen: $msg"
    }
}
Write-Check -Status 'OK' -Name 'TLS' -Message 'TLS/HTTPS Handshake erfolgreich.'

# Check 4: MacMon login check
$authHeaders = Get-MacmonAuthHeader
$login = Invoke-MacmonLogin -Uri $env:MACMON_BASE -Headers $authHeaders -TimeoutSec $stressTimeoutSeconds
if ($login.StatusCode -in 200, 404) {
    Write-Check -Status 'OK' -Name 'MacMon Login' -Message "Login-Check erfolgreich (HTTP $($login.StatusCode))."
} elseif ($login.StatusCode -in 401, 403) {
    Stop-WithCode -Code $EXIT_AUTH -Name 'MacMon Login' -Message "Authentifizierung fehlgeschlagen (HTTP $($login.StatusCode))."
} elseif ($login.StatusCode -eq 0 -or $login.StatusCode -ge 500) {
    Stop-WithCode -Code $EXIT_API -Name 'MacMon Login' -Message "API nicht gesund (HTTP $($login.StatusCode)). $($login.Message)"
} else {
    Stop-WithCode -Code $EXIT_API -Name 'MacMon Login' -Message "Unerwartete API-Antwort (HTTP $($login.StatusCode))."
}

# Check 5: Graph API auth + endpoint
$azLogin = Invoke-Az -AzArgs @(
    'login', '--service-principal',
    '-u', $env:AZURE_CLIENT_ID,
    '-p', $env:AZURE_CLIENT_SECRET,
    '--tenant', $env:AZURE_TENANT_ID,
    '--allow-no-subscriptions'
)
if (-not $azLogin.Success) {
    Stop-WithCode -Code $EXIT_GRAPH -Name 'Graph API' -Message "Azure Login fehlgeschlagen. $($azLogin.Output)"
}

$graphUri = 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$top=5&`$select=deviceName,lastSyncDateTime,wiFiMacAddress,ethernetMacAddress'
$azGraph = Invoke-Az -AzArgs @('rest', '--method', 'GET', '--uri', $graphUri, '--output', 'json')
if (-not $azGraph.Success) {
    Stop-WithCode -Code $EXIT_GRAPH -Name 'Graph API' -Message "Graph Endpoint Test fehlgeschlagen. $($azGraph.Output)"
}
Write-Check -Status 'OK' -Name 'Graph API' -Message 'Token und Endpoint-Test erfolgreich.'

# Check 6: CSV header + MAC sample
$csvPath = $env:INTUNE_CSV_PATH
if (-not (Test-Path $csvPath)) {
    Stop-WithCode -Code $EXIT_DATA -Name 'CSV' -Message "CSV nicht gefunden: $csvPath"
}

$firstLine = (Get-Content $csvPath -TotalCount 1 -Encoding UTF8).TrimEnd("`r")
if ($firstLine -notin $validHeaders) {
    Stop-WithCode -Code $EXIT_DATA -Name 'CSV' -Message "Unerwarteter CSV-Header: $firstLine"
}

$sampleRows = Import-Csv -Path $csvPath -Encoding UTF8 | Select-Object -First 200
if (-not $sampleRows -or $sampleRows.Count -eq 0) {
    Write-Check -Status 'WARN' -Name 'CSV' -Message 'CSV ist leer, Header aber gueltig.'
} else {
    $wifiCount = ($sampleRows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.'Wi-Fi MAC') }).Count
    $ethCount = ($sampleRows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.'EthernetMAC') -or -not [string]::IsNullOrWhiteSpace($_.'EthernetMac') }).Count
    $ethMissingPct = [math]::Round((($sampleRows.Count - $ethCount) / [double]$sampleRows.Count) * 100, 1)

    if ($ethMissingPct -ge $diagWarnEthMissingPct) {
        Write-Check -Status 'WARN' -Name 'CSV' -Message "Ethernet-MAC in Stichprobe haeufig leer ($ethMissingPct% von $($sampleRows.Count))."
    } else {
        Write-Check -Status 'OK' -Name 'CSV' -Message "Header gueltig, Stichprobe ok (Wi-Fi=$wifiCount, Ethernet=$ethCount, Rows=$($sampleRows.Count))."
    }
}

# Check 7: short stress test
$stressUri     = $env:MACMON_BASE
$stressHeaders = $authHeaders
$stressTimeout = $stressTimeoutSeconds

$stressResults = 1..$stressRequests | ForEach-Object -Parallel {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -SkipCertificateCheck -Method Get -Uri $using:stressUri -Headers $using:stressHeaders -TimeoutSec $using:stressTimeout -ErrorAction Stop
        [PSCustomObject]@{ Ok = $true; StatusCode = [int]$r.StatusCode; Message = '' }
    } catch {
        $statusCode = 0
        $msg = [string]$_.Exception.Message
        if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        } elseif ($msg -match '\((\d{3})\)') {
            $statusCode = [int]$Matches[1]
        }
        [PSCustomObject]@{ Ok = $false; StatusCode = $statusCode; Message = $msg }
    }
} -ThrottleLimit $stressParallel

$okCount   = ($stressResults | Where-Object { $_.Ok }).Count
$failCount = ($stressResults | Where-Object { -not $_.Ok }).Count

$failPct = if ($stressRequests -eq 0) { 0 } else { [math]::Round(($failCount / [double]$stressRequests) * 100, 1) }
if ($failPct -ge $stressFailThresholdPct) {
    Stop-WithCode -Code $EXIT_STRESS -Name 'Stress' -Message "Stresstest auffaellig: $failCount/$stressRequests fehlgeschlagen ($failPct%)."
}
if ($failCount -gt 0) {
    Write-Check -Status 'WARN' -Name 'Stress' -Message "Teilweise Fehler im Stresstest: $failCount/$stressRequests ($failPct%)."
} else {
    Write-Check -Status 'OK' -Name 'Stress' -Message "Stresstest stabil: $okCount/$stressRequests erfolgreich."
}

Write-Host '=== Preflight Diagnose Ende ===' -ForegroundColor Cyan
Write-Host "Exit-Code: $EXIT_OK" -ForegroundColor Green
exit $EXIT_OK
