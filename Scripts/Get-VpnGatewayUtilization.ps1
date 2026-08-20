#Requires -Version 5.1
<#
.SYNOPSIS
    Ermittelt die Auslastung eines Azure VPN Gateways und vergleicht sie mit den SKU-Limits.
.DESCRIPTION
    Liest ueber Azure CLI die Azure-Monitor-Metriken eines Virtual Network Gateways vom
    Typ "Vpn" aus (S2S-/P2S-Bandbreite, P2S-Verbindungen, Tunnel-Bandbreite, Paket-Drops,
    Flow-Counts) und stellt die gemessenen Spitzen- und Durchschnittswerte den offiziellen
    Limits der konfigurierten SKU/Generation gegenueber.

    Ausgegeben wird eine prozentuale Auslastung je Kennzahl inklusive Empfehlung, ob ein
    Upgrade oder ein Downgrade der SKU sinnvoll ist.
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
    .\Get-VpnGatewayUtilization.ps1
#>

# =========================================================================
#  PARAMETER - hier anpassen
# =========================================================================
$SubscriptionId    = ""                      # leer = aktuelle Subscription
$ResourceGroupName = "RG-Netzwerk"           # Resource Group des Gateways
$GatewayName       = "LDK_S2S_VPN_AVD"       # Name des Virtual Network Gateways
$DaysBack          = 7                       # Auswertungszeitraum in Tagen (max. 93)
$Interval          = "PT5M"                  # Granularitaet: PT1M/PT5M/PT1H
$MinAzCliVersion   = "2.60.0"                # Mindestversion Azure CLI
$WarnThresholdPct  = 70                      # ab hier Warnung (Upgrade pruefen)
$IdleThresholdPct  = 20                      # darunter Hinweis (Downgrade pruefen)

# =========================================================================
#  SKU-LIMITS (Stand 06/2026, Microsoft Learn "About gateway SKUs")
#  Mbps = Aggregat-Durchsatz | S2S = Tunnel | P2S = IKEv2/OpenVPN | SSTP = 128
# =========================================================================
$SkuLimits = @{
    "Generation1" = @{
        "Basic"    = @{ Mbps = 100;   S2S = 10;  P2S = 0;     PPS = 0      }
        "VpnGw1"   = @{ Mbps = 650;   S2S = 30;  P2S = 250;   PPS = 62000  }
        "VpnGw2"   = @{ Mbps = 1000;  S2S = 30;  P2S = 500;   PPS = 100000 }
        "VpnGw3"   = @{ Mbps = 1250;  S2S = 30;  P2S = 1000;  PPS = 120000 }
        "VpnGw1AZ" = @{ Mbps = 650;   S2S = 30;  P2S = 250;   PPS = 62000  }
        "VpnGw2AZ" = @{ Mbps = 1000;  S2S = 30;  P2S = 500;   PPS = 110000 }
        "VpnGw3AZ" = @{ Mbps = 1250;  S2S = 30;  P2S = 1000;  PPS = 120000 }
    }
    "Generation2" = @{
        "VpnGw2"   = @{ Mbps = 1250;  S2S = 30;  P2S = 500;   PPS = 120000 }
        "VpnGw3"   = @{ Mbps = 2500;  S2S = 30;  P2S = 1000;  PPS = 140000 }
        "VpnGw4"   = @{ Mbps = 5000;  S2S = 100; P2S = 5000;  PPS = 220000 }
        "VpnGw5"   = @{ Mbps = 10000; S2S = 100; P2S = 10000; PPS = 220000 }
        "VpnGw2AZ" = @{ Mbps = 1250;  S2S = 30;  P2S = 500;   PPS = 120000 }
        "VpnGw3AZ" = @{ Mbps = 2500;  S2S = 30;  P2S = 1000;  PPS = 140000 }
        "VpnGw4AZ" = @{ Mbps = 5000;  S2S = 100; P2S = 5000;  PPS = 220000 }
        "VpnGw5AZ" = @{ Mbps = 10000; S2S = 100; P2S = 10000; PPS = 220000 }
    }
}

$FlowLimit = 250000   # Limit distinkter 5-Tupel-Flows pro Gateway

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

