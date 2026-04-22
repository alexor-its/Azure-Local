<#
.SYNOPSIS
    Erstellt Remediation Tasks fuer jede einzelne DINE-Policy innerhalb der
    Change Tracking Arc-Initiative auf allen konfigurierten Resource Groups.

.BESCHREIBUNG
    Pro Resource Group werden 6 Remediation Tasks erstellt - einen pro Policy
    innerhalb der Initiative "Enable ChangeTracking and Inventory for Arc-enabled VMs".

    Die 6 Policies:
      1. DeployAMAWindowsHybridVMWithUAIChangeTrackingAndInventory
      2. DeployAMALinuxHybridVMWithUAIChangeTrackingAndInventory
      3. DeployChangeTrackingExtensionWindowsHybridVM
      4. DeployChangeTrackingExtensionLinuxHybridVM
      5. DCRAWindowsHybridVMChangeTrackingAndInventory
      6. DCRALinuxHybridVMChangeTrackingAndInventory

.VORAUSSETZUNGEN
    - Azure CLI installiert
    - Eingeloggt via: az login
    - Policy Contributor Rolle auf Subscription
    - Rolle "Azure Connected Machine Resource Administrator" auf den RGs

.BEISPIEL
    .\Create-ChangeTracking-Remediation.ps1

.NOTES
    Initiative : Enable ChangeTracking and Inventory for Arc-enabled virtual machines
    ID         : 53448c70-089b-4f52-8f38-89196d7f2de1
    Passend zu : Deploy-ChangeTracking-Arc-Policy.ps1
#>

#Requires -Version 7.0

# ============================================================
# === KONFIGURATION - identisch zum Deploy-Script anpassen! ==
# ============================================================

$SubscriptionId = "<DEINE-SUBSCRIPTION-ID>"

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

# Hardcodierte Policy Reference IDs der Arc Initiative
# Quelle: az policy set-definition show --name 53448c70-089b-4f52-8f38-89196d7f2de1
$PolicyReferenceIds = @(
    "DeployAMAWindowsHybridVMWithUAIChangeTrackingAndInventory",
    "DeployAMALinuxHybridVMWithUAIChangeTrackingAndInventory",
    "DeployChangeTrackingExtensionWindowsHybridVM",
    "DeployChangeTrackingExtensionLinuxHybridVM",
    "DCRAWindowsHybridVMChangeTrackingAndInventory",
    "DCRALinuxHybridVMChangeTrackingAndInventory"
)

# ------------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------------
function Write-Header {
    param([string]$Text)
    Write-Host "`n$("=" * 65)" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "$("=" * 65)" -ForegroundColor Cyan
}
function Write-Step    { param([string]$Text) Write-Host "`n  --> $Text" -ForegroundColor Yellow }
function Write-Success { param([string]$Text) Write-Host "  [OK]     $Text" -ForegroundColor Green }
function Write-Info    { param([string]$Text) Write-Host "  [INFO]   $Text" -ForegroundColor DarkYellow }
function Write-Warn    { param([string]$Text) Write-Host "  [WARN]   $Text" -ForegroundColor Magenta }
function Write-Err     { param([string]$Text) Write-Host "  [FEHLER] $Text" -ForegroundColor Red }

# ------------------------------------------------------------------
# Voraussetzungen
# ------------------------------------------------------------------
Write-Header "Remediation Tasks - Change Tracking Arc Initiative"

if ($SubscriptionId -like "*<*") { Write-Err "Bitte 'SubscriptionId' eintragen!"; exit 1 }
if ($ResourceGroups.Count -eq 0) { Write-Err "Bitte mindestens eine Resource Group eintragen!"; exit 1 }

Write-Step "Pruefe Azure Login..."
$account = az account show 2>&1 | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $account) {
    az login
    $account = az account show | ConvertFrom-Json
}
Write-Success "Eingeloggt als: $($account.user.name)"

Write-Step "Setze Subscription: $SubscriptionId"
$null = az account set --subscription $SubscriptionId 2>&1
if ($LASTEXITCODE -ne 0) { Write-Err "Subscription nicht gefunden oder kein Zugriff."; exit 1 }
Write-Success "Subscription aktiv: $SubscriptionId"

Write-Host ""
Write-Host "  Policy Reference IDs ($($PolicyReferenceIds.Count) Stueck):" -ForegroundColor White
foreach ($refId in $PolicyReferenceIds) {
    Write-Host "    - $refId" -ForegroundColor DarkGray
}

