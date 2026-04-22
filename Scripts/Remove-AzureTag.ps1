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

# Ressourcengruppen ebenfalls berücksichtigen? ($true / $false)
$IncludeResourceGroups = $false

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
# Alle Ressourcen laden
# ----------------------------------------------------------
Write-Host "📦 Lade alle Ressourcen der Subscription..." -ForegroundColor Cyan
$resources = az resource list --subscription $SubscriptionId | ConvertFrom-Json
Write-Host "   → $($resources.Count) Ressourcen gefunden." -ForegroundColor Gray

$resourceGroups = @()
if ($IncludeResourceGroups) {
    Write-Host "📁 Lade Ressourcengruppen..." -ForegroundColor Cyan
    $resourceGroups = az group list --subscription $SubscriptionId | ConvertFrom-Json
    Write-Host "   → $($resourceGroups.Count) Ressourcengruppen gefunden." -ForegroundColor Gray
}

# ----------------------------------------------------------
# Alle Tag Key-Value-Pairs einsammeln
# ----------------------------------------------------------
Write-Host ""
Write-Host "🏷️  Sammle alle vorhandenen Tag Key-Value-Pairs..." -ForegroundColor Cyan

# tagPairs: Key = "TagName||TagValue", Value = Anzahl Ressourcen
$tagPairs = @{}
$allItems = @($resources) + @($resourceGroups)
$total    = $allItems.Count
$counter  = 0

foreach ($item in $allItems) {
    $counter++
    Write-Progress -Activity "Tags werden gesammelt..." `
                   -Status "$counter von $total" `
                   -PercentComplete (($counter / $total) * 100)

    $tagsJson = az tag list --resource-id $item.id 2>$null | ConvertFrom-Json
    $tags     = $tagsJson.properties.tags

    if ($tags) {
        foreach ($key in $tags.PSObject.Properties.Name) {
            $value    = $tags.$key
            $pairKey  = "$key||$value"
            if ($tagPairs.ContainsKey($pairKey)) {
                $tagPairs[$pairKey]++
            } else {
                $tagPairs[$pairKey] = 1
            }
        }
    }
}

Write-Progress -Completed -Activity "Tags werden gesammelt..."

if ($tagPairs.Count -eq 0) {
    Write-Host ""
    Write-Host "❌ Keine Tags in der Subscription gefunden. Script wird beendet." -ForegroundColor Red
    exit 0
}

# ----------------------------------------------------------
# Interaktive Tag-Auswahl (Key-Value-Pairs)
# ----------------------------------------------------------
$sortedPairs = $tagPairs.GetEnumerator() | Sort-Object { $_.Key }

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  #    Tag Name                        Tag Value               " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

$index      = 1
$pairList   = @()
foreach ($entry in $sortedPairs) {
    $parts    = $entry.Key -split "\|\|"
    $tagName  = $parts[0]
    $tagValue = if ($parts.Count -gt 1 -and $parts[1] -ne "") { $parts[1] } else { "(kein Wert)" }
    $count    = $entry.Value

    Write-Host ("  [{0,2}]  {1,-30}  {2,-25} ({3}x)" -f $index, $tagName, $tagValue, $count) -ForegroundColor White
    $pairList += @{ Name = $tagName; Value = $parts[1] }
    $index++
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Eingabe mit Validierung
do {
    $userInput     = Read-Host "Nummer des Tag-Pairs eingeben, das entfernt werden soll (1-$($pairList.Count))"
    $selectedIndex = $userInput -as [int]

    if ($selectedIndex -ge 1 -and $selectedIndex -le $pairList.Count) {
        $selectedPair = $pairList[$selectedIndex - 1]
        $TagName      = $selectedPair.Name
        $TagValue     = $selectedPair.Value
        Write-Host ""
        Write-Host "✅ Ausgewählt: " -ForegroundColor Green -NoNewline
        Write-Host "$TagName = $TagValue" -ForegroundColor Yellow
    } else {
        Write-Host "⚠️  Ungültige Eingabe. Bitte eine Zahl zwischen 1 und $($pairList.Count) eingeben." -ForegroundColor Red
        $selectedIndex = 0
    }
} while ($selectedIndex -lt 1)

# Bestätigung
$pairKey  = "$TagName||$TagValue"
$affectedCount = $tagPairs[$pairKey]
Write-Host ""
$confirm = Read-Host "Tag '$TagName = $TagValue' von $affectedCount Ressource(n) entfernen? (j/n)"
if ($confirm -notin @("j", "J", "ja", "Ja", "JA")) {
    Write-Host "❌ Abgebrochen." -ForegroundColor Red
    exit 0
}

Write-Host ""

# ----------------------------------------------------------
# Hilfsfunktion: Tag entfernen (nur wenn Key+Value übereinstimmt)
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

    # Nur entfernen wenn Value übereinstimmt
    $currentValue = $currentTags.$TagKey
    if ($currentValue -ne $TagVal) { return "skipped" }

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
# Verarbeitung
# ----------------------------------------------------------
$totalRemoved = 0
$totalFailed  = 0
$totalSkipped = 0

Write-Host "🚀 Starte Verarbeitung..." -ForegroundColor Cyan
Write-Host ""

foreach ($resource in $resources) {
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

if ($IncludeResourceGroups) {
    foreach ($rg in $resourceGroups) {
        $status = Remove-TagFromResource `
            -ResourceId   $rg.id `
            -ResourceName "RG: $($rg.name)" `
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
}

# ----------------------------------------------------------
# Zusammenfassung
# ----------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Zusammenfassung" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Tag             : $TagName = $TagValue"
if ($DryRun) {
    Write-Host " Würden entfernt : $totalRemoved" -ForegroundColor Magenta
} else {
    Write-Host " Entfernt        : $totalRemoved" -ForegroundColor Green
}
Write-Host " Übersprungen    : $totalSkipped"    -ForegroundColor DarkGray
Write-Host " Fehler          : $totalFailed"     -ForegroundColor $(if ($totalFailed -gt 0) { "Red" } else { "Gray" })
Write-Host "============================================" -ForegroundColor Cyan
