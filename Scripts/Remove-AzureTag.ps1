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
# Resource Graph Extension prüfen
# ----------------------------------------------------------
$rgExt = az extension list 2>$null | ConvertFrom-Json | Where-Object { $_.name -eq "resource-graph" }
if (-not $rgExt) {
    Write-Host "📦 Installiere resource-graph Extension..." -ForegroundColor Yellow
    az extension add --name resource-graph --only-show-errors 2>$null
}

# ----------------------------------------------------------
# Alle Tag Key-Value-Pairs via Resource Graph laden
# Die Query gibt pro Ressource die Tags als Objekt zurück.
# PowerShell expandiert die Properties selbst – kein mvexpand.
# ----------------------------------------------------------
Write-Host "🏷️  Lade alle Tag Key-Value-Pairs via Resource Graph..." -ForegroundColor Cyan

$tagQuery = 'Resources | where isnotempty(tags) | project tags'

$allRows  = @()
$skipToken = $null
do {
    if ($skipToken) {
        $raw = az graph query -q $tagQuery --subscriptions $SubscriptionId --first 1000 --skip-token $skipToken -o json 2>$null | ConvertFrom-Json
    } else {
        $raw = az graph query -q $tagQuery --subscriptions $SubscriptionId --first 1000 -o json 2>$null | ConvertFrom-Json
    }
    $allRows  += $raw.data
    $skipToken = $raw.skipToken
} while ($skipToken)

if (-not $allRows -or $allRows.Count -eq 0) {
    Write-Host "❌ Keine Tags in der Subscription gefunden. Script wird beendet." -ForegroundColor Red
    exit 0
}

# Tags aus jedem Ressource-Objekt extrahieren und aggregieren
$tagMap = @{}  # "TagName||TagValue" -> Anzahl

foreach ($row in $allRows) {
    $tags = $row.tags
    if (-not $tags) { continue }
    foreach ($prop in $tags.PSObject.Properties) {
        $pairKey = "$($prop.Name)||$($prop.Value)"
        if ($tagMap.ContainsKey($pairKey)) { $tagMap[$pairKey]++ }
        else                               { $tagMap[$pairKey] = 1 }
    }
}

if ($tagMap.Count -eq 0) {
    Write-Host "❌ Keine Tags gefunden. Script wird beendet." -ForegroundColor Red
    exit 0
}

# Sortierte Liste aufbauen
$pairList = @()
foreach ($entry in ($tagMap.GetEnumerator() | Sort-Object Name)) {
    $parts = $entry.Key -split "\|\|", 2
    $pairList += [PSCustomObject]@{
        Name  = $parts[0]
        Value = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        Count = $entry.Value
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

for ($i = 0; $i -lt $pairList.Count; $i++) {
    $pair         = $pairList[$i]
    $displayValue = if ($pair.Value -ne "") { $pair.Value } else { "(kein Wert)" }
    Write-Host ("  [{0,2}]  {1,-30}  {2,-25}  ({3}x)" -f ($i + 1), $pair.Name, $displayValue, $pair.Count) -ForegroundColor White
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

# ----------------------------------------------------------
# Bestätigung
# ----------------------------------------------------------
Write-Host ""
$confirm = Read-Host "Tag '$TagName = $displayValue' von $($selectedPair.Count) Ressource(n) entfernen? (j/n)"
if ($confirm -notin @("j", "J", "ja", "Ja", "JA")) {
    Write-Host "❌ Abgebrochen." -ForegroundColor Red
    exit 0
}

Write-Host ""

# ----------------------------------------------------------
# Nur betroffene Ressourcen via Resource Graph laden
# ----------------------------------------------------------
Write-Host "📦 Lade betroffene Ressourcen via Resource Graph..." -ForegroundColor Cyan

$escapedName  = $TagName  -replace "'", "''"
$escapedValue = $TagValue -replace "'", "''"
$filterQuery  = "Resources | where tags['$escapedName'] == '$escapedValue' | project id, name, type"

$affectedRows = @()
$skipToken    = $null
do {
    if ($skipToken) {
        $raw = az graph query -q $filterQuery --subscriptions $SubscriptionId --first 1000 --skip-token $skipToken -o json 2>$null | ConvertFrom-Json
    } else {
        $raw = az graph query -q $filterQuery --subscriptions $SubscriptionId --first 1000 -o json 2>$null | ConvertFrom-Json
    }
    $affectedRows += $raw.data
    $skipToken     = $raw.skipToken
} while ($skipToken)

if (-not $affectedRows -or $affectedRows.Count -eq 0) {
    Write-Host "⚠️  Keine Ressourcen mit diesem Tag gefunden." -ForegroundColor Yellow
    exit 0
}

Write-Host "   → $($affectedRows.Count) betroffene Ressourcen gefunden." -ForegroundColor Gray
Write-Host ""
Write-Host "🚀 Starte Verarbeitung..." -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------
# Tag entfernen
# ----------------------------------------------------------
$totalRemoved = 0
$totalFailed  = 0
$counter      = 0

foreach ($resource in $affectedRows) {
    $counter++
    Write-Progress -Activity "Tags werden entfernt..." `
                   -Status "$counter von $($affectedRows.Count)" `
                   -PercentComplete (($counter / $affectedRows.Count) * 100)

    Write-Host "  🏷️  $($resource.name) [$($resource.type)]" -ForegroundColor Yellow

    if ($DryRun) {
        Write-Host "     → [DRY-RUN] Würde Tag '$TagName = $TagValue' entfernen." -ForegroundColor Magenta
        $totalRemoved++
        continue
    }

    $result = az tag remove-value --resource-id $resource.id --name $TagName 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Host "     ✅ Entfernt." -ForegroundColor Green
        $totalRemoved++
    } else {
        Write-Host "     ❌ Fehler: $result" -ForegroundColor Red
        $totalFailed++
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
Write-Host " Fehler          : $totalFailed" -ForegroundColor $(if ($totalFailed -gt 0) { "Red" } else { "Gray" })
Write-Host "============================================" -ForegroundColor Cyan