# ------------------------------------------------------------------
# Remediation Tasks pro RG und pro Policy erstellen
# ------------------------------------------------------------------
Write-Header "Erstelle Remediation Tasks ($($PolicyReferenceIds.Count) Tasks pro Resource Group)"

$timestamp    = Get-Date -Format 'yyyyMMddHHmm'
$successCount = 0
$errorCount   = 0
$rgErrorCount = 0

foreach ($rg in $ResourceGroups) {

    Write-Step "Resource Group: $rg"

    $rgClean        = ($rg -replace "[^a-zA-Z0-9-]", "").Substring(0, [Math]::Min(($rg -replace "[^a-zA-Z0-9-]","").Length, 20))
    $assignmentName = "$AssignmentPrefix-$rgClean"
    $scope          = "/subscriptions/$SubscriptionId/resourceGroups/$rg"

    # Assignment pruefen
    $assignCheck = az policy assignment show --name $assignmentName --scope $scope 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Assignment '$assignmentName' nicht gefunden - ueberspringe '$rg'."
        Write-Host "  Vorhandene Assignments anzeigen:" -ForegroundColor DarkGray
        Write-Host "  az policy assignment list --scope $scope -o table" -ForegroundColor DarkGray
        $rgErrorCount++
        continue
    }
    Write-Info "Assignment: $assignmentName"

    # Arc-Server zaehlen (informativ)
    $arcCount = az connectedmachine list --resource-group $rg --query "length(@)" -o tsv 2>&1
    if ($LASTEXITCODE -eq 0 -and $arcCount -match '^\d+$') {
        Write-Info "Arc-Server in dieser RG: $arcCount"
    }

    $rgSuccess = 0
    $rgError   = 0

    foreach ($refId in $PolicyReferenceIds) {

        # Remediation-Name aufbauen und auf 64 Zeichen kuerzen
        $refIdShort      = $refId.Substring(0, [Math]::Min($refId.Length, 20))
        $remNameRaw      = "rem-$rgClean-$refIdShort-$timestamp"
        $remediationName = $remNameRaw.Substring(0, [Math]::Min($remNameRaw.Length, 64))

        Write-Host "  Task: $refId" -ForegroundColor White

        $remResult = az policy remediation create `
            --name $remediationName `
            --policy-assignment $assignmentName `
            --definition-reference-id $refId `
            --resource-discovery-mode ReEvaluateCompliance `
            --resource-group $rg 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Err "Task fehlgeschlagen:"
            Write-Host "  $remResult" -ForegroundColor Red
            $rgError++
            $errorCount++
        } else {
            $remObj = $remResult | ConvertFrom-Json -ErrorAction SilentlyContinue
            Write-Success "Erstellt: $remediationName | Status: $($remObj.provisioningState)"
            $rgSuccess++
            $successCount++
        }
    }

    Write-Host ""
    Write-Host "  RG '$rg': $rgSuccess Tasks erstellt, $rgError Fehler" `
        -ForegroundColor $(if ($rgError -gt 0) { "Yellow" } else { "Green" })
}

# ------------------------------------------------------------------
# Zusammenfassung
# ------------------------------------------------------------------
Write-Header "Zusammenfassung"
Write-Host ""
Write-Host "  Resource Groups verarbeitet : $($ResourceGroups.Count - $rgErrorCount)" -ForegroundColor White
Write-Host "  RGs nicht gefunden          : $rgErrorCount"   -ForegroundColor $(if ($rgErrorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Tasks erfolgreich erstellt  : $successCount"   -ForegroundColor Green
Write-Host "  Tasks fehlgeschlagen        : $errorCount"     -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
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
    Write-Host "     Erwartet: AzureMonitorWindowsAgent + ChangeTracking-Windows/Linux" -ForegroundColor DarkGray
    Write-Host ""
}

if ($errorCount -gt 0 -or $rgErrorCount -gt 0) {
    Write-Host "  Bei Fehlern pruefen:" -ForegroundColor Yellow
    Write-Host "  - Assignment-Namen korrekt? (Prefix: '$AssignmentPrefix')" -ForegroundColor White
    Write-Host "    az policy assignment list --subscription $SubscriptionId --query `"[?contains(displayName,'Arc')]`" -o table" -ForegroundColor DarkGray
    Write-Host "  - Rolle korrekt gesetzt?" -ForegroundColor White
    Write-Host "    az role assignment list --subscription $SubscriptionId --query `"[?roleDefinitionName=='Azure Connected Machine Resource Administrator']`" -o table" -ForegroundColor DarkGray
    Write-Host ""
}
