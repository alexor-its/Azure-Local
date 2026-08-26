#Requires -Version 5.1
<#
.SYNOPSIS
    Analysiert alle Azure Arc Server einer Subscription und entfernt die Post-Deployment-
    Extensions "JsonADDomainExtension" (Domain Join) und "CustomScriptExtension".
.DESCRIPTION
    Nach einem ARM-Deployment einer Azure Local VM bleiben die Domain-Join- und die
    Custom-Script-Extension dauerhaft als eigenstaendige ARM-Ressourcen bestehen. Sie
    werden weder automatisch entfernt noch durch ein erneutes Deployment mit deaktivierter
    Bedingung geloescht (ARM Incremental Mode loescht nie fehlende Ressourcen).

    Dieses Script durchsucht alle Arc-Maschinen (Microsoft.HybridCompute/machines) einer
    Subscription, erkennt die betroffenen Extensions anhand ihres TYPS (nicht des Namens,
    da dieser frei vergeben werden kann) und entfernt sie.

    Erkennung erfolgt bevorzugt ueber Azure Resource Graph (eine Abfrage fuer die gesamte
    Subscription). Steht die CLI-Extension "resource-graph" nicht zur Verfuegung, wird
    automatisch auf eine Iteration ueber alle Maschinen zurueckgefallen.

    WICHTIG: Das Entfernen der Domain-Join-Extension nimmt die VM NICHT aus der Domaene.
    Der Join ist im AD und lokal auf der VM persistiert. Entfernt wird ausschliesslich
    der ARM-seitige Extension-Eintrag.

    Standardmaessig laeuft das Script im Simulationsmodus ($WhatIfMode = $true) und
    loescht nichts. Erst nach Pruefung der Ausgabe auf $false setzen.
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
    .\Remove-ArcVmExtensions.ps1
#>

# ═══════════════════════════════════════════════════════════════════════════
#  PARAMETER - hier anpassen
# ═══════════════════════════════════════════════════════════════════════════

# Ziel-Subscription. Leer lassen = aktuell im Kontext gesetzte Subscription.
$SubscriptionId = ""

# Auf eine Resource Group einschraenken. Leer lassen = gesamte Subscription.
$ResourceGroupFilter = ""

# Auf Maschinen-Namen einschraenken (Wildcards erlaubt, z.B. "avdhp*").
# Leer lassen = alle Maschinen.
$MachineNameFilter = ""

# Welche Extension-Typen sollen entfernt werden?
$RemoveDomainJoinExtension = $true    # Typ: JsonADDomainExtension
$RemoveCustomScriptExtension = $true  # Typ: CustomScriptExtension

# SIMULATIONSMODUS: $true = nur anzeigen, nichts loeschen. $false = wirklich loeschen.
$WhatIfMode = $true

# Vor jedem einzelnen Loeschvorgang nachfragen ($false = ohne Rueckfrage durchlaufen)
$ConfirmEachDeletion = $true

# Optionaler CSV-Report. Leer lassen = kein Export.
$ReportPath = "C:\temp\ArcExtensionReport.csv"

# Mindestens erwartete Azure CLI Version
$MinAzCliVersion = "2.60.0"

# ═══════════════════════════════════════════════════════════════════════════
#  AB HIER NICHTS MEHR ANPASSEN
# ═══════════════════════════════════════════════════════════════════════════

$ErrorActionPreference = "Continue"

# Extension-Typen, die entfernt werden sollen (Erkennung ueber properties.type)
$TargetTypes = @()
if ($RemoveDomainJoinExtension)   { $TargetTypes += "JsonADDomainExtension" }
if ($RemoveCustomScriptExtension) { $TargetTypes += "CustomScriptExtension" }

