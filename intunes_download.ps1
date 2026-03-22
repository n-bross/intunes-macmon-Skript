#Requires -Version 7.1
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $scriptDir
. "$scriptDir\common.ps1"

$configFile = if ($env:CONFIG_FILE) { $env:CONFIG_FILE } else { Join-Path $scriptDir 'pipeline_settings.env' }
Import-Config $configFile

Assert-Env 'LOG_DIR'
Assert-Env 'INTUNE_CSV_PATH'
Assert-Env 'HOURS_DEFAULT'
Assert-Env 'AZURE_CLIENT_ID'
Assert-Env 'AZURE_CLIENT_SECRET'
Assert-Env 'AZURE_TENANT_ID'

Initialize-Logger $env:LOG_DIR 'intune_download'

$timer = [System.Diagnostics.Stopwatch]::StartNew()

$outputFile = if ($env:OUTPUT_FILE) { $env:OUTPUT_FILE } else { $env:INTUNE_CSV_PATH }
$hours      = if ($env:HOURS)       { $env:HOURS }       else { $env:HOURS_DEFAULT }

if ($hours -notmatch '^\d+$') { fail "HOURS muss eine positive Ganzzahl sein (aktuell: '$hours')" }

Invoke-AzCli login --service-principal `
    -u $env:AZURE_CLIENT_ID `
    -p $env:AZURE_CLIENT_SECRET `
    --tenant $env:AZURE_TENANT_ID `
    --allow-no-subscriptions | Out-Null

$firstRun = ($env:FIRST_RUN -eq 'true')

if ($firstRun) {
    info "Login erfolgreich. Start Export (Erster Lauf - alle Geraete)"
    $uri = (
        'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices' +
        "?`$orderby=$([uri]::EscapeDataString('enrolledDateTime desc'))" +
        '&$select=id,deviceName,lastSyncDateTime,wiFiMacAddress,ethernetMacAddress'
    )
} else {
    $sinceUtc = (Get-Date).ToUniversalTime().AddHours(-[int]$hours).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $filter   = "enrolledDateTime ge $sinceUtc"
    info "Login erfolgreich. Start Export: HOURS=$hours"
    $uri = (
        'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices' +
        "?`$filter=$([uri]::EscapeDataString($filter))" +
        "&`$orderby=$([uri]::EscapeDataString('enrolledDateTime desc'))" +
        '&$select=id,deviceName,lastSyncDateTime,wiFiMacAddress,ethernetMacAddress'
    )
}

$jsonStr = Invoke-AzCli rest --method GET --uri $uri --output json
$devices = ($jsonStr | ConvertFrom-Json).value

function ConvertTo-CsvField([string]$v) {
    if (-not $v -or $v -eq 'None' -or $v -eq 'null') { return '' }
    $v = $v.Trim() -replace "`r|`n", ''
    # Feld in Anführungszeichen wenn es Kommas oder Anführungszeichen enthält
    if ($v -match '[,"]') {
        return '"' + $v.Replace('"', '""') + '"'
    }
    return $v
}

