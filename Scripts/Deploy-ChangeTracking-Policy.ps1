<#
.SYNOPSIS
    Weist die Azure Policy Initiative "Enable ChangeTracking and Inventory for Arc-enabled virtual machines"
    auf mehrere Resource Groups zu und erstellt dabei automatisch Managed Identity und Remediation Tasks.

.BESCHREIBUNG
    Dieses Skript gilt AUSSCHLIESSLICH für Azure Arc-enabled Server (keine Azure VMs).
    Es verwendet die Initiative: 53448c70-089b-4f52-8f38-89196d7f2de1

    Die Initiative enthält 6 Policies (DINE = Deploy If Not Exists):
      [Windows] Configure Arc-enabled machines to install AMA for ChangeTracking
      [Linux]   Configure Arc-enabled machines to install AMA for ChangeTracking
      [Windows] Configure Arc-enabled machines to be associated with a DCR for ChangeTracking
      [Linux]   Configure Arc-enabled machines to be associated with a DCR for ChangeTracking
      [Windows] Configure ChangeTracking Extension for Windows Arc-enabled machines
      [Linux]   Configure ChangeTracking Extension for Linux Arc-enabled machines

    Das Skript:
      1. Prüft Voraussetzungen (Login, Subscription, DCR-ID, Pflichtfelder)
      2. Erstellt pro Resource Group ein Policy Assignment (Arc-Initiative) inkl. System-Assigned Identity
      3. Weist der Managed Identity die Contributor-Rolle auf RG-Ebene zu
      4. Erstellt optional Remediation Tasks für bereits vorhandene Arc-Server

.VORAUSSETZUNGEN
    - Azure CLI installiert  (az --version)
    - Eingeloggt via:        az login
    - Rollen auf Subscription: Policy Contributor + Contributor (oder Owner)
    - Bestehende Data Collection Rule (DCR) für Change Tracking (AMA-Schema)
    - Arc-Server müssen in den Ziel-Resource-Groups onboarded sein

.PARAMETER KONFIGURATION
    Bitte den Abschnitt "=== KONFIGURATION ===" unten anpassen.

.BEISPIEL
    .\Deploy-ChangeTracking-Arc-Policy.ps1

.NOTES
    Arc Initiative ID : 53448c70-089b-4f52-8f38-89196d7f2de1
    Quelle            : https://learn.microsoft.com/azure/azure-change-tracking-inventory/enable-change-tracking-at-scale-policy
    Getestet mit      : Azure CLI 2.x, PowerShell 7+
#>

#Requires -Version 7.0

# ============================================================
# === KONFIGURATION - Hier anpassen! =========================
# ============================================================

# Azure Subscription ID
$SubscriptionId = "<DEINE-SUBSCRIPTION-ID>"

# Data Collection Rule Resource ID
# Name und Resource Group der DCR angeben - die Resource ID wird automatisch ermittelt
$DcrName              = "<DCR-NAME>"
$DcrResourceGroupName = "<DCR-RESOURCE-GROUP>"

# Resource Groups mit Arc-Servern, auf die die Policy angewendet werden soll
$ResourceGroups = @(
    "rg-arc-produktion",
    "rg-arc-entwicklung",
    "rg-arc-dmz"
    # Weitere Resource Groups hier hinzufügen
)

# Azure Regionen, in denen deine Arc-Server registriert sind
# Kommagetrennte Liste, z.B. "germanywestcentral,westeurope,northeurope"
# Leer lassen ("") = alle Regionen
$ApplicableLocations = "germanywestcentral,westeurope,northeurope"

# Region für die Managed Identity der Policy-Zuweisung
# Sollte der Haupt-Region deiner Umgebung entsprechen
$ManagedIdentityLocation = "germanywestcentral"

# Remediation Tasks direkt nach Assignment erstellen?
# $true  = bestehende Arc-Server werden sofort remediiert
# $false = nur neue/geänderte Server werden durch die Policy erfasst
$CreateRemediationTask = $true

