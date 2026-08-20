#Requires -Version 5.1
<#
.SYNOPSIS
    Erstellt E-Mail-Alerts fuer die Bandbreitenauslastung eines Azure VPN Gateways.
.DESCRIPTION
    Legt eine Azure-Monitor Action Group mit E-Mail-Empfaengern an und erstellt darauf
    aufbauend Metrik-Alerts fuer die Bandbreitenauslastung eines Virtual Network Gateways
    vom Typ "Vpn".

    Da Azure-Metrik-Alerts ausschliesslich mit absoluten Schwellwerten arbeiten, liest das
    Script die konfigurierte SKU und Generation des Gateways aus, ermittelt den zugehoerigen
    Aggregat-Durchsatz laut Microsoft-Dokumentation und rechnet den gewuenschten
    Prozentwert in Bytes pro Sekunde um.

    Es werden zwei getrennte Regeln erstellt (S2S und P2S), weil Azure mehrere Bedingungen
    innerhalb einer Regel mit UND verknuepft. Beide Metriken teilen sich jedoch dasselbe
    Durchsatzlimit der SKU.

    Das Script ist idempotent: bereits vorhandene Regeln gleichen Namens werden entfernt
    und mit den aktuellen Werten neu angelegt.
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
    .\New-VpnGatewayBandwidthAlert.ps1
#>

# =========================================================================
#  PARAMETER - hier anpassen
# =========================================================================
$SubscriptionId    = ""                      # leer = aktuelle Subscription
$ResourceGroupName = "RG-Netzwerk"           # Resource Group des Gateways
$GatewayName       = "LDK_S2S_VPN_AVD"       # Name des Virtual Network Gateways

# E-Mail-Empfaenger: Anzeigename = E-Mail-Adresse
$Recipients = @{
    "Alexander Ortha" = "alerts@ortha-itsolutions.de"
    # "IT Support"    = "support@example.de"
}

# Action Group
$ActionGroupName      = "AG-VPNGW-Bandwidth"     # Name der Action Group
$ActionGroupShortName = "VPNGWBW"                # max. 12 Zeichen, erscheint in der E-Mail

# Alert-Konfiguration
$ThresholdPercent     = 75                       # Schwellwert in Prozent des SKU-Limits
$WindowSize           = "15m"                    # Auswertungsfenster (1m/5m/15m/30m/1h/6h/12h/24h)
$EvaluationFrequency  = "5m"                     # Pruefintervall (1m/5m/15m/30m/1h)
$Severity             = 2                        # 0=kritisch, 1=Fehler, 2=Warnung, 3=Info, 4=ausfuehrlich
$AutoMitigate         = $true                    # Alarm automatisch aufloesen
$CreateP2SAlert       = $true                    # zusaetzliche Regel fuer P2S-Bandbreite

$MinAzCliVersion      = "2.60.0"

