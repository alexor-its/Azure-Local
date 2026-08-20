#Requires -Version 5.1
<#
.SYNOPSIS
    Detailanalyse von Paketverlusten an einem Azure VPN Gateway.
.DESCRIPTION
    Analysiert die Drop-Metriken eines Virtual Network Gateways vom Typ "Vpn" in drei Stufen:

      1. Drop-Rate: setzt verworfene Pakete ins Verhaeltnis zum Gesamtpaketaufkommen
         und bewertet, ob die Verluste ueberhaupt relevant sind.
      2. Dimensionen: splittet die Drops nach ConnectionName, RemoteIP und Instance auf,
         um die Verluste einem Tunnel, Remote-Gateway oder einer Gateway-Instanz zuzuordnen.
      3. Zeitliche Korrelation: listet die Intervalle mit den hoechsten Verlusten und
         stellt ihnen die Bandbreite im selben Intervall gegenueber (Ueberlast-Indikator).

    Zusaetzlich wird geprueft, ob Diagnose-Logs aktiv sind, und es werden passende
    KQL-Abfragen fuer die weitergehende Analyse in Log Analytics ausgegeben.
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
    .\Get-VpnGatewayPacketDropAnalysis.ps1
#>

# =========================================================================
#  PARAMETER - hier anpassen
# =========================================================================
$SubscriptionId    = ""                      # leer = aktuelle Subscription
$ResourceGroupName = "RG-Netzwerk"           # Resource Group des Gateways
$GatewayName       = "LDK_S2S_VPN_AVD"       # Name des Virtual Network Gateways
$DaysBack          = 7                       # Auswertungszeitraum in Tagen (max. 93)
$Interval          = "PT1H"                  # Granularitaet: PT5M/PT15M/PT1H
$TopIntervals      = 10                      # Anzahl der Top-Intervalle in Stufe 3
$MinAzCliVersion   = "2.60.0"                # Mindestversion Azure CLI

# Bewertungsschwellen fuer die Drop-Rate in Prozent
$RateIgnorePct     = 0.01                    # darunter: irrelevant
$RateWatchPct      = 0.10                    # darunter: beobachten
$RateActionPct     = 1.00                    # darueber: Handlungsbedarf

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

