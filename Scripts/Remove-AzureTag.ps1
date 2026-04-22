# ============================================================
# Remove-AzureTag.ps1
# Entfernt ein ausgewähltes Tag Key-Value-Pair von allen
# Azure-Ressourcen in der aktuellen Subscription
# ============================================================

# ----------------------------------------------------------
# ⚙️  KONFIGURATION – hier anpassen
# ----------------------------------------------------------

# Subscription ID (leer lassen = aktive Subscription wird verwendet)
$SubscriptionId = ""

# Nur anzeigen was entfernt würde, ohne Änderungen vorzunehmen? ($true / $false)
$DryRun = $false

# ----------------------------------------------------------


# ----------------------------------------------------------
# Login-Prüfung
# ----------------------------------------------------------
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "⚠️  Nicht eingeloggt. Starte Azure Login..." -ForegroundColor Yellow
    az login | Out-Null
}

if ($SubscriptionId -ne "") {
    az account set --subscription $SubscriptionId | Out-Null
    Write-Host "✅ Subscription gesetzt: $SubscriptionId" -ForegroundColor Cyan
} else {
    $account = az account show | ConvertFrom-Json
    $SubscriptionId = $account.id
    Write-Host "✅ Aktive Subscription: $($account.name) ($SubscriptionId)" -ForegroundColor Cyan
}

Write-Host ""
if ($DryRun) {
    Write-Host "🔍 DRY-RUN Modus aktiv – es werden keine Änderungen vorgenommen." -ForegroundColor Magenta
    Write-Host ""
}

# ----------------------------------------------------------
# Alle Tag Key-Value-Pairs via Resource Graph sammeln
# (ein einzelner API-Call, keine Iteration über Ressourcen)
# ----------------------------------------------------------
Write-Host "🏷️  Lade alle Tag Key-Value-Pairs via Resource Graph..." -ForegroundColor Cyan

# Resource Graph Extension sicherstellen
az extension add --name resource-graph --only-show-errors 2>$null

$graphQuery = @"
Resources
| where isnotempty(tags)
| mvexpand bagexpansion=array tags
| extend tagKey   = tostring(tags[0])
| extend tagValue = tostring(tags[1])
| where isnotempty(tagKey)
| summarize count() by tagKey, tagValue
| order by tagKey asc, tagValue asc
"@

$graphResult = az graph query `
    -q $graphQuery `
    --subscriptions $SubscriptionId `
    --first 1000 `
    -o json 2>$null | ConvertFrom-Json

if (-not $graphResult -or $graphResult.count -eq 0) {
    Write-Host "❌ Keine Tags in der Subscription gefunden. Script wird beendet." -ForegroundColor Red
    exit 0
}

$pairList = @()
foreach ($row in $graphResult.data) {
    $pairList += @{
        Name  = $row.tagKey
        Value = $row.tagValue
        Count = $row.count_
    }
}

Write-Host "   → $($pairList.Count) Tag Key-Value-Pairs gefunden." -ForegroundColor Gray

# ----------------------------------------------------------
# Auswahlliste anzeigen
# ----------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ("  {0,-4}  {1,-30}  {2,-25}  {3}" -f "#", "Tag Name", "Tag Value", "Anzahl") -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