function Get-MetricSeries {
    <#  Liefert @{ Avg = <double>; Max = <double>; Series = @{ name = @{Avg;Max} } } #>
    param(
        [string]$ResourceId,
        [string]$MetricName,
        [string]$StartTime,
        [string]$EndTime,
        [string]$Interval,
        [string]$SplitBy = $null
    )

    $cmd = @(
        "monitor", "metrics", "list",
        "--resource", $ResourceId,
        "--metric", $MetricName,
        "--aggregation", "Average", "Maximum",
        "--interval", $Interval,
        "--start-time", $StartTime,
        "--end-time", $EndTime,
        "--output", "json"
    )
    if ($SplitBy) { $cmd += @("--filter", "$SplitBy eq '*'") }

    $raw = & az @cmd 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return $null }

    try { $json = $raw | ConvertFrom-Json } catch { return $null }
    if (-not $json.value -or $json.value.Count -eq 0) { return $null }

    $result = @{ Avg = 0.0; Max = 0.0; Series = @{}; HasData = $false }
    $allAvg = New-Object System.Collections.ArrayList

    foreach ($ts in $json.value[0].timeseries) {
        $label = "gesamt"
        if ($ts.metadatavalues -and $ts.metadatavalues.Count -gt 0) {
            $label = $ts.metadatavalues[0].value
        }

        $sAvg = New-Object System.Collections.ArrayList
        $sMax = 0.0
        foreach ($p in $ts.data) {
            if ($null -ne $p.average) { [void]$sAvg.Add([double]$p.average) ; [void]$allAvg.Add([double]$p.average) }
            if ($null -ne $p.maximum -and [double]$p.maximum -gt $sMax) { $sMax = [double]$p.maximum }
        }
        if ($sAvg.Count -gt 0 -or $sMax -gt 0) {
            $result.HasData = $true
            $sMean = 0.0
            if ($sAvg.Count -gt 0) { $sMean = ($sAvg | Measure-Object -Average).Average }
            if ($sMax -eq 0 -and $sAvg.Count -gt 0) { $sMax = ($sAvg | Measure-Object -Maximum).Maximum }
            $result.Series[$label] = @{ Avg = $sMean; Max = $sMax }
            if ($sMax -gt $result.Max) { $result.Max = $sMax }
        }
    }
    if ($allAvg.Count -gt 0) { $result.Avg = ($allAvg | Measure-Object -Average).Average }
    return $result
}

function ConvertTo-Mbps { param([double]$BytesPerSecond) return [math]::Round(($BytesPerSecond * 8) / 1000000, 2) }

function Write-Usage {
    <# Einheitliche Zeile: Wert / Limit / Prozent inkl. Farbcodierung #>
    param([string]$Label, [double]$Value, [double]$Limit, [string]$Unit)

    if ($Limit -le 0) { Write-Sub ("{0,-26} {1} {2}" -f $Label, $Value, $Unit) ; return 0 }
    $pct = [math]::Round(($Value / $Limit) * 100, 1)

    $color = "Green"
    if ($pct -ge $WarnThresholdPct) { $color = "Yellow" }
    if ($pct -ge 90)                { $color = "Red" }

    Write-Sub ("{0,-26} {1} / {2} {3}  ({4} %)" -f $Label, $Value, $Limit, $Unit, $pct) $color
    return $pct
}

# =========================================================================
#  PRE-CHECK
# =========================================================================
Write-Section "PRE-CHECK"

Write-Info "Pruefe Azure CLI..."
$azCli = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCli) {
    Write-Err "Azure CLI nicht gefunden. Installation: https://aka.ms/installazurecliwindows"
    exit 1
}

$verJson = az version --output json 2>$null | ConvertFrom-Json
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
Write-Sub "Id: $($account.id)"

# =========================================================================
#  GATEWAY-INFORMATIONEN
# =========================================================================
Write-Section "GATEWAY"

Write-Log "Lese Gateway '$GatewayName'..."
$gwJson = az network vnet-gateway show `
    --name $GatewayName `
    --resource-group $ResourceGroupName `
    --output json 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gwJson)) {
    Write-Err "Gateway '$GatewayName' in Resource Group '$ResourceGroupName' nicht gefunden."
    exit 1
}
$gw = $gwJson | ConvertFrom-Json

$sku        = $gw.sku.name
$generation = $gw.vpnGatewayGeneration
if ([string]::IsNullOrWhiteSpace($generation)) { $generation = "Generation1" }
$resourceId = $gw.id

Write-Ok "Gateway gefunden: $GatewayName"
Write-Sub "SKU            : $sku"
Write-Sub "Generation     : $generation"
Write-Sub "Typ            : $($gw.gatewayType) / $($gw.vpnType)"
Write-Sub "Active-Active  : $($gw.activeActive)"
Write-Sub "BGP            : $($gw.enableBgp)"
Write-Sub "Region         : $($gw.location)"

if (-not $SkuLimits[$generation] -or -not $SkuLimits[$generation][$sku]) {
    Write-Err "Keine Limit-Daten fuer SKU '$sku' ($generation) hinterlegt."
    exit 1
}
$limits = $SkuLimits[$generation][$sku]
Write-Info "Limits laut Microsoft: $($limits.Mbps) Mbps | $($limits.S2S) S2S-Tunnel | $($limits.P2S) P2S (IKEv2/OpenVPN)"

# Konfigurierte Verbindungen zaehlen
$connJson = az network vpn-connection list `
    --resource-group $ResourceGroupName `
    --query "[?virtualNetworkGateway1.id=='$resourceId']" `
    --output json 2>$null