# =========================================================================
#  SKU-LIMITS (Stand 06/2026, Microsoft Learn "About gateway SKUs")
#  Wert = Aggregat-Durchsatz in Mbps
# =========================================================================
$SkuThroughput = @{
    "Generation1" = @{
        "Basic"    = 100
        "VpnGw1"   = 650
        "VpnGw2"   = 1000
        "VpnGw3"   = 1250
        "VpnGw1AZ" = 650
        "VpnGw2AZ" = 1000
        "VpnGw3AZ" = 1250
    }
    "Generation2" = @{
        "VpnGw2"   = 1250
        "VpnGw3"   = 2500
        "VpnGw4"   = 5000
        "VpnGw5"   = 10000
        "VpnGw2AZ" = 1250
        "VpnGw3AZ" = 2500
        "VpnGw4AZ" = 5000
        "VpnGw5AZ" = 10000
    }
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

function New-BandwidthAlert {
    <# Legt eine Metrik-Alert-Regel an; entfernt eine bestehende Regel gleichen Namens. #>
    param(
        [string]$AlertName,
        [string]$MetricName,
        [double]$ThresholdBytes,
        [string]$ResourceId,
        [string]$ResourceGroup,
        [string]$ActionGroupId,
        [string]$Description
    )

    $existing = az monitor metrics alert show --name $AlertName --resource-group $ResourceGroup --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Info "Regel '$AlertName' existiert bereits - wird neu erstellt"
        az monitor metrics alert delete --name $AlertName --resource-group $ResourceGroup --output none 2>$null
    }

    $condition = "avg $MetricName > $ThresholdBytes"
    $autoMit   = if ($AutoMitigate) { "true" } else { "false" }

    az monitor metrics alert create `
        --name $AlertName `
        --resource-group $ResourceGroup `
        --scopes $ResourceId `
        --condition $condition `
        --window-size $WindowSize `
        --evaluation-frequency $EvaluationFrequency `
        --severity $Severity `
        --action $ActionGroupId `
        --description $Description `
        --auto-mitigate $autoMit `
        --output none 2>$null

    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Regel erstellt: $AlertName"
        Write-Sub "Metrik      : $MetricName"
        Write-Sub "Bedingung   : Durchschnitt > $([math]::Round($ThresholdBytes,0)) Bytes/s"
        return $true
    } else {
        Write-Err "Regel '$AlertName' konnte nicht erstellt werden."
        return $false
    }
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

if ($Recipients.Count -eq 0) {
    Write-Err "Keine E-Mail-Empfaenger im Parameterblock hinterlegt."
    exit 1
}
Write-Ok "Empfaenger konfiguriert: $($Recipients.Count)"

if ($ActionGroupShortName.Length -gt 12) {
    Write-Err "ActionGroupShortName darf maximal 12 Zeichen lang sein (aktuell: $($ActionGroupShortName.Length))."
    exit 1
}

# =========================================================================
#  GATEWAY UND SCHWELLWERT
# =========================================================================
Write-Section "GATEWAY UND SCHWELLWERT"

Write-Log "Lese Gateway '$GatewayName'..."
$gwJson = az network vnet-gateway show --name $GatewayName --resource-group $ResourceGroupName --output json 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gwJson)) {
    Write-Err "Gateway '$GatewayName' in Resource Group '$ResourceGroupName' nicht gefunden."
    exit 1
}
$gw         = $gwJson | ConvertFrom-Json
$resourceId = $gw.id
$sku        = $gw.sku.name
$generation = $gw.vpnGatewayGeneration
if ([string]::IsNullOrWhiteSpace($generation)) { $generation = "Generation1" }

Write-Ok "Gateway gefunden: $GatewayName"
Write-Sub "SKU        : $sku"
Write-Sub "Generation : $generation"
Write-Sub "Region     : $($gw.location)"

if (-not $SkuThroughput[$generation] -or -not $SkuThroughput[$generation][$sku]) {
    Write-Err "Kein Durchsatzwert fuer SKU '$sku' ($generation) hinterlegt."
    exit 1
}

$skuMbps        = $SkuThroughput[$generation][$sku]
$thresholdMbps  = [math]::Round($skuMbps * ($ThresholdPercent / 100), 2)
$thresholdBytes = [math]::Round(($thresholdMbps * 1000000) / 8, 0)

Write-Host ""
Write-Info "Schwellwertberechnung:"
Write-Sub "SKU-Limit       : $skuMbps Mbps"
Write-Sub "Schwelle        : $ThresholdPercent %"
Write-Sub "entspricht      : $thresholdMbps Mbps"
Write-Sub "Alert-Wert      : $thresholdBytes Bytes/s" "Yellow"
Write-Host ""
Write-Warn "Bei einem SKU-Wechsel muss dieses Script erneut ausgefuehrt werden."

# =========================================================================
#  ACTION GROUP
# =========================================================================
Write-Section "ACTION GROUP"

$agExists = az monitor action-group show --name $ActionGroupName --resource-group $ResourceGroupName --output json 2>$null
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($agExists)) {
    Write-Info "Action Group '$ActionGroupName' existiert bereits - wird aktualisiert"
    az monitor action-group delete --name $ActionGroupName --resource-group $ResourceGroupName --output none 2>$null
}

# --action email <Name> <Adresse> je Empfaenger
$agArgs = @(
    "monitor", "action-group", "create",
    "--name", $ActionGroupName,
    "--resource-group", $ResourceGroupName,
    "--short-name", $ActionGroupShortName,
    "--output", "none"
)
foreach ($r in $Recipients.GetEnumerator()) {
    $safeName = ($r.Key -replace '[^a-zA-Z0-9 ]', '')
    $agArgs += @("--action", "email", $safeName, $r.Value)
}

Write-Log "Erstelle Action Group..."
& az @agArgs 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Err "Action Group konnte nicht erstellt werden."
    exit 1
}
Write-Ok "Action Group erstellt: $ActionGroupName"
foreach ($r in $Recipients.GetEnumerator()) {
    Write-Sub "$($r.Key) -> $($r.Value)"
}

$actionGroupId = az monitor action-group show `
    --name $ActionGroupName `
    --resource-group $ResourceGroupName `
    --query "id" --output tsv 2>$null

if ([string]::IsNullOrWhiteSpace($actionGroupId)) {
    Write-Err "Action-Group-Id konnte nicht ermittelt werden."
    exit 1
}

# =========================================================================
#  ALERT-REGELN
# =========================================================================
Write-Section "ALERT-REGELN"

$created = 0

Write-Log "Erstelle S2S-Bandbreiten-Alert..."
$okS2S = New-BandwidthAlert `
    -AlertName      "ALERT-$GatewayName-S2S-Bandwidth-$ThresholdPercent" `
    -MetricName     "AverageBandwidth" `
    -ThresholdBytes $thresholdBytes `
    -ResourceId     $resourceId `
    -ResourceGroup  $ResourceGroupName `
    -ActionGroupId  $actionGroupId `
    -Description    "S2S-Bandbreite von $GatewayName ueberschreitet $ThresholdPercent % des SKU-Limits ($sku, $skuMbps Mbps)."
if ($okS2S) { $created++ }

if ($CreateP2SAlert) {
    Write-Host ""
    Write-Log "Erstelle P2S-Bandbreiten-Alert..."
    $okP2S = New-BandwidthAlert `
        -AlertName      "ALERT-$GatewayName-P2S-Bandwidth-$ThresholdPercent" `
        -MetricName     "P2SBandwidth" `
        -ThresholdBytes $thresholdBytes `
        -ResourceId     $resourceId `
        -ResourceGroup  $ResourceGroupName `
        -ActionGroupId  $actionGroupId `
        -Description    "P2S-Bandbreite von $GatewayName ueberschreitet $ThresholdPercent % des SKU-Limits ($sku, $skuMbps Mbps)."
    if ($okP2S) { $created++ }
}

# =========================================================================
#  ZUSAMMENFASSUNG
# =========================================================================
Write-Section "ZUSAMMENFASSUNG"

if ($created -gt 0) {
    Write-Ok "$created Alert-Regel(n) aktiv"
    Write-Sub "Gateway     : $GatewayName ($sku)"
    Write-Sub "Schwellwert : $thresholdMbps Mbps ($ThresholdPercent % von $skuMbps Mbps)"
    Write-Sub "Fenster     : Durchschnitt ueber $WindowSize, Pruefung alle $EvaluationFrequency"
    Write-Sub "Empfaenger  : $($Recipients.Values -join ', ')"
    Write-Host ""
    Write-Info "S2S und P2S teilen sich das Aggregat-Limit - beide Regeln feuern unabhaengig."
    Write-Info "Test der Zustellung: az monitor action-group test-notifications create --action-group-name $ActionGroupName --resource-group $ResourceGroupName --alert-type metric"
    Write-Host ""
    Write-Info "Regeln pruefen:"
    Write-Sub "az monitor metrics alert list --resource-group $ResourceGroupName --output table"
} else {
    Write-Err "Es wurde keine Regel erstellt."
}

Write-Line
