
<#
.SYNOPSIS
    Weist die Azure Policy Initiative "Enable ChangeTracking and Inventory for virtual machines"
    auf mehrere Resource Groups zu und erstellt dabei automatisch Managed Identity & Remediation Tasks.

.BESCHREIBUNG
    Dieses Skript:
      1. Prüft Voraussetzungen (Login, Subscription, DCR-ID)
      2. Erstellt pro Resource Group ein Policy Assignment inkl. Managed Identity
      3. Erstellt automatisch einen Remediation Task für bestehende VMs

.VORAUSSETZUNGEN
    - Azure CLI installiert (az --version)
    - Eingeloggt via: az login
    - Contributor + Policy Contributor Rolle auf Subscription
    - Eine bestehende Data Collection Rule (DCR) für Change Tracking

.PARAMETER KONFIGURATION
    Bitte die Variablen im Abschnitt "=== KONFIGURATION ===" anpassen.

.BEISPIEL
    .\Deploy-ChangeTracking-Policy.ps1

.NOTES
    Initiative ID : 92a36f05-ebc9-4bba-9128-b47ad2ea3354
    Quelle        : https://learn.microsoft.com/azure/azure-change-tracking-inventory/enable-change-tracking-at-scale-policy
#>

#Requires -Version 7.0

# ============================================================
# === KONFIGURATION - Hier anpassen! =========================
# ============================================================

# Azure Subscription ID
$SubscriptionId = "<DEINE-SUBSCRIPTION-ID>"

# Data Collection Rule Resource ID (aus Azure Portal: DCR -> JSON-Ansicht -> id)
# Format: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Insights/dataCollectionRules/<name>
$DcrResourceId = "<DEINE-DCR-RESOURCE-ID>"

# User-Assigned Managed Identity Resource ID (wird für DINE-Policies benötigt)
# Format: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name>
# Leer lassen ("") wenn System-Assigned Identity verwendet werden soll
$UserAssignedIdentityId = ""

# Resource Groups, auf die die Policy angewendet werden soll
$ResourceGroups = @(
    "rg-produktion",
    "rg-entwicklung",
    "rg-staging"
    # Weitere Resource Groups hier hinzufügen
)

# Azure Regionen, für die die Policy gilt (kommagetrennt, z.B. "germanywestcentral,westeurope")
# Leer lassen für alle Regionen
$ApplicableLocations = "germanywestcentral,westeurope,northeurope"

# Präfix für den Assignment-Namen (max. 24 Zeichen gesamt inkl. RG-Name-Kürzel)
$AssignmentPrefix = "CT-Inventory"

# Remediation Task direkt nach Assignment erstellen? ($true / $false)
$CreateRemediationTask = $true

# ============================================================
# === ENDE KONFIGURATION =====================================
# ============================================================

# Builtin Initiative ID für "Enable ChangeTracking and Inventory for virtual machines"
$InitiativeId = "92a36f05-ebc9-4bba-9128-b47ad2ea3354"

# ------------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------------
function Write-Header {
    param([string]$Text)
    Write-Host "`n$("=" * 60)" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "$("=" * 60)" -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Text)
    Write-Host "`n  --> $Text" -ForegroundColor Yellow
}

function Write-Success {
    param([string]$Text)
    Write-Host "  [OK] $Text" -ForegroundColor Green
}

function Write-Err {
    param([string]$Text)
    Write-Host "  [FEHLER] $Text" -ForegroundColor Red
}

# ------------------------------------------------------------------
# Voraussetzungen prüfen
# ------------------------------------------------------------------
Write-Header "Voraussetzungen prüfen"

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
$null = az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) {
    Write-Err "Subscription '$SubscriptionId' nicht gefunden oder kein Zugriff."
    exit 1
}
Write-Success "Subscription aktiv: $SubscriptionId"

# Pflichtparameter prüfen
if ($SubscriptionId -like "*<*") {
    Write-Err "Bitte 'SubscriptionId' in der Konfiguration eintragen!"
    exit 1
}
if ($DcrResourceId -like "*<*") {
    Write-Err "Bitte 'DcrResourceId' in der Konfiguration eintragen!"
    exit 1
}

# Initiative Definition holen
Write-Step "Lade Policy Initiative Definition..."
$initiativeDef = az policy set-definition show --name $InitiativeId 2>&1 | ConvertFrom-Json
if (-not $initiativeDef) {
    Write-Err "Initiative '$InitiativeId' konnte nicht geladen werden."
    exit 1
}
Write-Success "Initiative gefunden: $($initiativeDef.displayName)"

# ------------------------------------------------------------------
# Assignment-Parameter vorbereiten
# ------------------------------------------------------------------
$locationParam = if ($ApplicableLocations) {
    $ApplicableLocations -split "," | ForEach-Object { $_.Trim() } | ConvertTo-Json -Compress
} else { "[]" }

$identityParam = if ($UserAssignedIdentityId -and $UserAssignedIdentityId -ne "") {
    "bringYourOwnUserAssignedManagedIdentity=true userAssignedIdentityResourceId=$UserAssignedIdentityId"
} else {
    "bringYourOwnUserAssignedManagedIdentity=false"
}

# ------------------------------------------------------------------
# Assignments erstellen
# ------------------------------------------------------------------
Write-Header "Policy Assignments erstellen"

$successCount = 0
$errorCount = 0
$assignmentIds = @{}