$connections = @()
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($connJson)) {
    $connections = @($connJson | ConvertFrom-Json)
}
Write-Sub "Verbindungen   : $($connections.Count) konfiguriert"

# =========================================================================
#  METRIKEN ABFRAGEN
# =========================================================================
$endTime   = (Get-Date).ToUniversalTime()
$startTime = $endTime.AddDays(-$DaysBack)
$stStr     = $startTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
$etStr     = $endTime.ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Section "AUSLASTUNG (letzte $DaysBack Tage, Granularitaet $Interval)"
Write-Log "Frage Azure-Monitor-Metriken ab..."

$mS2S   = Get-MetricSeries -ResourceId $resourceId -MetricName "AverageBandwidth"   -StartTime $stStr -EndTime $etStr -Interval $Interval
$mP2S   = Get-MetricSeries -ResourceId $resourceId -MetricName "P2SBandwidth"       -StartTime $stStr -EndTime $etStr -Interval $Interval
$mP2SC  = Get-MetricSeries -ResourceId $resourceId -MetricName "P2SConnectionCount" -StartTime $stStr -EndTime $etStr -Interval $Interval
$mPPS   = Get-MetricSeries -ResourceId $resourceId -MetricName "TunnelPeakPackets"  -StartTime $stStr -EndTime $etStr -Interval $Interval
$mFlowI = Get-MetricSeries -ResourceId $resourceId -MetricName "InboundFlowsCount"  -StartTime $stStr -EndTime $etStr -Interval $Interval
$mFlowO = Get-MetricSeries -ResourceId $resourceId -MetricName "OutboundFlowsCount" -StartTime $stStr -EndTime $etStr -Interval $Interval

$s2sMaxMbps = 0.0 ; $s2sAvgMbps = 0.0
if ($mS2S -and $mS2S.HasData) { $s2sMaxMbps = ConvertTo-Mbps $mS2S.Max ; $s2sAvgMbps = ConvertTo-Mbps $mS2S.Avg }

$p2sMaxMbps = 0.0 ; $p2sAvgMbps = 0.0
if ($mP2S -and $mP2S.HasData) { $p2sMaxMbps = ConvertTo-Mbps $mP2S.Max ; $p2sAvgMbps = ConvertTo-Mbps $mP2S.Avg }

$totalMaxMbps = [math]::Round($s2sMaxMbps + $p2sMaxMbps, 2)

Write-Host ""
Write-Host "  DURCHSATZ" -ForegroundColor White
$pctS2S   = Write-Usage -Label "S2S Spitze"        -Value $s2sMaxMbps   -Limit $limits.Mbps -Unit "Mbps"
Write-Sub ("{0,-26} {1} Mbps" -f "S2S Durchschnitt", $s2sAvgMbps)
$pctP2S   = Write-Usage -Label "P2S Spitze"        -Value $p2sMaxMbps   -Limit $limits.Mbps -Unit "Mbps"
Write-Sub ("{0,-26} {1} Mbps" -f "P2S Durchschnitt", $p2sAvgMbps)
$pctTotal = Write-Usage -Label "Gesamt-Spitze"     -Value $totalMaxMbps -Limit $limits.Mbps -Unit "Mbps"

Write-Host ""
Write-Host "  VERBINDUNGEN" -ForegroundColor White
$pctS2SC = Write-Usage -Label "S2S-Tunnel (konfig.)" -Value $connections.Count -Limit $limits.S2S -Unit "Tunnel"
$p2sCount = 0
if ($mP2SC -and $mP2SC.HasData) { $p2sCount = [math]::Round($mP2SC.Max, 0) }
$pctP2SC = Write-Usage -Label "P2S-Verbindungen max" -Value $p2sCount -Limit $limits.P2S -Unit "Verb."