function Get-EthernetMacFromDetail {
    param([string]$DeviceId)

    if ([string]::IsNullOrWhiteSpace($DeviceId)) { return '' }

    try {
        $detailUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices('$DeviceId')?`$select=ethernetMacAddress"
        $detailJson = Invoke-AzCli rest --method GET --uri $detailUri --output json
        $detail = $detailJson | ConvertFrom-Json
        return [string]$detail.ethernetMacAddress
    } catch {
        return ''
    }
}

$header = 'Device name,Last check-in,Wi-Fi MAC,EthernetMAC'
$rows = [System.Collections.ArrayList]::new()
$missingWifiCount = 0
$missingEthCount = 0
$missingBothCount = 0
$missingMacReportEnabled = ($env:INTUNE_MISSING_MAC_REPORT -eq 'true')
$missingMacReportRows = [System.Collections.ArrayList]::new()
$enrichEthernetEnabled = ($env:INTUNE_ENRICH_ETHERNET_FROM_DETAIL -eq 'true')
$enrichEthernetMax = if ($env:INTUNE_ENRICH_ETHERNET_MAX -and $env:INTUNE_ENRICH_ETHERNET_MAX -match '^\d+$') { [int]$env:INTUNE_ENRICH_ETHERNET_MAX } else { 0 }
$enrichTried = 0
$enrichFilled = 0

foreach ($d in $devices) {
    $nameRaw = [string]$d.deviceName
    $deviceId = [string]$d.id
    $checkinRaw = [string]$d.lastSyncDateTime
    $wifiRaw = [string]$d.wiFiMacAddress
    $ethRaw = [string]$d.ethernetMacAddress

    if (($enrichEthernetEnabled) -and [string]::IsNullOrWhiteSpace($ethRaw) -and (($enrichEthernetMax -eq 0) -or ($enrichTried -lt $enrichEthernetMax))) {
        $enrichTried++
        $ethFromDetail = Get-EthernetMacFromDetail -DeviceId $deviceId
        if (-not [string]::IsNullOrWhiteSpace($ethFromDetail)) {
            $ethRaw = $ethFromDetail
            $enrichFilled++
        }
    }

    $name    = ConvertTo-CsvField $nameRaw
    $checkin = ConvertTo-CsvField $checkinRaw
    $wifi    = ConvertTo-CsvField $wifiRaw
    $eth     = ConvertTo-CsvField $ethRaw
    [void]$rows.Add("$name,$checkin,$wifi,$eth")

    $wifiMissing = [string]::IsNullOrWhiteSpace($wifiRaw) -or $wifiRaw -eq 'None' -or $wifiRaw -eq 'null'
    $ethMissing = [string]::IsNullOrWhiteSpace($ethRaw) -or $ethRaw -eq 'None' -or $ethRaw -eq 'null'

    if ($wifiMissing) { $missingWifiCount++ }
    if ($ethMissing) { $missingEthCount++ }
    if ($wifiMissing -and $ethMissing) { $missingBothCount++ }

    if ($missingMacReportEnabled -and ($wifiMissing -or $ethMissing)) {
        $reason = if ($wifiMissing -and $ethMissing) { 'missing_both' } elseif ($ethMissing) { 'missing_ethernet' } else { 'missing_wifi' }
        [void]$missingMacReportRows.Add([PSCustomObject]@{
            DeviceName = $nameRaw
            LastCheckIn = $checkinRaw
            WifiMac = $wifiRaw
            EthernetMac = $ethRaw
            MissingReason = $reason
        })
    }
}

if (@($devices).Count -gt 0) {
    $deviceTotal = @($devices).Count
    $pctWifiMissing = [math]::Round(($missingWifiCount / [double]$deviceTotal) * 100, 1)
    $pctEthMissing = [math]::Round(($missingEthCount / [double]$deviceTotal) * 100, 1)
    $pctBothMissing = [math]::Round(($missingBothCount / [double]$deviceTotal) * 100, 1)
    info "MAC-Diagnose: Wi-Fi leer=$missingWifiCount/$deviceTotal ($pctWifiMissing%), Ethernet leer=$missingEthCount/$deviceTotal ($pctEthMissing%), beide leer=$missingBothCount/$deviceTotal ($pctBothMissing%)"
    if ($enrichEthernetEnabled) {
        $maxText = if ($enrichEthernetMax -eq 0) { 'unbegrenzt' } else { [string]$enrichEthernetMax }
        info "Ethernet-Enrichment: versucht=$enrichTried, erfolgreich nachgezogen=$enrichFilled, max=$maxText"
    }
} else {
    info 'MAC-Diagnose: Keine Geraete aus Graph erhalten.'
}

if ($missingMacReportEnabled) {
    $reportPath = Join-Path $scriptDir 'intune_missing_macs.csv'
    $missingMacReportRows | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
    info "Missing-MAC-Report geschrieben: $reportPath (Zeilen=$($missingMacReportRows.Count))"
}

if ((Test-Path $outputFile) -and (Get-Item $outputFile).Length -gt 0) {
    Add-Content -Path $outputFile -Value $rows -Encoding UTF8
    info "Export ergaenzt: $(@($rows).Count) neue Zeilen -> $outputFile"
} else {
    Set-Content -Path $outputFile -Value $header -Encoding UTF8
    Add-Content -Path $outputFile -Value $rows -Encoding UTF8
    info "Export erstellt: $(@($rows).Count) Zeilen -> $outputFile"
}

$timer.Stop()
info "Laufzeit gesamt: $([math]::Round($timer.Elapsed.TotalSeconds, 1))s"
