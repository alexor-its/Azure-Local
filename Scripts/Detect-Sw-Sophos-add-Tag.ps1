# ============================================================
# Variablen anpassen
# ============================================================
$SubscriptionId = "<SUBSCRIPTION-ID>"
$WorkspaceId    = "<LOG-ANALYTICS-WORKSPACE-ID>"
$TagName        = "Software"
$TagValue       = "Sophos"
$RequiredExtensions = @("log-analytics", "connectedmachine")

# ============================================================
# 1. Azure CLI installiert?
# ============================================================
Write-Host "→ Prüfe Azure CLI Installation..."
$AzVersion = az version --output json 2>&1 | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $AzVersion) {
    Write-Host "✗ Azure CLI nicht gefunden: https://aka.ms/installazurecliwindows" -ForegroundColor Red
    exit 1
}
Write-Host "  ✓ Azure CLI $($AzVersion.'azure-cli') gefunden." -ForegroundColor Green

# ============================================================
# 2. Extensions prüfen
# ============================================================
Write-Host "→ Prüfe CLI Extensions..."
$InstalledExtensions = az extension list --query "[].name" --output json | ConvertFrom-Json
foreach ($Ext in $RequiredExtensions) {
    if ($InstalledExtensions -contains $Ext) {
        Write-Host "  ✓ Extension vorhanden: $Ext" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ Extension fehlt: $Ext — wird installiert..." -ForegroundColor Yellow
        az extension add --name $Ext --output none 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ✗ Installation fehlgeschlagen: $Ext" -ForegroundColor Red
            exit 1
        }
        Write-Host "  ✓ Extension installiert: $Ext" -ForegroundColor Green
    }
}

# ============================================================
# 3. Login prüfen
# ============================================================
Write-Host "→ Prüfe Azure Login..."
$AccountInfo = az account show --output json 2>&1 | ConvertFrom-Json
if (-not $AccountInfo -or $AccountInfo.id -eq $null) {
    Write-Host "  Nicht eingeloggt — starte Login..." -ForegroundColor Yellow
    az login
    $AccountInfo = az account show --output json 2>&1 | ConvertFrom-Json
    if (-not $AccountInfo) {
        Write-Host "✗ Login fehlgeschlagen." -ForegroundColor Red
        exit 1
    }
}
Write-Host "  ✓ Eingeloggt als: $($AccountInfo.user.name)" -ForegroundColor Green

# ============================================================
# 4. Subscription setzen
# ============================================================
Write-Host "→ Setze Subscription: $SubscriptionId"
az account set --subscription $SubscriptionId 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Subscription nicht gefunden: $SubscriptionId" -ForegroundColor Red
    az account list --query "[].{Name:name, ID:id, State:state}" --output table
    exit 1
}
$ActiveSub = az account show --query "{Name:name, ID:id}" --output json | ConvertFrom-Json
Write-Host "  ✓ Aktive Subscription: $($ActiveSub.Name) ($($ActiveSub.ID))" -ForegroundColor Green

# ============================================================
# 5. Log Analytics via REST API abfragen
# ============================================================
Write-Host "→ Frage Log Analytics Workspace ab (REST API)..."

$KqlQuery = "ConfigurationData | where TimeGenerated > ago(24h) | where ConfigDataType == 'Software' | where SoftwareName == 'Sophos Endpoint Agent' | summarize arg_max(TimeGenerated, *) by Computer, _ResourceId | project Computer, _ResourceId"

# Body als temporäre Datei — az rest übergibt @pfad unverändert
$TempFile = [System.IO.Path]::GetTempFileName()
[ordered]@{ query = $KqlQuery } | ConvertTo-Json -Compress -Depth 1 | Set-Content -Path $TempFile -Encoding UTF8

Write-Host "  Body: $(Get-Content $TempFile)" -ForegroundColor DarkGray

$RawResult = az rest `
    --method POST `
    --url "https://api.loganalytics.io/v1/workspaces/$WorkspaceId/query" `
    --headers "Content-Type=application/json" `
    --body "@$TempFile" `
    --output json 2>&1

Remove-Item $TempFile -Force -ErrorAction SilentlyContinue

if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Log Analytics REST Abfrage fehlgeschlagen:" -ForegroundColor Red
    Write-Host "  $RawResult" -ForegroundColor Red
    exit 1
}

$Parsed = $RawResult | ConvertFrom-Json
$Rows   = $Parsed.tables[0].rows

if (-not $Rows -or $Rows.Count -eq 0) {
    Write-Host "  ⚠ Keine Server mit Sophos Endpoint Agent gefunden." -ForegroundColor Yellow
    exit 0
}

$Servers = $Rows | ForEach-Object {
    [PSCustomObject]@{
        Computer   = $_[0]
        ResourceId = $_[1]
    }
}

Write-Host "  ✓ $($Servers.Count) Server gefunden:" -ForegroundColor Green
$Servers | ForEach-Object { Write-Host "    - $($_.Computer)" }

# ============================================================
# 6. Tags setzen
# ============================================================
foreach ($Server in $Servers) {
    Write-Host "→ Verarbeite: $($Server.Computer)"

    az tag update `
        --resource-id $Server.ResourceId `
        --operation Merge `
        --tags "${TagName}=${TagValue}" `
        --output none 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ✗ Tag konnte nicht gesetzt werden: $($Server.Computer)" -ForegroundColor Red
    } else {
        Write-Host "  ✓ Tag gesetzt: ${TagName}=${TagValue}" -ForegroundColor Green
    }
}

Write-Host "→ Fertig." -ForegroundColor Cyan