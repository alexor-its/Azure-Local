#Requires -Version 5.1
<#
.SYNOPSIS
    Aktiviert die Diagnose-Logs eines Azure VPN Gateways in einem Log Analytics Workspace.
.DESCRIPTION
    Richtet die vollstaendige Diagnose-Kette fuer ein Virtual Network Gateway vom Typ "Vpn" ein:

      1. Prueft, ob der angegebene Log Analytics Workspace existiert und legt ihn bei Bedarf an.
      2. Ermittelt die vom Gateway tatsaechlich unterstuetzten Log-Kategorien dynamisch ueber
         die Azure API, statt sie fest zu verdrahten.
      3. Erstellt beziehungsweise aktualisiert die Diagnose-Einstellung mit den gewuenschten
         Kategorien und optional den Plattform-Metriken.
      4. Verifiziert das Ergebnis und gibt vorbereitete KQL-Abfragen aus.

    Ueber den Parameter $LogProfile wird gesteuert, welche Kategorien aktiviert werden.
    Das Profil "Standard" verzichtet bewusst auf IKEDiagnosticLog, da dieser Kanal jede
    einzelne IKE-Nachricht protokolliert und im Dauerbetrieb den groessten Teil der
    Ingestion-Kosten verursacht.
.NOTES
    =========================================================================
    Author      : Alexander Ortha
    Company     : Alexander Ortha IT Solutions
    Contact     : https://ortha-itsolutions.de/
    Created     : 20.08.2026
    Version     : 1.0.0
    Copyright   : (c) 2026 Alexander Ortha IT Solutions. All rights reserved.
    -------------------------------------------------------------------------
    Code created by Alexander Ortha.
    Development supported through AI-tools.
    =========================================================================
.EXAMPLE
    .\Enable-VpnGatewayDiagnostics.ps1
#>

# =========================================================================
#  PARAMETER - hier anpassen
# =========================================================================
$SubscriptionId       = ""                       # leer = aktuelle Subscription
$ResourceGroupName    = "rg-AVDmgmt"             # Resource Group des Gateways
$GatewayName          = "LDK_S2S_VPN_AVD"        # Name des Virtual Network Gateways

# Log Analytics Workspace
$WorkspaceName        = "law-vpngw-monitoring"   # Name des Workspace
$WorkspaceRG          = "rg-AVDmgmt"             # Resource Group des Workspace
$WorkspaceLocation    = ""                       # leer = Region des Gateways uebernehmen
$WorkspaceRetention   = 30                       # Aufbewahrung in Tagen (30-730)
$CreateWorkspace      = $true                    # Workspace anlegen, falls nicht vorhanden

# Diagnose-Einstellung
$DiagnosticName       = "diag-vpngw"             # Name der Diagnose-Einstellung
$IncludeMetrics       = $true                    # AllMetrics zusaetzlich in den Workspace
$LogProfile           = "Standard"               # Standard | Troubleshooting | Minimal

$MinAzCliVersion      = "2.60.0"

# =========================================================================
#  LOG-PROFILE
#  Standard        = Dauerbetrieb, ohne IKE (kostenoptimiert)
#  Troubleshooting = alles, fuer die aktive Fehlersuche
#  Minimal         = nur Tunnel-Statuswechsel
# =========================================================================
$LogProfiles = @{
    "Standard" = @(
        "GatewayDiagnosticLog",
        "TunnelDiagnosticLog",
        "RouteDiagnosticLog",
        "P2SDiagnosticLog"
    )
    "Troubleshooting" = @(
        "GatewayDiagnosticLog",
        "TunnelDiagnosticLog",
        "RouteDiagnosticLog",
        "IKEDiagnosticLog",
        "P2SDiagnosticLog"
    )
    "Minimal" = @(
        "TunnelDiagnosticLog"
    )
}

# =========================================================================
#  HILFSFUNKTIONEN
# =========================================================================
function Write-Line    { Write-Host ("=" * 60) -ForegroundColor White }
function Write-Section { param([string]$T) Write-Host "" ; Write-Line ; Write-Host "[ $T ]" -ForegroundColor White ; Write-Line }
function Write-Ok      { param([string]$M) Write-Host "OK   $M" -ForegroundColor Green }
function Write-Err     { param([string]$M) Write-Host "FEHL $M" -ForegroundColor Red }
function Write-Warn    { param([string]$M) Write-Host "WARN $M" -ForegroundColor Yellow }
function Write-Info    { param([string]$M) Write-Host "INFO $M" -ForegroundColor Cyan }
function Write-Sub     { param([string]$M,[string]$C = "Gray") Write-Host ("    " + $M) -ForegroundColor $C }
function Write-Log     { param([string]$M) Write-Host ("[" + (Get-Date -Format "HH:mm:ss") + "] $M") -ForegroundColor Cyan }

