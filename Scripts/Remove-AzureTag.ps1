# ============================================================
# Remove-AzureTag.ps1
# Entfernt einen ausgewählten Tag von allen Azure-Ressourcen
# und Ressourcengruppen im aktuellen Subscription
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

# Subscription setzen
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
# Alle vorhandenen Tags einsammeln
# ----------------------------------------------------------
Write-Host ""
Write-Host "🏷️  Sammle alle vorhandenen Tags..." -ForegroundColor Cyan

$tagMap   = @{}
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
            if ($tagMap.ContainsKey($key)) {
                $tagMap[$key]++
            } else {
                $tagMap[$key] = 1
            }
        }
    }
}

Write-Progress -Completed -Activity "Tags werden gesammelt..."

if ($tagMap.Count -eq 0) {
    Write-Host ""
    Write-Host "❌ Keine Tags in der Subscription gefunden. Script wird beendet." -ForegroundColor Red
    exit 0
}

# ----------------------------------------------------------
# Interaktive Tag-Auswahl
# ----------------------------------------------------------
$sortedTags = $tagMap.GetEnumerator() | Sort-Object Name

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Verfügbare Tags in der Subscription" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

$index   = 1
$tagList = @()
foreach ($entry in $sortedTags) {
    Write-Host ("  [{0,2}]  {1,-40} ({2} Ressource(n))" -f $index, $entry.Key, $entry.Value) -ForegroundColor White
    $tagList += $entry.Key
    $index++
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Eingabe mit Validierung
do {
    $userInput     = Read-Host "Nummer des Tags eingeben, der entfernt werden soll (1-$($tagList.Count))"
    $selectedIndex = $userInput -as [int]

    if ($selectedIndex -ge 1 -and $selectedIndex -le $tagList.Count) {
        $TagName = $tagList[$selectedIndex - 1]
        Write-Host ""
        Write-Host "✅ Ausgewählter Tag: " -ForegroundColor Green -NoNewline
        Write-Host $TagName -ForegroundColor Yellow
    } else {
        Write-Host "⚠️  Ungültige Eingabe. Bitte eine Zahl zwischen 1 und $($tagList.Count) eingeben." -ForegroundColor Red
        $selectedIndex = 0
    }
} while ($selectedIndex -lt 1)

# Bestätigung
Write-Host ""
$confirm = Read-Host "Tag '$TagName' von $($tagMap[$TagName]) Ressource(n) entfernen? (j/n)"
if ($confirm -notin @("j", "J", "ja", "Ja", "JA")) {
    Write-Host "❌ Abgebrochen." -ForegroundColor Red
    exit 0
}

Write-Host ""

# ----------------------------------------------------------
# Hilfsfunktion: Tag entfernen
# ----------------------------------------------------------
function Remove-TagFromResource {
    param(
        [string]$ResourceId,
        [string]$ResourceName,
        [string]$TagKey,
        [bool]$IsDryRun
    )

    $tagsJson    = az tag list --resource-id $ResourceId 2>$null | ConvertFrom-Json
    $currentTags = $tagsJson.properties.tags

    if (-not $currentTags) { return "skipped" }

    $tagExists = $currentTags.PSObject.Properties.Name -contains $TagKey
    if (-not $tagExists) { return "skipped" }

    Write-Host "  🏷️  $ResourceName" -ForegroundColor Yellow

    if ($IsDryRun) {
        Write-Host "     → [DRY-RUN] Würde Tag '$TagKey' entfernen." -ForegroundColor Magenta
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
# Tag von allen Ressourcen entfernen
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
Write-Host " Tag-Name        : $TagName"
if ($DryRun) {
    Write-Host " Würden entfernt : $totalRemoved" -ForegroundColor Magenta
} else {
    Write-Host " Entfernt        : $totalRemoved" -ForegroundColor Green
}
Write-Host " Übersprungen    : $totalSkipped"    -ForegroundColor DarkGray
Write-Host " Fehler          : $totalFailed"     -ForegroundColor $(if ($totalFailed -gt 0) { "Red" } else { "Gray" })
Write-Host "============================================" -ForegroundColor Cyan
