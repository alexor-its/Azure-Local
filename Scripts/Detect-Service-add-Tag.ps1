# ============================================================
# Variablen anpassen
# ============================================================
$ServiceName    = "MySQL80"             # Windows Service Name (SvcName)
$ServiceStatus  = "Running"             # Running | Stopped | Paused
$WorkspaceName  = "<LOG-ANALYTICS-WORKSPACE-NAME>"
$SubscriptionId = "<SUBSCRIPTION-ID>"
$TagName        = "Service"
$TagValue       = $ServiceName          # Alternativ festen Wert setzen z.B. "MySQL"

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
# 5. Workspace ID anhand des Namens auslesen
# ============================================================
Write-Host "→ Suche Log Analytics Workspace: $WorkspaceName"

$Workspace = az monitor log-analytics workspace list `
    --query "[?name=='$WorkspaceName'].{id:customerId, name:name, rg:resourceGroup}" `
    --output json 2>&1 | ConvertFrom-Json

if (-not $Workspace -or $Workspace.Count -eq 0) {
    Write-Host "✗ Workspace '$WorkspaceName' nicht gefunden." -ForegroundColor Red
    Write-Host "  Verfügbare Workspaces:" -ForegroundColor Yellow
    az monitor log-analytics workspace list --query "[].{Name:name, RG:resourceGroup}" --output table
    exit 1
}

$WorkspaceId = $Workspace[0].id
Write-Host "  ✓ Workspace gefunden: $($Workspace[0].name) (ID: $WorkspaceId)" -ForegroundColor Green

# ============================================================
# 6. Log Analytics via REST API abfragen
#    Tabelle: ConfigurationData — ConfigDataType: WindowsServices
#    Felder:  SvcName (interner Dienstname), SvcState (Running/Stopped/Paused)
# ============================================================
Write-Host "→ Suche Server mit Service '$ServiceName' im Status '$ServiceStatus'..."

$KqlQuery = "ConfigurationData | where TimeGenerated > ago(24h) | where ConfigDataType == 'WindowsServices' | where SvcName == '$ServiceName' | where SvcState == '$ServiceStatus' | summarize arg_max(TimeGenerated, *) by Computer, _ResourceId | project Computer, _ResourceId, SvcName, SvcDisplayName, SvcState, SvcStartupType"

$TempFile = [System.IO.Path]::GetTempFileName()
[ordered]@{ query = $KqlQuery } | ConvertTo-Json -Compress -Depth 1 | Set-Content -Path $TempFile -Encoding UTF8

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
    Write-Host "  ⚠ Keine Server mit Service '$ServiceName' im Status '$ServiceStatus' gefunden." -ForegroundColor Yellow
    exit 0
}

# Spaltenreihenfolge: Computer(0), _ResourceId(1), SvcName(2), SvcDisplayName(3), SvcState(4), SvcStartupType(5)
$Servers = $Rows | ForEach-Object {
    [PSCustomObject]@{
        Computer       = $_[0]
        ResourceId     = $_[1]
        SvcName        = $_[2]
        SvcDisplayName = $_[3]
        SvcState       = $_[4]
        SvcStartupType = $_[5]
    }
}

Write-Host "  ✓ $($Servers.Count) Server gefunden:" -ForegroundColor Green
$Servers | ForEach-Object {
    Write-Host "    - $($_.Computer) | $($_.SvcDisplayName) | Status: $($_.SvcState) | Startup: $($_.SvcStartupType)"
}

# ============================================================
# 7. Tags setzen
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