function Compare-Version {
    param([string]$Current, [string]$Required)
    try { return ([version]$Current) -ge ([version]$Required) } catch { return $true }
}

function Write-JsonParamFile {
    <#
        Schreibt ein Objekt als JSON in eine temporaere Datei und liefert den az-Parameter
        in @-Notation zurueck. Vermeidet Quoting-Probleme der Azure CLI unter Windows.
    #>
    param([object]$Value, [string]$FileName)
    $path = Join-Path $env:TEMP $FileName
    $json = $Value | ConvertTo-Json -Depth 5 -Compress
    if ($Value -is [System.Array] -and $Value.Count -eq 1) { $json = "[" + $json + "]" }
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return @{ Path = $path; Param = "@$path" }
}

# =========================================================================
#  PRE-CHECK
# =========================================================================
Write-Section "PRE-CHECK"

Write-Info "Pruefe Azure CLI..."
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Err "Azure CLI nicht gefunden. Installation: https://aka.ms/installazurecliwindows"
    exit 1
}

$verJson    = az version --output json 2>$null | ConvertFrom-Json
$cliVersion = $verJson.'azure-cli'
Write-Ok "Azure CLI gefunden: $cliVersion"

if (-not (Compare-Version -Current $cliVersion -Required $MinAzCliVersion)) {
    Write-Warn "Version aelter als $MinAzCliVersion - Update empfohlen (az upgrade)"
} else {
    Write-Ok "Azure CLI Version ausreichend (>= $MinAzCliVersion)"
}

Write-Info "Pruefe Azure-Anmeldung..."
$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Warn "Kein Login vorhanden - starte 'az login'"
    az login --output none
    $account = az account show --output json 2>$null | ConvertFrom-Json
    if (-not $account) { Write-Err "Anmeldung fehlgeschlagen." ; exit 1 }
}
Write-Ok "Login vorhanden: $($account.user.name)"

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    az account set --subscription $SubscriptionId --output none 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Err "Subscription '$SubscriptionId' konnte nicht gesetzt werden." ; exit 1 }
    $account = az account show --output json | ConvertFrom-Json
}
Write-Ok "Subscription: $($account.name)"

if (-not $LogProfiles.ContainsKey($LogProfile)) {
    Write-Err "Unbekanntes Log-Profil '$LogProfile'. Zulaessig: $($LogProfiles.Keys -join ', ')"
    exit 1
}
Write-Ok "Log-Profil: $LogProfile"

# =========================================================================
#  GATEWAY
# =========================================================================
Write-Section "GATEWAY"

Write-Log "Lese Gateway '$GatewayName'..."
$gwJson = az network vnet-gateway show --name $GatewayName --resource-group $ResourceGroupName --output json 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gwJson)) {
    Write-Err "Gateway '$GatewayName' in Resource Group '$ResourceGroupName' nicht gefunden."
    exit 1
}
$gw         = $gwJson | ConvertFrom-Json
$resourceId = $gw.id

Write-Ok "Gateway gefunden: $GatewayName"
Write-Sub "SKU    : $($gw.sku.name) / $($gw.vpnGatewayGeneration)"
Write-Sub "Region : $($gw.location)"

if ([string]::IsNullOrWhiteSpace($WorkspaceLocation)) {
    $WorkspaceLocation = $gw.location
    Write-Info "Workspace-Region aus Gateway uebernommen: $WorkspaceLocation"
}

# =========================================================================
#  LOG ANALYTICS WORKSPACE
# =========================================================================
Write-Section "LOG ANALYTICS WORKSPACE"