# Bestehende Assignments mit korrekter DCR-ID aktualisieren?
# $true  = vorhandene Assignments werden mit az policy assignment update aktualisiert
# $false = bestehende Assignments werden uebersprungen (Standard-Verhalten)
$UpdateExistingAssignments = $true

# OS-Filter: Nur passende Policies deployen
# "Windows" = nur Windows-Policies
# "Linux"   = nur Linux-Policies
# "Both"    = alle 6 Policies (Standard)
$OsFilter = "Both"

# ============================================================
# === ENDE KONFIGURATION =====================================
# ============================================================

# Builtin Initiative IDs je OS
# Quelle: az policy set-definition show --name 53448c70-089b-4f52-8f38-89196d7f2de1
$InitiativeIdBoth    = "53448c70-089b-4f52-8f38-89196d7f2de1"  # Alle 6 Policies (Windows + Linux)
$InitiativeIdWindows = "53448c70-089b-4f52-8f38-89196d7f2de1"  # Gleiche Initiative - OS-Filter per Exclusion
$InitiativeIdLinux   = "53448c70-089b-4f52-8f38-89196d7f2de1"  # Gleiche Initiative - OS-Filter per Exclusion

# Policy Reference IDs aufgeteilt nach OS (fuer Remediation-Steuerung und Anzeige)
$PoliciesWindows = @(
    "DeployAMAWindowsHybridVMWithUAIChangeTrackingAndInventory",
    "DeployChangeTrackingExtensionWindowsHybridVM",
    "DCRAWindowsHybridVMChangeTrackingAndInventory"
)
$PoliciesLinux = @(
    "DeployAMALinuxHybridVMWithUAIChangeTrackingAndInventory",
    "DeployChangeTrackingExtensionLinuxHybridVM",
    "DCRALinuxHybridVMChangeTrackingAndInventory"
)

# Aktive Policies basierend auf OsFilter
$ActivePolicies = switch ($OsFilter) {
    "Windows" { $PoliciesWindows }
    "Linux"   { $PoliciesLinux }
    "Both"    { $PoliciesWindows + $PoliciesLinux }
    default   { Write-Host "[FEHLER] OsFilter muss 'Windows', 'Linux' oder 'Both' sein." -ForegroundColor Red; exit 1 }
}

# Arc Initiative ID (eine Initiative fuer alle OS-Typen)
$ArcInitiativeId = $InitiativeIdBoth

# Prafix fuer Assignment- und Remediation-Namen (OS wird angehaengt wenn nicht Both)
$AssignmentPrefix = switch ($OsFilter) {
    "Windows" { "CT-Arc-Win" }
    "Linux"   { "CT-Arc-Lin" }
    "Both"    { "CT-Arc" }
}

# ------------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------------
function Write-Header {
    param([string]$Text)
    Write-Host "`n$("=" * 65)" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "$("=" * 65)" -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Text)
    Write-Host "`n  --> $Text" -ForegroundColor Yellow
}

function Write-Success {
    param([string]$Text)
    Write-Host "  [OK]     $Text" -ForegroundColor Green
}

function Write-Info {
    param([string]$Text)
    Write-Host "  [INFO]   $Text" -ForegroundColor DarkYellow
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  [WARN]   $Text" -ForegroundColor Magenta
}

function Write-Err {
    param([string]$Text)
    Write-Host "  [FEHLER] $Text" -ForegroundColor Red
}

# ------------------------------------------------------------------
# Voraussetzungen prüfen
# ------------------------------------------------------------------
Write-Header "Voraussetzungen prüfen"

# Pflichtparameter prüfen (vor allem anderen)
if ($SubscriptionId -like "*<*") {
    Write-Err "Bitte 'SubscriptionId' in der Konfiguration eintragen!"
    exit 1
}
if ($DcrName -like "*<*") {
    Write-Err "Bitte 'DcrName' in der Konfiguration eintragen!"
    exit 1
}
if ($DcrResourceGroupName -like "*<*") {
    Write-Err "Bitte 'DcrResourceGroupName' in der Konfiguration eintragen!"
    exit 1
}
if ($ResourceGroups.Count -eq 0) {
    Write-Err "Bitte mindestens eine Resource Group in 'ResourceGroups' eintragen!"
    exit 1
}