$index = 1
foreach ($pair in $pairList) {
    $displayValue = if ($pair.Value -ne "") { $pair.Value } else { "(kein Wert)" }
    Write-Host ("  [{0,2}]  {1,-30}  {2,-25}  ({3}x)" -f $index, $pair.Name, $displayValue, $pair.Count) -ForegroundColor White
    $index++
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------
# Eingabe mit Validierung
# ----------------------------------------------------------
do {
    $userInput     = Read-Host "Nummer des Tag-Pairs eingeben, das entfernt werden soll (1-$($pairList.Count))"
    $selectedIndex = $userInput -as [int]

    if ($selectedIndex -ge 1 -and $selectedIndex -le $pairList.Count) {
        $selectedPair = $pairList[$selectedIndex - 1]
        $TagName      = $selectedPair.Name
        $TagValue     = $selectedPair.Value
        $displayValue = if ($TagValue -ne "") { $TagValue } else { "(kein Wert)" }
        Write-Host ""
        Write-Host "✅ Ausgewählt: " -ForegroundColor Green -NoNewline
        Write-Host "$TagName = $displayValue" -ForegroundColor Yellow
    } else {
        Write-Host "⚠️  Ungültige Eingabe. Bitte eine Zahl zwischen 1 und $($pairList.Count) eingeben." -ForegroundColor Red
        $selectedIndex = 0
    }
} while ($selectedIndex -lt 1)

# Bestätigung
Write-Host ""
$confirm = Read-Host "Tag '$TagName = $displayValue' von $($selectedPair.Count) Ressource(n) entfernen? (j/n)"
if ($confirm -notin @("j", "J", "ja", "Ja", "JA")) {
    Write-Host "❌ Abgebrochen." -ForegroundColor Red
    exit 0
}

Write-Host ""

# ----------------------------------------------------------
# Hilfsfunktion: Tag entfernen (Key + Value müssen übereinstimmen)
# ----------------------------------------------------------
function Remove-TagFromResource {
    param(
        [string]$ResourceId,
        [string]$ResourceName,
        [string]$TagKey,
        [string]$TagVal,
        [bool]$IsDryRun
    )

    $tagsJson    = az tag list --resource-id $ResourceId 2>$null | ConvertFrom-Json
    $currentTags = $tagsJson.properties.tags

    if (-not $currentTags) { return "skipped" }

    $tagExists = $currentTags.PSObject.Properties.Name -contains $TagKey
    if (-not $tagExists) { return "skipped" }

    $currentValue = $currentTags.$TagKey
    if ($TagVal -ne "" -and $currentValue -ne $TagVal) { return "skipped" }

    Write-Host "  🏷️  $ResourceName" -ForegroundColor Yellow
    Write-Host "       $TagKey = $currentValue" -ForegroundColor DarkYellow

    if ($IsDryRun) {
        Write-Host "     → [DRY-RUN] Würde Tag-Pair entfernen." -ForegroundColor Magenta
        return "dryrun"
    }

    $result = az tag remove-value `
        --resource-id $ResourceId `
        --name $TagKey 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Host "     ✅ Entfernt." -ForegroundColor Green
        return "removed"
    } else {
        Write-Host "     ❌ Fehler: $result" -ForegroundColor Red
        return "failed"
    }
}

# ----------------------------------------------------------
# Alle Ressourcen laden und Tag entfernen
# ----------------------------------------------------------
$totalRemoved = 0
$totalFailed  = 0
$totalSkipped = 0

Write-Host "📦 Lade betroffene Ressourcen via Resource Graph..." -ForegroundColor Cyan

# Nur Ressourcen laden die den Tag auch wirklich haben
$filterQuery = @"
Resources
| where tags['$TagName'] == '$TagValue'
| project id, name, type
"@

$filteredResources = az graph query `
    -q $filterQuery `
    --subscriptions $SubscriptionId `
    --first 1000 `
    -o json 2>$null | ConvertFrom-Json

Write-Host "   → $($filteredResources.count) betroffene Ressourcen gefunden." -ForegroundColor Gray
Write-Host ""
Write-Host "🚀 Starte Verarbeitung..." -ForegroundColor Cyan
Write-Host ""

$counter = 0
foreach ($resource in $filteredResources.data) {
    $counter++
    Write-Progress -Activity "Tags werden entfernt..." `
                   -Status "$counter von $($filteredResources.count)" `
                   -PercentComplete (($counter / [Math]::Max($filteredResources.count, 1)) * 100)

    $status = Remove-TagFromResource `
        -ResourceId   $resource.id `
        -ResourceName "$($resource.name) [$($resource.type)]" `
        -TagKey       $TagName `
        -TagVal       $TagValue `
        -IsDryRun     $DryRun

    switch ($status) {
        "removed" { $totalRemoved++ }
        "dryrun"  { $totalRemoved++ }
        "failed"  { $totalFailed++  }
        "skipped" { $totalSkipped++ }
    }
}

Write-Progress -Completed -Activity "Tags werden entfernt..."

# ----------------------------------------------------------
# Zusammenfassung
# ----------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Zusammenfassung" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Tag             : $TagName = $displayValue"
if ($DryRun) {
    Write-Host " Würden entfernt : $totalRemoved" -ForegroundColor Magenta
} else {
    Write-Host " Entfernt        : $totalRemoved" -ForegroundColor Green
}
Write-Host " Übersprungen    : $totalSkipped"    -ForegroundColor DarkGray
Write-Host " Fehler          : $totalFailed"     -ForegroundColor $(if ($totalFailed -gt 0) { "Red" } else { "Gray" })
Write-Host "============================================" -ForegroundColor Cyan