Write-Log "Pruefe Workspace '$WorkspaceName'..."
$wsJson = az monitor log-analytics workspace show `
    --workspace-name $WorkspaceName `
    --resource-group $WorkspaceRG `
    --output json 2>$null

if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($wsJson)) {
    $ws = $wsJson | ConvertFrom-Json
    Write-Ok "Workspace vorhanden: $WorkspaceName"
    Write-Sub "Region      : $($ws.location)"
    Write-Sub "Aufbewahrung: $($ws.retentionInDays) Tage"
    Write-Sub "SKU         : $($ws.sku.name)"
} else {
    if (-not $CreateWorkspace) {
        Write-Err "Workspace '$WorkspaceName' nicht gefunden und CreateWorkspace = false."
        exit 1
    }

    Write-Warn "Workspace nicht vorhanden - wird angelegt"

    # Resource Group anlegen, falls noetig
    az group show --name $WorkspaceRG --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Info "Resource Group '$WorkspaceRG' wird angelegt..."
        az group create --name $WorkspaceRG --location $WorkspaceLocation --output none 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Err "Resource Group konnte nicht angelegt werden." ; exit 1 }
        Write-Ok "Resource Group erstellt: $WorkspaceRG"
    }

    Write-Log "Erstelle Workspace (kann einige Sekunden dauern)..."
    az monitor log-analytics workspace create `
        --workspace-name $WorkspaceName `
        --resource-group $WorkspaceRG `
        --location $WorkspaceLocation `
        --retention-time $WorkspaceRetention `
        --output none 2>$null

    if ($LASTEXITCODE -ne 0) {
        Write-Err "Workspace konnte nicht erstellt werden."
        exit 1
    }

    $ws = az monitor log-analytics workspace show `
        --workspace-name $WorkspaceName `
        --resource-group $WorkspaceRG `
        --output json 2>$null | ConvertFrom-Json

    Write-Ok "Workspace erstellt: $WorkspaceName"
    Write-Sub "Region      : $WorkspaceLocation"
    Write-Sub "Aufbewahrung: $WorkspaceRetention Tage"
}

$workspaceId = $ws.id
if ([string]::IsNullOrWhiteSpace($workspaceId)) {
    Write-Err "Workspace-Resource-Id konnte nicht ermittelt werden."
    exit 1
}

if ($ws.location -ne $gw.location) {
    Write-Warn "Workspace liegt in einer anderen Region als das Gateway - es fallen Egress-Kosten an."
}

# =========================================================================
#  VERFUEGBARE KATEGORIEN
# =========================================================================
Write-Section "LOG-KATEGORIEN"

Write-Log "Ermittle unterstuetzte Kategorien..."
$catJson = az monitor diagnostic-settings categories list --resource $resourceId --output json 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($catJson)) {
    Write-Err "Kategorien konnten nicht abgefragt werden."
    exit 1
}
$categories = ($catJson | ConvertFrom-Json).value

$availableLogs = @($categories | Where-Object { $_.categoryType -eq "Logs" } | ForEach-Object { $_.name })
$requestedLogs = $LogProfiles[$LogProfile]

Write-Info "Vom Gateway unterstuetzt:"
foreach ($c in ($availableLogs | Sort-Object)) {
    if ($requestedLogs -contains $c) { Write-Sub "[x] $c" "Green" }
    else                             { Write-Sub "[ ] $c" "Gray" }
}

$enableLogs = @($requestedLogs | Where-Object { $availableLogs -contains $_ })
$skipped    = @($requestedLogs | Where-Object { $availableLogs -notcontains $_ })

if ($skipped.Count -gt 0) {
    Write-Warn "Nicht unterstuetzt und uebersprungen: $($skipped -join ', ')"
}
if ($enableLogs.Count -eq 0) {
    Write-Err "Keine aktivierbare Kategorie uebrig."
    exit 1
}
Write-Ok "Zu aktivieren: $($enableLogs.Count) Kategorie(n)"

# =========================================================================
#  DIAGNOSE-EINSTELLUNG
# =========================================================================
Write-Section "DIAGNOSE-EINSTELLUNG"

$existing = az monitor diagnostic-settings show `
    --name $DiagnosticName `
    --resource $resourceId `
    --output json 2>$null

if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existing)) {
    Write-Info "Einstellung '$DiagnosticName' existiert bereits - wird neu erstellt"
    az monitor diagnostic-settings delete --name $DiagnosticName --resource $resourceId --output none 2>$null
}

# JSON-Parameter ueber Dateien uebergeben (Quoting-sicher unter Windows)
$logsArray = @()
foreach ($c in $enableLogs) { $logsArray += @{ category = $c; enabled = $true } }
$logsFile = Write-JsonParamFile -Value $logsArray -FileName "vpngw-diag-logs.json"

$diagArgs = @(
    "monitor", "diagnostic-settings", "create",
    "--name", $DiagnosticName,
    "--resource", $resourceId,
    "--workspace", $workspaceId,
    "--logs", $logsFile.Param,
    "--output", "none"
)