# Azure CLI vorhanden?
Write-Step "Prüfe Azure CLI..."
try {
    $cliVersion = az --version 2>&1 | Select-Object -First 1
    Write-Success "Azure CLI gefunden: $cliVersion"
} catch {
    Write-Err "Azure CLI nicht gefunden. Bitte installieren: https://aka.ms/installazurecli"
    exit 1
}

# Eingeloggt?
Write-Step "Prüfe Azure Login..."
$account = az account show 2>&1 | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $account) {
    Write-Host "  Nicht eingeloggt. Starte 'az login'..." -ForegroundColor Yellow
    az login
    $account = az account show | ConvertFrom-Json
}
Write-Success "Eingeloggt als: $($account.user.name)"

# Subscription setzen
Write-Step "Setze Subscription: $SubscriptionId"
$null = az account set --subscription $SubscriptionId 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "Subscription '$SubscriptionId' nicht gefunden oder kein Zugriff."
    exit 1
}
Write-Success "Subscription aktiv: $SubscriptionId"

# DCR Resource ID automatisch ermitteln
Write-Step "Ermittle DCR Resource ID fuer: $DcrName (RG: $DcrResourceGroupName)..."
$DcrResourceId = az monitor data-collection rule show `
    --name $DcrName `
    --resource-group $DcrResourceGroupName `
    --subscription $SubscriptionId `
    --query id -o tsv 2>&1

if ($LASTEXITCODE -ne 0 -or -not $DcrResourceId -or $DcrResourceId -like "*ERROR*") {
    Write-Err "DCR '$DcrName' in RG '$DcrResourceGroupName' nicht gefunden:"
    Write-Host "  $DcrResourceId" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Verfuegbare DCRs anzeigen:" -ForegroundColor DarkGray
    Write-Host "  az monitor data-collection rule list --subscription $SubscriptionId --query `"[].{Name:name, RG:resourceGroup}`" -o table" -ForegroundColor DarkGray
    exit 1
}
$DcrResourceId = $DcrResourceId.Trim()
Write-Success "DCR gefunden: $DcrResourceId"

# Arc Initiative Definition laden und prüfen
Write-Step "Lade Arc Policy Initiative Definition (ID: $ArcInitiativeId)..."
$arcInitiativeDef = az policy set-definition show --name $ArcInitiativeId 2>&1 | ConvertFrom-Json
if (-not $arcInitiativeDef -or $LASTEXITCODE -ne 0) {
    Write-Err "Arc Initiative '$ArcInitiativeId' konnte nicht geladen werden."
    exit 1
}
Write-Success "Initiative gefunden: $($arcInitiativeDef.displayName)"

# ------------------------------------------------------------------
# Parameter vorbereiten
# ------------------------------------------------------------------

# Locations als JSON-Array aufbauen
if ($ApplicableLocations -and $ApplicableLocations -ne "") {
    $locationEntries = $ApplicableLocations -split "," | ForEach-Object { "`"$($_.Trim())`"" }
    $locationJson    = "[" + ($locationEntries -join ",") + "]"
} else {
    $locationJson = "[]"
}

# ------------------------------------------------------------------
# Assignments erstellen (Arc)
# ------------------------------------------------------------------
Write-Header "Arc Policy Assignments erstellen"
Write-Host "  Initiative : $($arcInitiativeDef.displayName)" -ForegroundColor White
Write-Host "  ID         : $ArcInitiativeId" -ForegroundColor DarkGray
Write-Host "  Scope      : Resource Group (je RG ein Assignment)" -ForegroundColor White
Write-Host ""

$successCount   = 0
$errorCount     = 0
$skippedCount   = 0
$updatedCount   = 0
$assignmentMap  = @{}   # rg -> assignmentName