Write-Host ""
Write-Host "  PAKETE / FLOWS" -ForegroundColor White
$ppsMax = 0
if ($mPPS -and $mPPS.HasData) { $ppsMax = [math]::Round($mPPS.Max, 0) }
$pctPPS = Write-Usage -Label "Peak PPS pro Tunnel" -Value $ppsMax -Limit $limits.PPS -Unit "pps"

$flowMax = 0
if ($mFlowI -and $mFlowI.HasData) { $flowMax = [math]::Max($flowMax, [math]::Round($mFlowI.Max, 0)) }
if ($mFlowO -and $mFlowO.HasData) { $flowMax = [math]::Max($flowMax, [math]::Round($mFlowO.Max, 0)) }
$null = Write-Usage -Label "Flows max (5-Tupel)" -Value $flowMax -Limit $FlowLimit -Unit "Flows"

# =========================================================================
#  BANDBREITE PRO TUNNEL
# =========================================================================
Write-Section "BANDBREITE PRO TUNNEL"

$mTun = Get-MetricSeries -ResourceId $resourceId -MetricName "TunnelAverageBandwidth" `
        -StartTime $stStr -EndTime $etStr -Interval $Interval -SplitBy "ConnectionName"

if ($mTun -and $mTun.HasData) {
    foreach ($key in ($mTun.Series.Keys | Sort-Object)) {
        $tMax = ConvertTo-Mbps $mTun.Series[$key].Max
        $tAvg = ConvertTo-Mbps $mTun.Series[$key].Avg
        Write-Sub ("{0,-30} Spitze {1,8} Mbps | Schnitt {2,8} Mbps" -f $key, $tMax, $tAvg)
    }
} else {
    Write-Info "Keine Tunnel-Metriken im Zeitraum vorhanden (kein Traffic oder Tunnel down)."
}

# =========================================================================
#  PAKETVERLUSTE
# =========================================================================
Write-Section "PAKETVERLUSTE"

$dropMetrics = @(
    @{ Name = "TunnelIngressPacketDropCount";      Label = "Ingress Drops" },
    @{ Name = "TunnelEgressPacketDropCount";       Label = "Egress Drops" },
    @{ Name = "TunnelIngressPacketDropTSMismatch"; Label = "Ingress TS-Mismatch" },
    @{ Name = "TunnelEgressPacketDropTSMismatch";  Label = "Egress TS-Mismatch" }
)

$dropTotal = 0
foreach ($dm in $dropMetrics) {
    $m = Get-MetricSeries -ResourceId $resourceId -MetricName $dm.Name -StartTime $stStr -EndTime $etStr -Interval "PT1H"
    $v = 0
    if ($m -and $m.HasData) { $v = [math]::Round($m.Max, 0) }
    $dropTotal += $v
    if ($v -gt 0) { Write-Sub ("{0,-26} max {1} Pakete / Intervall" -f $dm.Label, $v) "Yellow" }
    else          { Write-Sub ("{0,-26} keine" -f $dm.Label) "Green" }
}

# =========================================================================
#  BEWERTUNG
# =========================================================================
Write-Section "BEWERTUNG"

$peakPct = 0
foreach ($p in @($pctTotal, $pctP2SC, $pctPPS)) { if ($p -gt $peakPct) { $peakPct = $p } }

if ($peakPct -ge 90) {
    Write-Err "Kritische Auslastung ($peakPct %) - SKU-Upgrade dringend empfohlen."
} elseif ($peakPct -ge $WarnThresholdPct) {
    Write-Warn "Hohe Auslastung ($peakPct %) - SKU-Upgrade pruefen."
} elseif ($peakPct -lt $IdleThresholdPct) {
    Write-Ok "Geringe Auslastung ($peakPct %) - kleinere SKU koennte ausreichen (Kostenersparnis)."
} else {
    Write-Ok "Auslastung im gruenen Bereich ($peakPct %) - aktuelle SKU passt."
}

if ($dropTotal -gt 0) {
    Write-Warn "Paketverluste festgestellt - Ursache pruefen (Ueberlast vs. Traffic-Selector-Mismatch)."
}

if ($gw.activeActive -eq $false) {
    Write-Info "Active-Active ist deaktiviert - Aktivierung verdoppelt den Durchsatz ohne SKU-Wechsel."
}

Write-Host ""
Write-Info "Hinweis: S2S- und P2S-Bandbreite teilen sich das Aggregat-Limit der SKU."
Write-Info "Benchmarks sind Richtwerte, keine garantierten Werte."
Write-Line