$metricsFile = $null
if ($IncludeMetrics) {
    $metricsArray = @(@{ category = "AllMetrics"; enabled = $true })
    $metricsFile  = Write-JsonParamFile -Value $metricsArray -FileName "vpngw-diag-metrics.json"
    $diagArgs += @("--metrics", $metricsFile.Param)
}

Write-Log "Erstelle Diagnose-Einstellung..."
& az @diagArgs 2>$null
$diagExit = $LASTEXITCODE

# Temporaere Dateien aufraeumen
Remove-Item $logsFile.Path -Force -ErrorAction SilentlyContinue
if ($metricsFile) { Remove-Item $metricsFile.Path -Force -ErrorAction SilentlyContinue }

if ($diagExit -ne 0) {
    Write-Err "Diagnose-Einstellung konnte nicht erstellt werden."
    exit 1
}

Write-Ok "Diagnose-Einstellung erstellt: $DiagnosticName"
foreach ($c in $enableLogs) { Write-Sub "$c" "Green" }
if ($IncludeMetrics) { Write-Sub "AllMetrics" "Green" }

# =========================================================================
#  VERIFIKATION
# =========================================================================
Write-Section "VERIFIKATION"

$verify = az monitor diagnostic-settings show `
    --name $DiagnosticName `
    --resource $resourceId `
    --output json 2>$null | ConvertFrom-Json

if ($verify) {
    $activeLogs = @($verify.logs | Where-Object { $_.enabled -eq $true } | ForEach-Object { $_.category })
    Write-Ok "Einstellung aktiv"
    Write-Sub "Name       : $($verify.name)"
    Write-Sub "Workspace  : $WorkspaceName"
    Write-Sub "Kategorien : $($activeLogs -join ', ')"
} else {
    Write-Warn "Verifikation lieferte kein Ergebnis - im Portal pruefen."
}

Write-Host ""
Write-Warn "Erste Log-Eintraege erscheinen typischerweise nach 10-15 Minuten."

# =========================================================================
#  KQL-ABFRAGEN
# =========================================================================
Write-Section "KQL-ABFRAGEN"

Write-Info "Tunnel-Statuswechsel (Verbindungsabbrueche):"
Write-Sub 'AzureDiagnostics'
Write-Sub '| where Category == "TunnelDiagnosticLog"'
Write-Sub '| where TimeGenerated > ago(7d)'
Write-Sub '| project TimeGenerated, remoteIP_s, status_s, stateChangeReason_s, instance_s'
Write-Sub '| order by TimeGenerated desc'

Write-Host ""
Write-Info "Haeufigkeit der Abbrueche je Remote-Gateway:"
Write-Sub 'AzureDiagnostics'
Write-Sub '| where Category == "TunnelDiagnosticLog" and status_s == "Disconnected"'
Write-Sub '| where TimeGenerated > ago(30d)'
Write-Sub '| summarize Abbrueche = count() by remoteIP_s, stateChangeReason_s'
Write-Sub '| order by Abbrueche desc'

Write-Host ""
Write-Info "Routing-Aenderungen und BGP-Ereignisse:"
Write-Sub 'AzureDiagnostics'
Write-Sub '| where Category == "RouteDiagnosticLog"'
Write-Sub '| where TimeGenerated > ago(7d)'
Write-Sub '| project TimeGenerated, OperationName, Message'
Write-Sub '| order by TimeGenerated desc'

if ($enableLogs -contains "IKEDiagnosticLog") {
    Write-Host ""
    Write-Info "IKE-Fehler und Rekeying:"
    Write-Sub 'AzureDiagnostics'
    Write-Sub '| where Category == "IKEDiagnosticLog"'
    Write-Sub '| where TimeGenerated > ago(24h)'
    Write-Sub '| where Message contains "FAIL" or Message contains "REKEY"'
    Write-Sub '| project TimeGenerated, Message'
    Write-Sub '| order by TimeGenerated desc'
}

Write-Host ""
Write-Info "Ingestion-Volumen pruefen (Kostenkontrolle):"
Write-Sub 'AzureDiagnostics'
Write-Sub '| where ResourceType == "VIRTUALNETWORKGATEWAYS"'
Write-Sub '| where TimeGenerated > ago(7d)'
Write-Sub '| summarize MB = sum(_BilledSize) / 1024 / 1024 by Category'
Write-Sub '| order by MB desc'

Write-Host ""
Write-Line