foreach ($rg in $ResourceGroups) {

    Write-Step "Verarbeite Resource Group: $rg"

    # RG-Existenz prüfen
    $rgCheck = az group show --name $rg --subscription $SubscriptionId 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Resource Group '$rg' nicht gefunden – überspringe."
        $errorCount++
        continue
    }

    # Arc-Server in dieser RG zählen (informativer Hinweis)
    $arcServers = az connectedmachine list --resource-group $rg --subscription $SubscriptionId `
        --query "length(@)" -o tsv 2>&1
    if ($LASTEXITCODE -eq 0 -and $arcServers -match '^\d+$') {
        Write-Host "  Arc-Server in dieser RG: $arcServers" -ForegroundColor White
        if ([int]$arcServers -eq 0) {
            Write-Warn "Keine Arc-Server gefunden – Assignment wird trotzdem erstellt (gilt auch für zukünftige Server)."
        }
    }

    $scope = "/subscriptions/$SubscriptionId/resourceGroups/$rg"

    # Assignment-Namen sicher generieren (max. 64 Zeichen, nur alphanumerisch + Bindestrich)
    $rgClean       = ($rg -replace "[^a-zA-Z0-9-]", "").Substring(0, [Math]::Min(($rg -replace "[^a-zA-Z0-9-]","").Length, 24))
    $assignmentName = "$AssignmentPrefix-$rgClean"
    $displayName    = "[Arc] ChangeTracking and Inventory - $rg"

    # Existiert das Assignment bereits?
    $existingAssign = az policy assignment show --name $assignmentName --scope $scope 2>&1
    $assignmentExists = ($LASTEXITCODE -eq 0)

    if ($assignmentExists -and -not $UpdateExistingAssignments) {
        Write-Info "Assignment '$assignmentName' existiert bereits - ueberspringe."
        $assignmentMap[$rg] = $assignmentName
        $skippedCount++
        continue
    }

    # JSON-Params fuer Erstellung und Update vorbereiten
    # WICHTIG: Direkt als String schreiben - ConvertTo-Json kapitalisiert "value" zu "Value"
    $locationJsonArray = ($ApplicableLocations -split "," | ForEach-Object { "`"$($_.Trim())`"" }) -join ","
    $paramsJson = @"
{
  "dcrResourceId": {
    "value": "$DcrResourceId"
  },
  "listOfApplicableLocations": {
    "value": [$locationJsonArray]
  }
}
"@
    $paramsTempFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "ct-arc-params-$($rg -replace '[^a-zA-Z0-9]','').json")
    $paramsJson | Set-Content -Path $paramsTempFile -Encoding UTF8

    if ($assignmentExists -and $UpdateExistingAssignments) {

        Write-Host "  Aktualisiere Assignment: $assignmentName (DCR-ID wird korrigiert)" -ForegroundColor White

        $updateResult = az policy assignment update `
            --name $assignmentName `
            --scope $scope `
            --params "@$paramsTempFile" 2>&1

        Remove-Item -Path $paramsTempFile -ErrorAction SilentlyContinue

        if ($LASTEXITCODE -ne 0) {
            Write-Err "Update fehlgeschlagen fuer '$rg':"
            Write-Host "  $updateResult" -ForegroundColor Red
            $errorCount++
            continue
        }

        Write-Success "Assignment aktualisiert: $assignmentName"
        $assignmentMap[$rg] = $assignmentName
        $updatedCount++
        continue
    }

    Write-Host "  Erstelle Assignment: $assignmentName" -ForegroundColor White

    # Policy Assignment erstellen mit System-Assigned Managed Identity (benoetigt fuer DINE)
    $assignResult = az policy assignment create `
        --name $assignmentName `
        --display-name $displayName `
        --description "Aktiviert Change Tracking und Inventory fuer Azure Arc-Server in $rg (DINE-Policy)" `
        --policy-set-definition $ArcInitiativeId `
        --scope $scope `
        --mi-system-assigned `
        --location $ManagedIdentityLocation `
        --params "@$paramsTempFile" 2>&1

    # Temp-Datei aufraeumen
    Remove-Item -Path $paramsTempFile -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0) {
        Write-Err "Fehler beim Erstellen des Assignments für '$rg':"
        Write-Host "  $assignResult" -ForegroundColor Red
        $errorCount++
        continue
    }

    $assignObj = $assignResult | ConvertFrom-Json
    $assignmentMap[$rg] = $assignmentName
    Write-Success "Assignment erstellt: $($assignObj.id)"

    # ------------------------------------------------------------------
    # Rollenzuweisung für die Managed Identity
    # Die DINE-Policies benötigen Contributor-Rechte um Ressourcen zu deployen
    # ------------------------------------------------------------------
    $principalId = $assignObj.identity.principalId

    if ($principalId) {
        Write-Host "  Warte auf Bereitstellung der Managed Identity..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 20

        # Contributor auf RG-Ebene (für Extension-Deployment auf Arc-Servern)
        Write-Host "  Weise Contributor-Rolle zu (Principal: $principalId)..." -ForegroundColor White
        $roleResult = az role assignment create `
            --role "Contributor" `
            --assignee-object-id $principalId `
            --assignee-principal-type ServicePrincipal `
            --scope $scope 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Contributor-Rollenzuweisung fehlgeschlagen – bitte manuell vergeben:"
            Write-Host "  az role assignment create --role Contributor --assignee-object-id $principalId --scope $scope" -ForegroundColor DarkGray
        } else {
            Write-Success "Contributor-Rolle zugewiesen"
        }

        # Connected Machine Contributor (für Arc-spezifische Operationen)
        Write-Host "  Weise 'Azure Connected Machine Resource Administrator'-Rolle zu..." -ForegroundColor White
        $arcRoleResult = az role assignment create `
            --role "Azure Connected Machine Resource Administrator" `
            --assignee-object-id $principalId `
            --assignee-principal-type ServicePrincipal `
            --scope $scope 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Arc-Rollenzuweisung fehlgeschlagen – bei Bedarf manuell vergeben:"
            Write-Host "  az role assignment create --role 'Azure Connected Machine Resource Administrator' --assignee-object-id $principalId --scope $scope" -ForegroundColor DarkGray
        } else {
            Write-Success "Azure Connected Machine Resource Administrator-Rolle zugewiesen"
        }

    } else {
        Write-Warn "Keine Principal-ID in der Antwort – Rollenzuweisung übersprungen."
    }

    $successCount++
}

# ------------------------------------------------------------------
# Remediation Tasks erstellen (für bereits vorhandene Arc-Server)
# ------------------------------------------------------------------
if ($CreateRemediationTask -and $assignmentMap.Count -gt 0) {

    Write-Header "Remediation Tasks erstellen (für bestehende Arc-Server)"

    # Policy-Kurzbezeichnungen fuer eindeutige Task-Namen (identisch zum Remediation-Script)
    $PolicyShortNames = @{
        "DeployAMAWindowsHybridVMWithUAIChangeTrackingAndInventory" = "AMAWin"
        "DeployAMALinuxHybridVMWithUAIChangeTrackingAndInventory"   = "AMALin"
        "DeployChangeTrackingExtensionWindowsHybridVM"              = "CTExtWin"
        "DeployChangeTrackingExtensionLinuxHybridVM"                = "CTExtLin"
        "DCRAWindowsHybridVMChangeTrackingAndInventory"             = "DCRAWin"
        "DCRALinuxHybridVMChangeTrackingAndInventory"               = "DCRALin"
    }

    foreach ($rg in $assignmentMap.Keys) {

        $assignmentName = $assignmentMap[$rg]
        $timestamp      = Get-Date -Format 'yyyyMMddHHmm'
        $rgClean        = ($rg -replace "[^a-zA-Z0-9-]", "").Substring(0, [Math]::Min(($rg -replace "[^a-zA-Z0-9-]","").Length, 18))

        Write-Step "Erstelle Remediation Tasks fuer: $rg ($($ActivePolicies.Count) Tasks)"

        foreach ($refId in $ActivePolicies) {
            $short           = $PolicyShortNames[$refId]
            $remediationName = "rem-$rgClean-$short-$timestamp"

            Write-Host "  Task: $refId" -ForegroundColor White

            $remResult = az policy remediation create `
                --name $remediationName `
                --policy-assignment $assignmentName `
                --definition-reference-id $refId `
                --resource-discovery-mode ReEvaluateCompliance `
                --resource-group $rg 2>&1

            if ($LASTEXITCODE -ne 0) {
                if ($remResult -match "active|not be changed|replaced while") {
                    Write-Warn "Task laeuft bereits - ueberspringe."
                } else {
                    Write-Warn "Task fehlgeschlagen:"
                    Write-Host "  $remResult" -ForegroundColor DarkGray
                }
            } else {
                $remObj = $remResult | ConvertFrom-Json -ErrorAction SilentlyContinue
                Write-Success "Erstellt: $remediationName | Status: $($remObj.provisioningState)"
            }
        }
    }
}

