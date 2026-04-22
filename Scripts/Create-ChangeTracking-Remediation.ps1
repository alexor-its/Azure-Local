<#
.SYNOPSIS
    Erstellt Remediation Tasks fuer die Change Tracking Arc-Policy Initiative
    auf allen konfigurierten Resource Groups.

.BESCHREIBUNG
    Da keine Remediation Tasks existieren, erstellt dieses Script pro Resource Group
    einen neuen Task fuer die gesamte Initiative (1 Task pro RG).
    DINE-Policies (Deploy If Not Exists) benoetigen einen Remediation Task um
    bereits vorhandene Arc-Server zu erfassen - neue Server werden automatisch behandelt.

.VORAUSSETZUNGEN
    - Azure CLI installiert
    - Eingeloggt via: az login
    - Policy Contributor Rolle auf Subscription
    - Rolle "Azure Connected Machine Resource Administrator" auf den RGs (bereits manuell vergeben)

.BEISPIEL
    .\Create-ChangeTracking-Remediation.ps1

.NOTES
    Passend zu : Deploy-ChangeTracking-Arc-Policy.ps1
    Initiative : Enable ChangeTracking and Inventory for Arc-enabled virtual machines
    ID         : 53448c70-089b-4f52-8f38-89196d7f2de1
#>

#Requires -Version 7.0

# ============================================================
# === KONFIGURATION - identisch zum Deploy-Script anpassen! ==
# ============================================================

$SubscriptionId = "<DEINE-SUBSCRIPTION-ID>"

# Dieselben Resource Groups wie im Deploy-Script
$ResourceGroups = @(
    "rg-arc-produktion",
    "rg-arc-entwicklung",
    "rg-arc-dmz"
    # Weitere Resource Groups hier hinzufuegen
)

# Muss identisch zum Deploy-Script sein
$AssignmentPrefix = "CT-Arc"

# ============================================================
# === ENDE KONFIGURATION =====================================
# ============================================================

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

function Write-Err {
    param([string]$Text)
    Write-Host "  [FEHLER] $Text" -ForegroundColor Red
}

# ------------------------------------------------------------------
# Voraussetzungen
# ------------------------------------------------------------------
Write-Header "Remediation Tasks erstellen - Change Tracking Arc Initiative"

if ($SubscriptionId -like "*<*") {
    Write-Err "Bitte 'SubscriptionId' in der Konfiguration eintragen!"
    exit 1
}
if ($ResourceGroups.Count -eq 0) {
    Write-Err "Bitte mindestens eine Resource Group eintragen!"
    exit 1
}

Write-Step "Pruefe Azure Login..."
$account = az account show 2>&1 | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $account) {
    Write-Host "  Nicht eingeloggt. Starte 'az login'..." -ForegroundColor Yellow
    az login
    $account = az account show | ConvertFrom-Json
}
Write-Success "Eingeloggt als: $($account.user.name)"

Write-Step "Setze Subscription: $SubscriptionId"
$null = az account set --subscription $SubscriptionId 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "Subscription '$SubscriptionId' nicht gefunden oder kein Zugriff."
    exit 1
}
Write-Success "Subscription aktiv: $SubscriptionId"

# ------------------------------------------------------------------
# Remediation Tasks erstellen
# ------------------------------------------------------------------
Write-Header "Erstelle Remediation Tasks (1 pro Resource Group)"

$successCount = 0
$errorCount   = 0
$timestamp    = Get-Date -Format 'yyyyMMddHHmm'

foreach ($rg in $ResourceGroups) {

    Write-Step "Resource Group: $rg"

    # Assignment-Namen rekonstruieren (identisch zum Deploy-Script)
    $rgClean        = ($rg -replace "[^a-zA-Z0-9-]", "").Substring(0, [Math]::Min(($rg -replace "[^a-zA-Z0-9-]","").Length, 24))
    $assignmentName = "$AssignmentPrefix-$rgClean"
    $scope          = "/subscriptions/$SubscriptionId/resourceGroups/$rg"

    # Assignment pruefen
    Write-Host "  Pruefe Assignment: $assignmentName" -ForegroundColor White
    $assignCheck = az policy assignment show --name $assignmentName --scope $scope 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Assignment '$assignmentName' nicht gefunden - ueberspringe RG '$rg'."
        Write-Host "  Tipp: az policy assignment list --scope $scope -o table" -ForegroundColor DarkGray
        $errorCount++
        continue
    }
    Write-Success "Assignment gefunden: $assignmentName"

    # Arc-Server in dieser RG anzeigen (informativ)
    $arcCount = az connectedmachine list `
        --resource-group $rg `
        --query "length(@)" -o tsv 2>&1
    if ($LASTEXITCODE -eq 0 -and $arcCount -match '^\d+$') {
        Write-Info "Arc-Server in dieser RG: $arcCount"
    }

    # Remediation Task erstellen
    $remediationName = "rem-arc-$rgClean-$timestamp"
    Write-Host "  Erstelle Remediation Task: $remediationName" -ForegroundColor White

    $remResult = az policy remediation create `
        --name $remediationName `
        --policy-assignment $assignmentName `
        --resource-group $rg 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Err "Remediation Task konnte nicht erstellt werden:"
        Write-Host "  $remResult" -ForegroundColor Red
        $errorCount++
        continue
    }

    $remObj = $remResult | ConvertFrom-Json -ErrorAction SilentlyContinue
    Write-Success "Remediation Task erstellt: $remediationName"
    Write-Info "Status: $($remObj.provisioningState)"
    $successCount++
}

# ------------------------------------------------------------------
# Zusammenfassung
# ------------------------------------------------------------------
Write-Header "Zusammenfassung"
Write-Host ""
Write-Host "  Resource Groups verarbeitet : $($ResourceGroups.Count)" -ForegroundColor White
Write-Host "  Tasks erfolgreich erstellt  : $successCount"            -ForegroundColor Green
Write-Host "  Fehler                      : $errorCount"              -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($successCount -gt 0) {
    Write-Host "  Naechste Schritte:" -ForegroundColor Cyan
    Write-Host "  1. Task-Status pruefen:" -ForegroundColor White
    Write-Host "     az policy remediation list --subscription $SubscriptionId -o table" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  2. Nach 15-60 Min Compliance pruefen:" -ForegroundColor White
    Write-Host "     Azure Portal -> Policy -> Compliance -> Initiative filtern" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  3. Extensions auf Arc-Servern pruefen:" -ForegroundColor White
    Write-Host "     Azure Portal -> Arc-Server -> Extensions" -ForegroundColor DarkGray
    Write-Host "     Erwartet: AzureMonitorWindowsAgent + ChangeTracking-Windows" -ForegroundColor DarkGray
    Write-Host ""
}

if ($errorCount -gt 0) {
    Write-Host "  Bei Fehlern pruefen:" -ForegroundColor Yellow
    Write-Host "  - Stimmt der AssignmentPrefix? (aktuell: '$AssignmentPrefix')" -ForegroundColor White
    Write-Host "  - Assignment-Namen pruefen:" -ForegroundColor White
    Write-Host "    az policy assignment list --subscription $SubscriptionId --query `"[?contains(displayName,'Arc')]`" -o table" -ForegroundColor DarkGray
    Write-Host ""
}