# ─── Ausgabe-Helfer ────────────────────────────────────────────────────────
function Write-Divider { Write-Host ("=" * 60) -ForegroundColor White }
function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Divider
    Write-Host "[ $Title ]" -ForegroundColor White
    Write-Divider
}
function Write-Ok {
    param([string]$Message, [int]$Indent = 0)
    Write-Host ((" " * $Indent) + "✅  $Message") -ForegroundColor Green
}
function Write-Err {
    param([string]$Message, [int]$Indent = 0)
    Write-Host ((" " * $Indent) + "❌  $Message") -ForegroundColor Red
}
function Write-Warn {
    param([string]$Message, [int]$Indent = 0)
    Write-Host ((" " * $Indent) + "⚠️  $Message") -ForegroundColor Yellow
}
function Write-Info {
    param([string]$Message, [int]$Indent = 0)
    Write-Host ((" " * $Indent) + "ℹ️  $Message") -ForegroundColor Cyan
}
function Write-Process {
    param([string]$Message, [int]$Indent = 0)
    Write-Host ((" " * $Indent) + "🔄  $Message") -ForegroundColor Cyan
}
function Write-Log {
    param([string]$Message, [string]$Color = "Cyan", [int]$Indent = 0)
    Write-Host ((" " * $Indent) + "[$(Get-Date -Format 'HH:mm:ss')] $Message") -ForegroundColor $Color
}

Clear-Host
Write-Divider
Write-Host " ARC EXTENSION CLEANUP - JsonADDomainExtension / CustomScriptExtension" -ForegroundColor White
Write-Host " Alexander Ortha IT Solutions" -ForegroundColor White
Write-Divider

# ─── PRE-CHECK ─────────────────────────────────────────────────────────────
Write-Section "PRE-CHECK"

# 1. Azure CLI vorhanden?
Write-Info "Pruefe Azure CLI..."
$azCmd = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCmd) {
    Write-Err "Azure CLI nicht gefunden. Installation: https://aka.ms/installazurecliwindows" 4
    return
}

$azVersionRaw = az version --output json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $azVersionRaw) {
    Write-Err "Azure CLI konnte nicht ausgefuehrt werden." 4
    return
}
$azVersion = ($azVersionRaw | ConvertFrom-Json).'azure-cli'
Write-Ok "Azure CLI gefunden: $azVersion" 4

# 2. Azure CLI aktuell?
try {
    if ([version]$azVersion -lt [version]$MinAzCliVersion) {
        Write-Warn "Version aelter als empfohlen ($MinAzCliVersion). Update: az upgrade" 4
    } else {
        Write-Ok "Version erfuellt Mindestanforderung ($MinAzCliVersion)" 4
    }
} catch {
    Write-Warn "Versionsvergleich nicht moeglich: $azVersion" 4
}

# 3. CLI-Extension "connectedmachine" vorhanden?
Write-Info "Pruefe CLI-Extension 'connectedmachine'..."
$null = az extension show --name connectedmachine --output json 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Nicht installiert - wird jetzt hinzugefuegt..." 4
    az extension add --name connectedmachine --only-show-errors 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Installation fehlgeschlagen: az extension add --name connectedmachine" 4
        return
    }
    Write-Ok "CLI-Extension 'connectedmachine' installiert" 4
} else {
    Write-Ok "CLI-Extension 'connectedmachine' vorhanden" 4
}

# 4. Login vorhanden?
Write-Info "Pruefe Azure Login..."
$accountRaw = az account show --output json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $accountRaw) {
    Write-Warn "Kein aktiver Login - starte 'az login'..." 4
    az login --only-show-errors | Out-Null
    $accountRaw = az account show --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $accountRaw) {
        Write-Err "Login fehlgeschlagen." 4
        return
    }
}
$account = $accountRaw | ConvertFrom-Json
Write-Ok "Login vorhanden: $($account.user.name)" 4

# 5. Subscription setzen
if ($SubscriptionId) {
    Write-Info "Setze Subscription-Kontext..."
    az account set --subscription $SubscriptionId 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Subscription nicht gefunden oder kein Zugriff: $SubscriptionId" 4
        return
    }
    $account = az account show --output json 2>$null | ConvertFrom-Json
}
Write-Ok "Subscription: $($account.name)" 4
Write-Host "     ID: $($account.id)" -ForegroundColor Cyan