function Get-MetricRaw {
    <#
        Fragt eine Metrik ab und liefert:
        @{
            HasData = $true/$false
            Total   = <double>                       # Summe ueber alle Serien
            Series  = @{ "<Label>" = <double> }      # Summe je Dimensionswert
            Points  = @{ "<Timestamp>" = <double> }  # Summe je Zeitintervall
        }
    #>
    param(
        [string]$ResourceId,
        [string]$MetricName,
        [string]$StartTime,
        [string]$EndTime,
        [string]$Interval,
        [string]$Aggregation = "Total",
        [string]$SplitBy = $null
    )

    $cmd = @(
        "monitor", "metrics", "list",
        "--resource", $ResourceId,
        "--metric", $MetricName,
        "--aggregation", $Aggregation,
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

    $result = @{ HasData = $false; Total = 0.0; Series = @{}; Points = @{} }
    $aggKey = $Aggregation.ToLower()
    if ($aggKey -eq "maximum") { $aggKey = "maximum" }
    if ($aggKey -eq "average") { $aggKey = "average" }

    foreach ($ts in $json.value[0].timeseries) {
        $label = "gesamt"
        if ($ts.metadatavalues -and $ts.metadatavalues.Count -gt 0) {
            $label = $ts.metadatavalues[0].value
        }

        $seriesSum = 0.0
        foreach ($p in $ts.data) {
            $v = $null
            switch ($aggKey) {
                "total"   { $v = $p.total }
                "maximum" { $v = $p.maximum }
                "average" { $v = $p.average }
            }
            if ($null -eq $v) { continue }
            $v = [double]$v
            if ($v -eq 0) { continue }

            $result.HasData = $true
            $seriesSum += $v
            $result.Total += $v

            $tsKey = [string]$p.timeStamp
            if ($result.Points.ContainsKey($tsKey)) { $result.Points[$tsKey] += $v }
            else                                    { $result.Points[$tsKey]  = $v }
        }

        if ($seriesSum -gt 0) {
            if ($result.Series.ContainsKey($label)) { $result.Series[$label] += $seriesSum }
            else                                    { $result.Series[$label]  = $seriesSum }
        }
    }
    return $result
}

function Get-Rate {
    param([double]$Drops, [double]$Packets)
    $denom = $Packets + $Drops
    if ($denom -le 0) { return 0.0 }
    return [math]::Round(($Drops / $denom) * 100, 5)
}

function Write-RateVerdict {
    param([string]$Label, [double]$Drops, [double]$Packets)
    $rate = Get-Rate -Drops $Drops -Packets $Packets

    $color   = "Green"
    $verdict = "irrelevant"
    if ($rate -ge $RateIgnorePct) { $color = "Green"  ; $verdict = "unauffaellig" }
    if ($rate -ge $RateWatchPct)  { $color = "Yellow" ; $verdict = "beobachten" }
    if ($rate -ge $RateActionPct) { $color = "Red"    ; $verdict = "Handlungsbedarf" }

    Write-Sub ("{0,-20} {1,12:N0} Drops / {2,14:N0} Pakete = {3} %  [{4}]" -f `
               $Label, $Drops, $Packets, $rate, $verdict) $color
    return $rate
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
Write-Sub "SKU           : $($gw.sku.name) / $($gw.vpnGatewayGeneration)"
Write-Sub "Active-Active : $($gw.activeActive)"

$endTime   = (Get-Date).ToUniversalTime()
$startTime = $endTime.AddDays(-$DaysBack)
$stStr     = $startTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
$etStr     = $endTime.ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Sub "Zeitraum      : $($startTime.ToString('dd.MM.yyyy HH:mm')) - $($endTime.ToString('dd.MM.yyyy HH:mm')) UTC"
Write-Sub "Granularitaet : $Interval"

# =========================================================================
#  STUFE 1 - DROP-RATE
# =========================================================================
Write-Section "STUFE 1 - DROP-RATE"

Write-Log "Frage Paket- und Drop-Metriken ab..."

$egPkt   = Get-MetricRaw -ResourceId $resourceId -MetricName "TunnelEgressPackets"              -StartTime $stStr -EndTime $etStr -Interval $Interval
$inPkt   = Get-MetricRaw -ResourceId $resourceId -MetricName "TunnelIngressPackets"             -StartTime $stStr -EndTime $etStr -Interval $Interval
$egDrop  = Get-MetricRaw -ResourceId $resourceId -MetricName "TunnelEgressPacketDropCount"      -StartTime $stStr -EndTime $etStr -Interval $Interval
$inDrop  = Get-MetricRaw -ResourceId $resourceId -MetricName "TunnelIngressPacketDropCount"     -StartTime $stStr -EndTime $etStr -Interval $Interval
$egTsm   = Get-MetricRaw -ResourceId $resourceId -MetricName "TunnelEgressPacketDropTSMismatch" -StartTime $stStr -EndTime $etStr -Interval $Interval
$inTsm   = Get-MetricRaw -ResourceId $resourceId -MetricName "TunnelIngressPacketDropTSMismatch" -StartTime $stStr -EndTime $etStr -Interval $Interval

$egPktT  = if ($egPkt)  { $egPkt.Total }  else { 0 }
$inPktT  = if ($inPkt)  { $inPkt.Total }  else { 0 }
$egDropT = if ($egDrop) { $egDrop.Total } else { 0 }
$inDropT = if ($inDrop) { $inDrop.Total } else { 0 }
$egTsmT  = if ($egTsm)  { $egTsm.Total }  else { 0 }
$inTsmT  = if ($inTsm)  { $inTsm.Total }  else { 0 }

Write-Host ""
$rateEg = Write-RateVerdict -Label "Egress"  -Drops $egDropT -Packets $egPktT
$rateIn = Write-RateVerdict -Label "Ingress" -Drops $inDropT -Packets $inPktT

Write-Host ""
Write-Sub ("{0,-20} {1:N0}" -f "TS-Mismatch Egress",  $egTsmT)
Write-Sub ("{0,-20} {1:N0}" -f "TS-Mismatch Ingress", $inTsmT)

$maxRate = [math]::Max($rateEg, $rateIn)

Write-Host ""
if ($maxRate -lt $RateIgnorePct) {
    Write-Ok "Drop-Rate unter $RateIgnorePct % - statistisches Rauschen, kein Handlungsbedarf."
} elseif ($maxRate -lt $RateWatchPct) {
    Write-Ok "Drop-Rate unauffaellig ($maxRate %) - Stufe 2 und 3 dienen nur der Dokumentation."
} elseif ($maxRate -lt $RateActionPct) {
    Write-Warn "Drop-Rate erhoeht ($maxRate %) - Stufe 2 und 3 auswerten."
} else {
    Write-Err "Drop-Rate kritisch ($maxRate %) - Ursache zwingend klaeren."
}

if (($egTsmT + $inTsmT) -gt 0) {
    Write-Warn "TS-Mismatch vorhanden: Adressraeume zwischen Azure und On-Prem stimmen nicht ueberein."
}

# =========================================================================
#  STUFE 2 - DIMENSIONEN
# =========================================================================
Write-Section "STUFE 2 - DIMENSIONEN"

$dimensions = @("ConnectionName", "RemoteIP", "Instance")
$dropMetrics = @(
    @{ Name = "TunnelEgressPacketDropCount";  Label = "Egress Drops" },
    @{ Name = "TunnelIngressPacketDropCount"; Label = "Ingress Drops" }
)

foreach ($dm in $dropMetrics) {
    Write-Host ""
    Write-Host "  $($dm.Label)" -ForegroundColor White

    $any = $false
    foreach ($dim in $dimensions) {
        $m = Get-MetricRaw -ResourceId $resourceId -MetricName $dm.Name `
             -StartTime $stStr -EndTime $etStr -Interval $Interval -SplitBy $dim

        if ($m -and $m.HasData) {
            $any = $true
            Write-Sub ("nach {0}:" -f $dim) "Cyan"
            foreach ($k in ($m.Series.GetEnumerator() | Sort-Object -Property Value -Descending)) {
                $share = 0
                if ($m.Total -gt 0) { $share = [math]::Round(($k.Value / $m.Total) * 100, 1) }
                Write-Sub ("    {0,-32} {1,10:N0} Drops ({2} %)" -f $k.Key, $k.Value, $share)
            }
        }
    }
    if (-not $any) { Write-Sub "keine Drops im Zeitraum" "Green" }
}

Write-Host ""
Write-Info "Konzentration auf einen ConnectionName -> Problem beim jeweiligen On-Prem-Geraet."
Write-Info "Konzentration auf eine Instance        -> Problem einer Gateway-Instanz (Active-Active)."
Write-Info "Gleichmaessige Verteilung              -> eher SKU-Ueberlast oder MTU-Thematik."

# =========================================================================
#  STUFE 3 - ZEITLICHE KORRELATION
# =========================================================================
Write-Section "STUFE 3 - ZEITLICHE KORRELATION"

$bw = Get-MetricRaw -ResourceId $resourceId -MetricName "AverageBandwidth" `
      -StartTime $stStr -EndTime $etStr -Interval $Interval -Aggregation "Maximum"

$allDropPoints = @{}
foreach ($src in @($egDrop, $inDrop)) {
    if (-not $src) { continue }
    foreach ($k in $src.Points.Keys) {
        if ($allDropPoints.ContainsKey($k)) { $allDropPoints[$k] += $src.Points[$k] }
        else                                { $allDropPoints[$k]  = $src.Points[$k] }
    }
}

if ($allDropPoints.Count -eq 0) {
    Write-Ok "Keine Intervalle mit Paketverlusten im Zeitraum."
} else {
    Write-Sub ("{0,-22} {1,10} {2,14}" -f "Zeitpunkt (UTC)", "Drops", "Bandbreite") "Cyan"
    $top = $allDropPoints.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First $TopIntervals

    foreach ($p in $top) {
        $bwText = "n/a"
        if ($bw -and $bw.Points.ContainsKey($p.Key)) {
            $mbps = [math]::Round(($bw.Points[$p.Key] * 8) / 1000000, 2)
            $bwText = "$mbps Mbps"
        }
        $tsText = $p.Key
        try { $tsText = ([datetime]$p.Key).ToString("dd.MM.yyyy HH:mm") } catch { }
        Write-Sub ("{0,-22} {1,10:N0} {2,14}" -f $tsText, $p.Value, $bwText)
    }

    Write-Host ""
    Write-Info "Drops bei hoher Bandbreite  -> Ueberlast, SKU-Upgrade oder Active-Active pruefen."
    Write-Info "Drops bei geringer Last     -> MTU/Fragmentierung, Rekeying oder On-Prem-Geraet."
    Write-Info "Drops in kurzen Bursts      -> typisch fuer IKE SA-Rekeying (meist unkritisch)."
}

# =========================================================================
#  DIAGNOSE-LOGS
# =========================================================================
Write-Section "DIAGNOSE-LOGS"

$diagJson = az monitor diagnostic-settings list --resource $resourceId --output json 2>$null
$diag = $null
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($diagJson)) {
    $diag = ($diagJson | ConvertFrom-Json).value
}

if ($diag -and $diag.Count -gt 0) {
    Write-Ok "Diagnose-Einstellungen aktiv: $($diag.Count)"
    foreach ($d in $diag) {
        Write-Sub "Name: $($d.name)"
        $enabled = @($d.logs | Where-Object { $_.enabled -eq $true } | ForEach-Object { $_.category })
        if ($enabled.Count -gt 0) { Write-Sub "    Kategorien: $($enabled -join ', ')" }
        if ($d.workspaceId)       { Write-Sub "    Workspace : $(($d.workspaceId -split '/')[-1])" }
    }
    Write-Host ""
    Write-Info "KQL fuer Tunnel-Statuswechsel (Log Analytics):"
    Write-Sub 'AzureDiagnostics'
    Write-Sub '| where Category == "TunnelDiagnosticLog"'
    Write-Sub '| where TimeGenerated > ago(7d)'
    Write-Sub '| project TimeGenerated, remoteIP_s, status_s, stateChangeReason_s, instance_s'
    Write-Sub '| order by TimeGenerated desc'
    Write-Host ""
    Write-Info "KQL fuer IKE-Fehler und Rekeying:"
    Write-Sub 'AzureDiagnostics'
    Write-Sub '| where Category == "IKEDiagnosticLog"'
    Write-Sub '| where TimeGenerated > ago(7d)'
    Write-Sub '| where Message contains "FAIL" or Message contains "REKEY"'
    Write-Sub '| project TimeGenerated, Message'
    Write-Sub '| order by TimeGenerated desc'
} else {
    Write-Warn "Keine Diagnose-Einstellungen aktiv - ohne Logs ist keine Ursachenanalyse moeglich."
    Write-Host ""
    Write-Info "Aktivierung (Workspace-ID vorher eintragen):"
    Write-Sub 'az monitor diagnostic-settings create \'
    Write-Sub '    --name "vpngw-diag" \'
    Write-Sub "    --resource `"$resourceId`" \"
    Write-Sub '    --workspace "<Log-Analytics-Resource-Id>" \'
    Write-Sub '    --logs "[{category:TunnelDiagnosticLog,enabled:true},{category:IKEDiagnosticLog,enabled:true},{category:RouteDiagnosticLog,enabled:true},{category:GatewayDiagnosticLog,enabled:true}]"'
}

Write-Host ""
Write-Line
