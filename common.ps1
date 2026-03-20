# common.ps1 – Gemeinsame Hilfsfunktionen (dot-source in allen PS-Skripten)

$global:_LogFile       = $null
$global:_LogScriptName = ''

function Initialize-Logger {
    param([string]$LogDir, [string]$Name)
    $global:_LogScriptName = $Name
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $global:_LogFile = Join-Path $LogDir "$Name.log"
}

function Write-Log {
    param([string]$Level, [string]$Message)
    $name = if ($global:_LogScriptName) { $global:_LogScriptName } else { 'script' }
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$ts [$name] [$Level] $Message"
    Write-Host $line
    if ($global:_LogFile) {
        Add-Content -Path $global:_LogFile -Value $line -Encoding UTF8
    }
}

function info { param([string]$msg) Write-Log 'INFO'  $msg }
function warn { param([string]$msg) Write-Log 'WARN'  $msg }
function err  { param([string]$msg) Write-Log 'ERROR' $msg }
function fail { param([string]$msg) err $msg; exit 1 }

function Import-Config {
    param([string]$Path = './pipeline_settings.env')

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = './pipeline_settings.env'
    }

    $Path = $Path.Trim()

    if (-not (Test-Path $Path)) {
        Write-Host "FEHLER: Konfiguration fehlt: $Path"
        Write-Host 'Bitte zuerst pipeline_settings.env anlegen.'
        exit 1
    }
    Get-Content $Path | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_]\w*)\s*=\s*"?([^"]*)"?\s*$') {
            Set-Item -Path "env:$($Matches[1])" -Value $Matches[2]
        }
    }
}

function Assert-Env {
    param([string]$Name)
    $item = Get-Item -Path "env:$Name" -ErrorAction SilentlyContinue
    if (-not $item -or [string]::IsNullOrEmpty($item.Value)) {
        fail "$Name ist leer (in pipeline_settings.env setzen)"
    }
}

function Invoke-AzCli {
    $azCmd = Get-Command az -ErrorAction SilentlyContinue
    $azPath = $null
    if ($azCmd) {
        $azPath = $azCmd.Source
    } else {
        $candidates = @(
            'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd',
            'C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\az.cmd',
            'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.exe'
        )
        $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $found) {
            fail 'Azure CLI (az) nicht gefunden. Bitte installieren oder PATH setzen.'
        }
        $azPath = $found
    }

    if ($azPath -match '\.cmd$') {
        $quotedExe = '"' + $azPath + '"'
        $quotedArgs = @()
        foreach ($a in $Args) {
            $arg = [string]$a
            $arg = $arg -replace '"', '\\"'
            $quotedArgs += ('"' + $arg + '"')
        }
        $cmdLine = "$quotedExe $($quotedArgs -join ' ')"
        $output = & $env:ComSpec /d /s /c $cmdLine 2>&1
    } else {
        $output = & $azPath @Args 2>&1
    }

    if ($LASTEXITCODE -ne 0) {
        fail "Azure CLI Fehler (Exit $LASTEXITCODE): $output"
    }
    return $output
}