# 6. Konfiguration ausgeben
if ($TargetTypes.Count -eq 0) {
    Write-Err "Keine Extension-Typen zum Entfernen ausgewaehlt - bitte Parameter pruefen." 4
    return
}
Write-Info "Zu entfernende Extension-Typen: $($TargetTypes -join ', ')" 4
if ($ResourceGroupFilter) { Write-Info "Filter Resource Group: $ResourceGroupFilter" 4 }
if ($MachineNameFilter)   { Write-Info "Filter Maschinen-Name : $MachineNameFilter" 4 }
if ($WhatIfMode) {
    Write-Warn "SIMULATIONSMODUS AKTIV - es wird nichts geloescht" 4
} else {
    Write-Warn "LOESCHMODUS AKTIV - gefundene Extensions werden entfernt" 4
}

# ─── ANALYSE ───────────────────────────────────────────────────────────────
Write-Section "ANALYSE"

$subId = $account.id
$found = New-Object System.Collections.ArrayList

# Variante A: Azure Resource Graph (eine Abfrage fuer die gesamte Subscription)
$graphOk = $false
$null = az extension show --name resource-graph --output json 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Info "CLI-Extension 'resource-graph' nicht vorhanden - wird hinzugefuegt..."
    az extension add --name resource-graph --only-show-errors 2>$null | Out-Null
}
$null = az extension show --name resource-graph --output json 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Process "Frage Azure Resource Graph ab..."
    $query = "resources " +
             "| where type =~ 'microsoft.hybridcompute/machines/extensions' " +
             "| extend extType = tostring(properties.type), publisher = tostring(properties.publisher), state = tostring(properties.provisioningState) " +
             "| extend machine = tostring(split(id, '/')[8]) " +
             "| project id, name, machine, resourceGroup, extType, publisher, state, location " +
             "| order by machine asc"
    $graphRaw = az graph query -q $query --subscriptions $subId --first 1000 --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $graphRaw) {
        $graphResult = $graphRaw | ConvertFrom-Json
        foreach ($row in $graphResult.data) {
            if ($TargetTypes -notcontains $row.extType) { continue }
            if ($ResourceGroupFilter -and $row.resourceGroup -ne $ResourceGroupFilter) { continue }
            if ($MachineNameFilter -and $row.machine -notlike $MachineNameFilter) { continue }
            $null = $found.Add([PSCustomObject]@{
                Machine       = $row.machine
                ResourceGroup = $row.resourceGroup
                ExtensionName = $row.name
                ExtensionType = $row.extType
                Publisher     = $row.publisher
                State         = $row.state
                Action        = ""
            })
        }
        $graphOk = $true
        Write-Ok "Resource Graph ausgewertet: $($graphResult.data.Count) Extensions gesamt" 4
    }
}

# Variante B: Fallback - alle Maschinen einzeln durchgehen
if (-not $graphOk) {
    Write-Warn "Resource Graph nicht verfuegbar - nutze Einzelabfrage pro Maschine" 4
    Write-Process "Lade Arc-Maschinen..."

    if ($ResourceGroupFilter) {
        $machinesRaw = az connectedmachine list --resource-group $ResourceGroupFilter --output json 2>$null
    } else {
        $machinesRaw = az connectedmachine list --output json 2>$null
    }
    if ($LASTEXITCODE -ne 0 -or -not $machinesRaw) {
        Write-Err "Arc-Maschinen konnten nicht gelesen werden." 4
        return
    }
    $machines = @($machinesRaw | ConvertFrom-Json)
    if ($MachineNameFilter) {
        $machines = @($machines | Where-Object { $_.name -like $MachineNameFilter })
    }
    Write-Ok "$($machines.Count) Arc-Maschinen gefunden" 4

    $i = 0
    foreach ($m in $machines) {
        $i++
        $mRg = ($m.id -split '/')[4]
        Write-Log "[$i/$($machines.Count)] $($m.name)" "Cyan" 4
        $extRaw = az connectedmachine extension list --machine-name $m.name --resource-group $mRg --output json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $extRaw) { continue }
        foreach ($e in @($extRaw | ConvertFrom-Json)) {
            $eType = $e.properties.type
            if ($TargetTypes -notcontains $eType) { continue }
            $null = $found.Add([PSCustomObject]@{
                Machine       = $m.name
                ResourceGroup = $mRg
                ExtensionName = $e.name
                ExtensionType = $eType
                Publisher     = $e.properties.publisher
                State         = $e.properties.provisioningState
                Action        = ""
            })
        }
    }
}

