#Requires -Version 7.1
$ErrorActionPreference = 'Stop'

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $scriptDir
. "$scriptDir\common.ps1"

$configFile    = if ($env:CONFIG_FILE) { $env:CONFIG_FILE } else { Join-Path $scriptDir 'pipeline_settings.env' }
$intuneScript  = "$scriptDir\intunes_download.ps1"
$macmonScript  = "$scriptDir\macmon_upload.ps1"

if (-not (Test-Path $intuneScript)) { fail "Nicht gefunden: $intuneScript" }
if (-not (Test-Path $macmonScript)) { fail "Nicht gefunden: $macmonScript" }
if (-not (Test-Path $configFile))   { fail "Konfiguration fehlt: $configFile" }

Import-Config $configFile
if ([string]::IsNullOrWhiteSpace($env:LOG_DIR)) {
	$env:LOG_DIR = Join-Path $scriptDir 'logs'
}
Initialize-Logger $env:LOG_DIR 'run_all'

$env:CONFIG_FILE = $configFile

$overallTimer = [System.Diagnostics.Stopwatch]::StartNew()

Assert-Env 'AZURE_CLIENT_ID'
Assert-Env 'AZURE_TENANT_ID'
Assert-Env 'AZURE_CLIENT_SECRET'
Assert-Env 'MACMON_PASSWORD'

try {
	info "Starte Intune-Export..."
	$intuneTimer = [System.Diagnostics.Stopwatch]::StartNew()
	& $intuneScript
	$intuneTimer.Stop()

	info "Starte MacMon-Upload..."
	$macmonTimer = [System.Diagnostics.Stopwatch]::StartNew()
	& $macmonScript
	$macmonTimer.Stop()

	$overallTimer.Stop()

	info "Laufzeit Uebersicht:"
	info "- intunes_download.ps1: $([math]::Round($intuneTimer.Elapsed.TotalSeconds, 1))s"
	info "- macmon_upload.ps1: $([math]::Round($macmonTimer.Elapsed.TotalSeconds, 1))s"
	info "- Gesamt (run_all.ps1): $([math]::Round($overallTimer.Elapsed.TotalSeconds, 1))s"
	info "Fertig. Logs liegen unter: $($env:LOG_DIR)"
} catch {
	$overallTimer.Stop()
	err "Laufzeit bis Fehler (run_all.ps1): $([math]::Round($overallTimer.Elapsed.TotalSeconds, 1))s"
	throw
}


# Todo: Ich Gruppe wieso manchmal Default ist manchmal nicht
# Todo1: Was passiert mit doppelten mac adressen
# Todo2: Anletung umschreiben 