foreach ($rg in $ResourceGroups) {

    Write-Step "Verarbeite Resource Group: $rg"

    # Prüfen ob RG existiert
    $rgExists = az group show --name $rg --subscription $SubscriptionId 2>&1 | ConvertFrom-Json
    if (-not $rgExists) {
        Write-Err "Resource Group '$rg' nicht gefunden – überspringe."
        $errorCount++
        continue
    }

    $scope = "/subscriptions/$SubscriptionId/resourceGroups/$rg"

    # Assignment-Name generieren (max 64 Zeichen, keine Sonderzeichen)
    $rgShort = $rg -replace "[^a-zA-Z0-9]", "" | Select-Object -First 1
    $rgShort = ($rg -replace "[^a-zA-Z0-9-]", "").Substring(0, [Math]::Min($rg.Length, 20))
    $assignmentName = "$AssignmentPrefix-$rgShort"
    $displayName    = "ChangeTracking & Inventory - $rg"

    # Prüfen ob Assignment bereits existiert
    $existing = az policy assignment show --name $assignmentName --scope $scope 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [INFO] Assignment '$assignmentName' existiert bereits – überspringe." -ForegroundColor DarkYellow
        $existingObj = $existing | ConvertFrom-Json
        $assignmentIds[$rg] = $existingObj.id
        continue
    }

    Write-Host "  Erstelle Assignment: $assignmentName" -ForegroundColor White

    # Assignment erstellen mit System-Assigned Managed Identity (benötigt für DINE)
    $assignResult = az policy assignment create `
        --name $assignmentName `
        --display-name $displayName `
        --policy-set-definition $InitiativeId `
        --scope $scope `
        --mi-system-assigned `
        --location "westeurope" `
        --params "{
            `"dcrResourceId`": {`"value`": `"$DcrResourceId`"},
            `"bringYourOwnUserAssignedManagedIdentity`": {`"value`": $(if ($UserAssignedIdentityId) { 'true' } else { 'false' })},
            `"listOfApplicableLocations`": {`"value`": $locationParam}
            $(if ($UserAssignedIdentityId) { ",`"userAssignedIdentityResourceId`": {`"value`": `"$UserAssignedIdentityId`"}" })
        }" 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Err "Fehler beim Erstellen des Assignments für '$rg':"
        Write-Host "  $assignResult" -ForegroundColor Red
        $errorCount++
        continue
    }

    $assignObj = $assignResult | ConvertFrom-Json
    $assignmentIds[$rg] = $assignObj.id
    Write-Success "Assignment erstellt: $($assignObj.id)"

    # Rollenzuweisung für Managed Identity (Contributor auf RG-Ebene für DINE)
    Write-Host "  Weise Contributor-Rolle der Managed Identity zu..." -ForegroundColor White
    $principalId = $assignObj.identity.principalId

    if ($principalId) {
        # Kurz warten bis Identity bereit ist
        Start-Sleep -Seconds 15

        $roleResult = az role assignment create `
            --role "Contributor" `
            --assignee-object-id $principalId `
            --assignee-principal-type ServicePrincipal `
            --scope $scope 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [WARN] Rollenzuweisung fehlgeschlagen (ggf. manuell vergeben): $roleResult" -ForegroundColor DarkYellow
        } else {
            Write-Success "Contributor-Rolle zugewiesen (Principal: $principalId)"
        }
    }

    $successCount++
}

# ------------------------------------------------------------------
# Remediation Tasks erstellen
# ------------------------------------------------------------------
if ($CreateRemediationTask -and $assignmentIds.Count -gt 0) {

    Write-Header "Remediation Tasks erstellen (für bestehende VMs)"

    foreach ($rg in $assignmentIds.Keys) {

        $scope = "/subscriptions/$SubscriptionId/resourceGroups/$rg"
        $rgShort = ($rg -replace "[^a-zA-Z0-9-]", "").Substring(0, [Math]::Min($rg.Length, 20))
        $assignmentName = "$AssignmentPrefix-$rgShort"
        $remediationName = "remediate-$rgShort-$(Get-Date -Format 'yyyyMMddHHmm')"

        Write-Step "Erstelle Remediation Task für: $rg"

        $remResult = az policy remediation create `
            --name $remediationName `
            --policy-assignment $assignmentName `
            --resource-group $rg 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [WARN] Remediation Task fehlgeschlagen: $remResult" -ForegroundColor DarkYellow
        } else {
            Write-Success "Remediation Task gestartet: $remediationName"
        }
    }
}

# ------------------------------------------------------------------
# Zusammenfassung
# ------------------------------------------------------------------
Write-Header "Zusammenfassung"
Write-Host ""
Write-Host "  Resource Groups verarbeitet : $($ResourceGroups.Count)" -ForegroundColor White
Write-Host "  Erfolgreich                 : $successCount" -ForegroundColor Green
Write-Host "  Fehler                      : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($successCount -gt 0) {
    Write-Host "  Nächste Schritte:" -ForegroundColor Cyan
    Write-Host "  1. Azure Portal -> Policy -> Compliance prüfen (kann ~30min dauern)" -ForegroundColor White
    Write-Host "  2. Remediation Tasks unter Policy -> Remediation -> Tasks prüfen" -ForegroundColor White
    Write-Host "  3. Nach Deployment: Change Tracking & Inventory Center -> Machines prüfen" -ForegroundColor White
    Write-Host ""
}

if ($errorCount -gt 0) {
    Write-Host "  Bei Fehlern prüfen:" -ForegroundColor Yellow
    Write-Host "  - Hast du 'Policy Contributor' Rolle auf der Subscription?" -ForegroundColor White
    Write-Host "  - Ist die DCR Resource ID korrekt?" -ForegroundColor White
    Write-Host "  - Existieren alle Resource Groups?" -ForegroundColor White
    Write-Host ""
}

Write-Host "  Assignments auflisten:" -ForegroundColor Cyan
Write-Host "  az policy assignment list --subscription $SubscriptionId --query `"[?contains(displayName,'ChangeTracking')]`"" -ForegroundColor DarkGray
Write-Host ""
