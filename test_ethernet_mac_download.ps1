#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $scriptDir
. "$scriptDir\common.ps1"

$configFile = if ($env:CONFIG_FILE) { $env:CONFIG_FILE } else { Join-Path $scriptDir 'pipeline_settings.env' }
Import-Config $configFile

Assert-Env 'LOG_DIR'
Assert-Env 'AZURE_CLIENT_ID'
Assert-Env 'AZURE_CLIENT_SECRET'
Assert-Env 'AZURE_TENANT_ID'

Initialize-Logger $env:LOG_DIR 'test_ethernet_mac_download'
$timer = [System.Diagnostics.Stopwatch]::StartNew()

$top = if ($env:ETH_TEST_TOP -and $env:ETH_TEST_TOP -match '^\d+$') { [int]$env:ETH_TEST_TOP } else { 300 }
$maxDetail = if ($env:ETH_TEST_MAX_DETAIL -and $env:ETH_TEST_MAX_DETAIL -match '^\d+$') { [int]$env:ETH_TEST_MAX_DETAIL } else { 500 }
$reportFile = if ($env:ETH_TEST_REPORT_FILE) { $env:ETH_TEST_REPORT_FILE } else { Join-Path $scriptDir 'ethernet_mac_test_report.csv' }

function Get-DeviceDetailEth {
    param([string]$DeviceId)

    if ([string]::IsNullOrWhiteSpace($DeviceId)) {
        return [PSCustomObject]@{ EthernetMac = ''; Error = 'missing_device_id' }
    }

    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices('$DeviceId')?`$select=ethernetMacAddress"

    try {
        $json = Invoke-AzCli rest --method GET --uri $uri --output json
        $obj = $json | ConvertFrom-Json
        return [PSCustomObject]@{ EthernetMac = [string]$obj.ethernetMacAddress; Error = '' }
    } catch {
        return [PSCustomObject]@{ EthernetMac = ''; Error = [string]$_.Exception.Message }
    }
}

info "Starte Ethernet-MAC-Test (top=$top, maxDetail=$maxDetail)"

Invoke-AzCli login --service-principal `
    -u $env:AZURE_CLIENT_ID `
    -p $env:AZURE_CLIENT_SECRET `
    --tenant $env:AZURE_TENANT_ID `
    --allow-no-subscriptions | Out-Null

$uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$top=$top&`$select=id,deviceName,operatingSystem,lastSyncDateTime,wiFiMacAddress,ethernetMacAddress"
$jsonStr = Invoke-AzCli rest --method GET --uri $uri --output json
$devices = ($jsonStr | ConvertFrom-Json).value

if (-not $devices -or @($devices).Count -eq 0) {
    fail 'Keine Geraete aus Graph erhalten. Bitte Berechtigungen und Tenant pruefen.'
}

$total = @($devices).Count
$listEthPresent = 0
$listEthMissing = 0
$detailTried = 0
$detailFilled = 0
$detailError = 0
$finalMissing = 0

$reportRows = [System.Collections.ArrayList]::new()

foreach ($d in $devices) {
    $id = [string]$d.id
    $name = [string]$d.deviceName
    $os = [string]$d.operatingSystem
    $lastSync = [string]$d.lastSyncDateTime
    $wifi = [string]$d.wiFiMacAddress
    $listEth = [string]$d.ethernetMacAddress

    $finalEth = $listEth
    $source = 'list'
    $detailErr = ''

    if ([string]::IsNullOrWhiteSpace($listEth)) {
        $listEthMissing++

        if ($detailTried -lt $maxDetail) {
            $detailTried++
            $detail = Get-DeviceDetailEth -DeviceId $id

            if (-not [string]::IsNullOrWhiteSpace($detail.EthernetMac)) {
                $finalEth = [string]$detail.EthernetMac
                $detailFilled++
                $source = 'detail'
            } else {
                $source = 'none'
                $detailErr = [string]$detail.Error
                if (-not [string]::IsNullOrWhiteSpace($detailErr)) {
                    $detailError++
                }
            }
        } else {
            $source = 'none'
            $detailErr = 'detail_limit_reached'
        }
    } else {
        $listEthPresent++
    }

    if ([string]::IsNullOrWhiteSpace($finalEth)) {
        $finalMissing++
    }

    [void]$reportRows.Add([PSCustomObject]@{
        DeviceName = $name
        OperatingSystem = $os
        LastSyncDateTime = $lastSync
        WifiMac = $wifi
        EthernetMac_List = $listEth
        EthernetMac_Final = $finalEth
        EthSource = $source
        DetailError = $detailErr
        DeviceId = $id
    })
}

$reportRows | Export-Csv -Path $reportFile -NoTypeInformation -Encoding UTF8

$pct = {
    param([int]$value, [int]$base)
    if ($base -le 0) { return '0.0' }
    return [string]([math]::Round(($value / [double]$base) * 100, 1))
}

info "Ergebnis Ethernet-MAC-Test:"
info "- Gesamtgeraete: $total"
info "- Ethernet in LIST vorhanden: $listEthPresent ($(& $pct $listEthPresent $total)%)"
info "- Ethernet in LIST leer: $listEthMissing ($(& $pct $listEthMissing $total)%)"
info "- Detail-Checks versucht: $detailTried"
info "- Ethernet ueber DETAIL nachgezogen: $detailFilled ($(& $pct $detailFilled $detailTried)%)"
info "- DETAIL-Fehler: $detailError"
info "- Final ohne Ethernet-MAC: $finalMissing ($(& $pct $finalMissing $total)%)"
info "- Report: $reportFile"

$examples = $reportRows |
    Where-Object { $_.EthSource -eq 'detail' } |
    Select-Object -First 10 DeviceName, EthernetMac_List, EthernetMac_Final, EthSource

if ($examples -and @($examples).Count -gt 0) {
    info 'Beispiele (LIST leer, DETAIL gefuellt):'
    foreach ($e in $examples) {
        info "  - $($e.DeviceName): list='$($e.EthernetMac_List)' -> detail='$($e.EthernetMac_Final)'"
    }
}

$timer.Stop()
info "Laufzeit gesamt: $([math]::Round($timer.Elapsed.TotalSeconds, 1))s"