# ------------------------------------------------------------------
# Zusammenfassung
# ------------------------------------------------------------------
Write-Header "Zusammenfassung"
Write-Host ""
Write-Host "  Ziel         : Azure Arc-enabled Server (KEINE Azure VMs)" -ForegroundColor White
Write-Host "  OS-Filter    : $OsFilter ($($ActivePolicies.Count) Policies aktiv)" -ForegroundColor White
Write-Host "  Initiative   : $($arcInitiativeDef.displayName)" -ForegroundColor White
Write-Host "  Initiative ID: $ArcInitiativeId" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Resource Groups gesamt    : $($ResourceGroups.Count)" -ForegroundColor White
Write-Host "  Neu erstellt (Assignments): $successCount"            -ForegroundColor Green
Write-Host "  Aktualisiert (DCR-Fix)    : $updatedCount"            -ForegroundColor Cyan
Write-Host "  Uebersprungen             : $skippedCount"            -ForegroundColor DarkYellow
Write-Host "  Fehler                    : $errorCount"              -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host ""

if (($successCount + $skippedCount) -gt 0) {
    Write-Host "  Nächste Schritte:" -ForegroundColor Cyan
    Write-Host "  1. Policy Compliance prüfen (~30 min):  Azure Portal -> Policy -> Compliance" -ForegroundColor White
    Write-Host "  2. Remediation Tasks prüfen:            Azure Portal -> Policy -> Remediation -> Tasks" -ForegroundColor White
    Write-Host "  3. Arc-Server prüfen:                   Change Tracking and Inventory Center -> Machines" -ForegroundColor White
    Write-Host "  4. Extensions prüfen:                   Azure Portal -> Arc-Server -> Extensions" -ForegroundColor White
    Write-Host ""
    Write-Host "  Erwartete Extensions auf Arc-Servern nach erfolgreichem Deployment:" -ForegroundColor Cyan
    Write-Host "  - AzureMonitorWindowsAgent / AzureMonitorLinuxAgent" -ForegroundColor White
    Write-Host "  - ChangeTracking-Windows / ChangeTracking-Linux" -ForegroundColor White
    Write-Host ""
}

if ($errorCount -gt 0) {
    Write-Host "  Häufige Fehlerursachen:" -ForegroundColor Yellow
    Write-Host "  - Fehlende Rolle: 'Policy Contributor' auf der Subscription" -ForegroundColor White
    Write-Host "  - Falsche DCR Resource ID (az monitor data-collection rule list -o table)" -ForegroundColor White
    Write-Host "  - Arc-Server nicht korrekt onboarded (az connectedmachine list -o table)" -ForegroundColor White
    Write-Host ""
}

Write-Host "  Nützliche Befehle:" -ForegroundColor Cyan
Write-Host "  # Alle Arc-Assignments anzeigen:" -ForegroundColor DarkGray
Write-Host "  az policy assignment list --subscription $SubscriptionId --query `"[?contains(displayName,'Arc')]`" -o table" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  # Arc-Server in einer RG anzeigen:" -ForegroundColor DarkGray
Write-Host "  az connectedmachine list --resource-group <RG-NAME> -o table" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  # DCR-Liste anzeigen:" -ForegroundColor DarkGray
Write-Host "  az monitor data-collection rule list --subscription $SubscriptionId --query `"[].{Name:name, ID:id}`" -o table" -ForegroundColor DarkGray
Write-Host ""