# ─── ERGEBNIS ──────────────────────────────────────────────────────────────
Write-Section "GEFUNDENE EXTENSIONS"

if ($found.Count -eq 0) {
    Write-Ok "Keine passenden Extensions gefunden - nichts zu tun." 4
    Write-Host ""
    Write-Divider
    return
}

$machineCount = @($found | Select-Object -ExpandProperty Machine -Unique).Count
Write-Info "$($found.Count) Extension(s) auf $machineCount Maschine(n):" 4
Write-Host ""
$found | Format-Table Machine, ResourceGroup, ExtensionName, ExtensionType, State -AutoSize | Out-String | Write-Host

# ─── LOESCHEN ──────────────────────────────────────────────────────────────
Write-Section "CLEANUP"

$deleted = 0
$skipped = 0
$failed  = 0

if ($WhatIfMode) {
    Write-Warn "Simulationsmodus - folgende Extensions WUERDEN entfernt:" 4
    foreach ($f in $found) {
        Write-Host "     • $($f.Machine) → $($f.ExtensionName) ($($f.ExtensionType))" -ForegroundColor Yellow
        $f.Action = "WhatIf"
        $skipped++
    }
    Write-Host ""
    Write-Info "Zum tatsaechlichen Loeschen im Script `$WhatIfMode = `$false setzen." 4
} else {
    $aborted = $false
    foreach ($f in $found) {
        if ($aborted) { $f.Action = "Aborted"; $skipped++; continue }

        $label = "$($f.Machine) → $($f.ExtensionName) ($($f.ExtensionType))"
        $doDelete = $true

        if ($ConfirmEachDeletion) {
            Write-Host ""
            Write-Host "     Loeschen: $label" -ForegroundColor White
            $answer = (Read-Host "     [J] Ja  [N] Nein  [A] Alle ohne weitere Rueckfrage  [X] Abbrechen").Trim().ToUpper()

            if ($answer -eq "N") {
                Write-Warn "Uebersprungen: $label" 4
                $f.Action = "Skipped"
                $skipped++
                $doDelete = $false
            }
            elseif ($answer -eq "X") {
                Write-Warn "Abbruch durch Benutzer" 4
                $f.Action = "Aborted"
                $skipped++
                $doDelete = $false
                $aborted = $true
            }
            elseif ($answer -eq "A") {
                $ConfirmEachDeletion = $false
            }
        }

        if (-not $doDelete) { continue }

        Write-Process "Entferne: $label" 4
        az connectedmachine extension delete `
            --machine-name $f.Machine `
            --resource-group $f.ResourceGroup `
            --name $f.ExtensionName `
            --yes `
            --only-show-errors 2>$null

        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Entfernt: $label" 4
            $f.Action = "Deleted"
            $deleted++
        } else {
            Write-Err "Fehler beim Entfernen: $label" 4
            $f.Action = "Failed"
            $failed++
        }
    }
}

# ─── ZUSAMMENFASSUNG ───────────────────────────────────────────────────────
Write-Section "ZUSAMMENFASSUNG"

Write-Info "Gefunden : $($found.Count)" 4
if ($deleted -gt 0) { Write-Ok   "Entfernt : $deleted" 4 }
if ($skipped -gt 0) { Write-Warn "Offen    : $skipped" 4 }
if ($failed  -gt 0) { Write-Err  "Fehler   : $failed" 4 }

if ($ReportPath) {
    try {
        $reportDir = Split-Path -Path $ReportPath -Parent
        if ($reportDir -and -not (Test-Path $reportDir)) {
            New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
        }
        $found | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8 -Delimiter ";"
        Write-Ok "Report gespeichert: $ReportPath" 4
    } catch {
        Write-Warn "Report konnte nicht geschrieben werden: $($_.Exception.Message)" 4
    }
}

Write-Host ""
Write-Divider
Write-Host " FERTIG - $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')" -ForegroundColor White
Write-Divider
