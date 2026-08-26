#Requires -Version 5.1
<#
.SYNOPSIS
    SCHRITT 5 von 6 - Erstellt EINE E-Mail-Alert-Regel fuer mehrere Laufwerke
    aller Arc Windows Server. Server und Laufwerk erscheinen dynamisch im
    Mail-Betreff.
.DESCRIPTION
    Ablauf der Script-Reihe:
      0. Set-ArcVirtualServerTag.ps1   - Tag Monitoring=VirtualServer setzen
      1. New-ArcVmInsightsDcr.ps1      - DCR anlegen + Bestand assoziieren
      2. Test-ArcMonitoringPrereq.ps1  - Abdeckung pruefen
      3. New-ArcMonitoringPolicy.ps1   - Policy + RBAC + Remediation
      4. Get-ArcDiskSpace.ps1          - Ist-Werte abfragen
      5. New-ArcDiskSpaceAlert.ps1     - E-Mail-Alert einrichten (dieses Script)
      6. New-ArcDiskSpaceWorkbook.ps1  - Dashboard deployen

    Werkzeuge ausserhalb der Reihe:
      Get-ArcDcrDetail.ps1        - Diagnose: was sammelt welche DCR wohin
      Rename-ArcVmInsightsDcr.ps1 - einmalige Migration bei DCR-Umbenennung
      Test-ArcDiskSpaceAlert.ps1  - Diagnose: warum kommt keine Mail

    AENDERUNGEN IN 5.0.0 - ACHT KORREKTUREN AUS DER FEHLERANALYSE
    -------------------------------------------------------------------------
    Anlass: Die Regel lief, aber es kamen keine Mails, obwohl mehrere Server
    unter dem Schwellwert lagen. Ursachenanalyse ergab acht Punkte.

    (1) MASCHINEN-TAGS WURDEN CASE-SENSITIV VERGLICHEN
        Alt:  tostring(tags['Monitoring']) != 'VirtualServer'
        In Resource Graph ist sowohl der TAG-NAME in tags['...'] als auch der
        Vergleich mit != case-sensitiv. Ein Tag 'monitoring' oder ein Wert
        'Windows Server 2022' liess die Maschine durchfallen - sie landete auf
        der Ausschlussliste, die fest in die Alert-Query geschrieben wird.
        Im Extremfall wurde der komplette Bestand ausgeschlossen und die Query
        lieferte nie eine Zeile.
        Neu: tags wird als JSON-String komplett auf Kleinschreibung gezogen
        (todynamic(tolower(tostring(tags)))), Namen UND Werte werden dadurch
        case-insensitiv verglichen.

    (2) MASSENAUSSCHLUSS WURDE NICHT BEMERKT
        Neu: Stufe 1 ermittelt zusaetzlich die Gesamtzahl der Arc-Maschinen
        und bricht ab, wenn der Ausschlussanteil $MaxExclusionRatio
        ueberschreitet. Das verhindert genau den Fall aus (1).

    (3) 'MIN 2 VON 2 PERIODEN' WAR ZU SCHARF
        bin() schneidet auf absolute Uhrzeitgrenzen, das Lookback-Fenster
        (windowSize x numberOfEvaluationPeriods) haengt dagegen am
        Auswertungszeitpunkt. Randbins sind deshalb angeschnitten. Bei
        '2 von 2' muss JEDER Punkt verletzen - ein duenner Randbin kippt die
        Bedingung still.
        Neu: $MinFailingPeriods = 1. Die Daempfung bleibt erhalten (es wird
        weiterhin ueber zwei Perioden geschaut), aber der Bin-Versatz kann
        den Alarm nicht mehr verschlucken.

    (4) KQL-VERGLEICHE WAREN CASE-SENSITIV
        'where Drive in (...)'      -> in~
        'where _ResourceId has ...' -> contains
        has arbeitet termbasiert; der Operand '/microsoft.hybridcompute/
        machines/' enthaelt / und . als Termtrenner und ist damit kein
        sauberer Term.

    (5) STILLE FILTER WAREN NICHT SICHTBAR
        Neu: Stufe 3 listet vor der Anlage auf, welche Laufwerksbuchstaben im
        Workspace vorkommen, aber nicht in $Drives stehen, und welche Server
        durch $ExcludeNamePatterns wegfallen.

    (6) DIE QUERY WURDE NIE GEGENGEPRUEFT
        Neu: Stufe 3b fuehrt die fertige Query einmal gegen den Workspace aus.
        Liefert sie null Zeilen, bricht das Script ab, statt eine blinde Regel
        anzulegen.

    (7) PATCH-BODY MIT BOM UND VERLUST DER CUSTOM PROPERTIES
        Set-Content -Encoding UTF8 schreibt unter Windows PowerShell 5.1 ein
        BOM; 'az rest --body @datei' stolpert darueber. Ausserdem ersetzt das
        PATCH properties.actions komplett - die bei der Anlage gesetzten
        customProperties gingen dabei verloren.
        Neu: UTF8 ohne BOM ueber [System.IO.File]::WriteAllText, Temp-Pfad
        ueber [System.IO.Path]::GetTempPath() (laeuft auch unter PS 7 auf
        Linux), und customProperties werden im PATCH mitgeschickt.

    (8) POWERSHELL-KOMPATIBILITAET
        Neu: $PowerShellMode, Versionspruefung im Pre-Check, Symbole zur
        Laufzeit ueber ConvertFromUtf32, Quellcode reines ASCII,
        Assert-AzSuccess nach externen Aufrufen, Invoke-AzQuiet als Wrapper.
        Funktion Ensure-Extension in Confirm-AzExtension umbenannt
        (genehmigtes Verb).

    HINWEIS ZUM STATEFUL-VERHALTEN (keine Aenderung, nur Klarstellung)
    -------------------------------------------------------------------------
    Bei $NotificationMode = 'AutoResolve' ist die Regel STATEFUL. Pro
    Instanz (Server + Laufwerk) geht genau EINE Mail raus. Solange der Alarm
    offen ist, kommt keine weitere - auch wenn der Platz weiter schrumpft.
    Erst nach der Aufloesung kann dieselbe Instanz erneut feuern. Wer bei
    anhaltender Knappheit wiederkehrende Mails will, braucht 'Suppress' mit
    einer $MuteActionsDuration als Wiederholungsintervall.

    EINE REGEL FUER ALLE LAUFWERKE
    -------------------------------------------------------------------------
    Dimension-Splitting auf 'Computer' UND 'Drive' erzeugt je Kombination
    aus Server und Laufwerk eine eigene Alert-Instanz. Getrennte Regeln je
    Laufwerk sind deshalb nicht noetig - solange derselbe Schwellwert gilt.

    Braucht ihr je Laufwerk unterschiedliche Grenzen (z. B. C: 15 %, D: 5 %),
    fuehrt kein Weg an getrennten Regeln vorbei: eine Scheduled Query Rule
    kennt genau einen Schwellwert.

    WARUM TAGS NICHT DIREKT WIRKEN
    -------------------------------------------------------------------------
    Eine Log Search Alert Rule fragt Log Analytics ab. Dort gibt es KEINE
    Azure-Tags. Ein Cross-Query gegen Resource Graph ist in einer Alert-Regel
    nicht moeglich. Das Script loest beides deshalb ZUR ANLAGEZEIT auf und
    schreibt die Ausnahmen fest in die Query.

    WICHTIG: Das ist eine MOMENTAUFNAHME. Neue Disk-Tags oder neue Server
    ohne Tags wirken sich erst nach einem erneuten Lauf dieses Scripts aus.

    ACTION GROUP UND EMPFAENGER
    -------------------------------------------------------------------------
    'az monitor action-group create' fuehrt ein PUT aus - die Ressource wird
    komplett durch das ersetzt, was im Aufruf steht. Alles im Portal manuell
    Ergaenzte ist danach weg. $EmailRecipients ist die alleinige Quelle der
    Wahrheit. Die Action Group wird NICHT vorher geloescht, damit es kein
    Zeitfenster gibt, in dem ein feuernder Alarm ins Leere laeuft.

    DOKUMENTIERTE GRENZEN VON AZURE MONITOR
    -------------------------------------------------------------------------
      Dimensionen je Regel   max. 6            -> wir nutzen 2
      Regel-Eigenschaften    max. 64 KB        -> wird geprueft, Warnung ab 48
      Beschreibung           max. 4096 Zeichen -> wird geprueft
      Stateful-Regel         max. 300 Alarme je Auswertung, Azure kappt still
      E-Mail                 max. 100/Stunde je Adresse, 100/5 Min je Regel
.NOTES
    =========================================================================
    Author      : Alexander Ortha
    Company     : Alexander Ortha IT Solutions
    Contact     : https://ortha-itsolutions.de/
    Created     : 18.08.2026
    Version     : 5.0.0
    Copyright   : (c) 2026 Alexander Ortha IT Solutions. All rights reserved.
    -------------------------------------------------------------------------
    Code created by Alexander Ortha.
    Development supported through AI-tools.
    =========================================================================
.EXAMPLE
    .\New-ArcDiskSpaceAlert.ps1
.EXAMPLE
    # Vorschau - zeigt Query, Condition, Ausnahmen und Betreff
    $WhatIfMode = $true; .\New-ArcDiskSpaceAlert.ps1
#>

$env:PYTHONWARNINGS = "ignore"

# =============================================================================
#  KONFIGURATION
# =============================================================================

# --- PowerShell-Modus ---
# "Compat" laeuft unter Windows PowerShell 5.1 und PowerShell 7.x.
# "Seven"  bricht unter 5.1 ab.
$PowerShellMode         = "Compat"

# --- Azure-Kontext ---
$SubscriptionId         = "33207861-9482-4afb-9786-eba3a0265bef"   # Azure Local
$WorkspaceName          = "law-LDK-VirtualServer"
$WorkspaceResourceGroup = "rg-arcmgmt"
$AlertResourceGroup     = "rg-arcmgmt"
$Location               = "westeurope"

# --- Action Group / Empfaenger ---
# Array statt Hashtable: Anzeigenamen duerfen sich wiederholen, Schluessel
# einer Hashtable muessten eindeutig sein.
$ActionGroupName        = "ag-arc-diskspace"
$ActionGroupShortName   = "ArcDisk"                    # max. 12 Zeichen
$EmailRecipients        = @(
    @{ Name = "ITAlert";   Address = "statusmails@ortha-itsolutions.de" }
    # @{ Name = "Bereitsch"; Address = "bereitschaft@example.de" }
    # @{ Name = "Helpdesk";  Address = "helpdesk@example.de" }
)

# --- Alert-Regel ---
$RuleName               = "alert-arc-disk-below-15pct"
$RuleDisplayName        = "Arc Windows Server: Laufwerk unter 15 % frei"
$Severity               = 2                            # 0=schwerwiegend ... 4=info
$ThresholdPercent       = 15
$Drives                 = @("C:", "D:", "E:")
# Spalte der Query, die den Messwert traegt. Muss zum 'project' der Query
# passen - siehe STUFE 3.
$MetricColumn           = "FreePercent"
$EvaluationFrequency    = "PT15M"
$WindowSize             = "PT15M"
$NumberOfEvalPeriods    = 2

# KORREKTUR (3): 1 statt 2.
# Der Query-Lookback ist windowSize x numberOfEvaluationPeriods, also 30 Min.
# bin(TimeGenerated, 15m) schneidet aber auf absolute Uhrzeitgrenzen. Die
# Randbins sind deshalb angeschnitten und teils duenn besetzt. Mit '2 von 2'
# musste JEDER Punkt verletzen - ein schwacher Randbin hat den Alarm still
# verschluckt. Mit 1 bleibt die Zwei-Perioden-Sicht erhalten, ohne dass der
# Bin-Versatz die Regel unwirksam macht.
$MinFailingPeriods      = 1

# --- Benachrichtigungsmodus ---------------------------------------------
# Azure erlaubt genau EINES von beiden. Die API lehnt die Kombination ab:
#   "Auto mitigation must be disabled when action suppression is set"
#
#   'AutoResolve'  STATEFUL. Pro Instanz genau EINE Mail. Der Alarm loest
#                  sich selbst auf, sobald die Bedingung nicht mehr erfuellt
#                  ist, und es geht eine Resolved-Mail raus. Solange der
#                  Alarm offen steht, kommt KEINE weitere Mail.
#                  Nur in diesem Modus liefert ${data.essentials.monitorCondition}
#                  im Betreff etwas anderes als 'Fired'.
#
#   'Suppress'     Nach dem Feuern bleibt es fuer $MuteActionsDuration still,
#                  danach kann dieselbe Instanz erneut melden. Keine
#                  Entwarnung, dafuer wiederkehrende Erinnerungen bei
#                  anhaltender Knappheit.
$NotificationMode       = "AutoResolve"      # 'AutoResolve' oder 'Suppress'
$MuteActionsDuration    = "PT6H"             # nur bei 'Suppress' wirksam

# --- Serverauswahl ueber Maschinen-Tags ---
# Wird zur Anlagezeit gegen Resource Graph aufgeloest. Maschinen, die NICHT
# alle Tags tragen, werden namentlich aus der Query ausgeschlossen.
# Identisch zu $PolicyTagFilter in New-ArcMonitoringPolicy.ps1 halten.
# Vergleich laeuft seit 5.0.0 case-insensitiv (Tag-Name UND Wert).
$MachineTagFilter       = [ordered]@{
    "Monitoring"      = "VirtualServer"
    "OperatingSystem" = "Windows Server"
}
$ApplyMachineTagFilter  = $true

# KORREKTUR (2): Notbremse gegen Massenausschluss.
# Schliesst der Tag-Filter mehr als diesen Anteil des Bestands aus, ist mit
# hoher Wahrscheinlichkeit die Tag-Schreibweise schuld und nicht der Bestand.
# Das Script bricht dann ab, statt eine blinde Regel anzulegen.
$MaxExclusionRatio      = 0.80     # 0.0 - 1.0, oder $null zum Deaktivieren

# --- Laufwerks-Ausnahmen ueber Disk-Tags ---
# Tag auf der DISK-Ressource (Azure Local).
$DiskTagName            = "Monitoring"
$DiskTagValue           = "no-disccapacitymonitoring"
$ApplyDiskTagFilter     = $true
$SizeToleranceGB        = 1        # Toleranz beim Abgleich VHDX <-> Laufwerk

# --- Manuelle Ausnahmen (immer wirksam) ---
# Format: 'server|laufwerk', z. B. 'mxkkr8|D:'. Kurzname ohne Domaene.
$ExcludeDrives          = @()
# Ganze Server ausnehmen, unabhaengig vom Laufwerk.
$ExcludeServers         = @()
# Namensmuster (Regex), z. B. AVD-Hosts.
$ExcludeNamePatterns    = @('^avd')

# --- Betreff-Vorlage --------------------------------------------------------
# WICHTIG: einfache Anfuehrungszeichen! In doppelten wuerde PowerShell
# ${data...} als eigene Variable interpretieren und leer ersetzen.
#
# dimensions[0] = Computer, dimensions[1] = Drive - in der Reihenfolge, in
# der sie in der Condition stehen. Sollte der Betreff die Werte vertauscht
# zeigen, die beiden Indizes hier tauschen.
$EmailSubjectTemplate = '${data.alertContext.condition.allOf[0].dimensions[0].value}' `
                      + ' ${data.alertContext.condition.allOf[0].dimensions[1].value}' `
                      + ' - unter 15 % frei' `
                      + ' (${data.essentials.monitorCondition},' `
                      + ' ${data.alertContext.condition.allOf[0].metricValue} % frei)'

# --- Vorschaumodus ---
$WhatIfMode             = $false

# --- Laufzeitverhalten ---
$ErrorActionPreference  = "Continue"

# =============================================================================
#  AUSGABE - Symbole zur Laufzeit erzeugen, Quellcode bleibt ASCII
# =============================================================================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$SymOk   = [System.Char]::ConvertFromUtf32(0x2705)
$SymErr  = [System.Char]::ConvertFromUtf32(0x274C)
$SymWarn = [System.Char]::ConvertFromUtf32(0x26A0) + [System.Char]::ConvertFromUtf32(0xFE0F)
$SymInfo = [System.Char]::ConvertFromUtf32(0x2139) + [System.Char]::ConvertFromUtf32(0xFE0F)
$SymRun  = [System.Char]::ConvertFromUtf32(0x1F504)

function Write-Line  { Write-Host ("=" * 60) -ForegroundColor White }
function Write-Head  { param($T) Write-Host "[ $T ]" -ForegroundColor White }
function Write-Ok    { param($M) Write-Host "$SymOk  $(Get-Date -f '[HH:mm:ss]') $M" -ForegroundColor Green }
function Write-Fail  { param($M) Write-Host "$SymErr  $(Get-Date -f '[HH:mm:ss]') $M" -ForegroundColor Red }
function Write-Warn2 { param($M) Write-Host "$SymWarn  $(Get-Date -f '[HH:mm:ss]') $M" -ForegroundColor Yellow }
function Write-Info2 { param($M) Write-Host "$SymInfo  $(Get-Date -f '[HH:mm:ss]') $M" -ForegroundColor Cyan }
function Write-Run   { param($M) Write-Host "$SymRun  $(Get-Date -f '[HH:mm:ss]') $M" -ForegroundColor Cyan }
function Write-Sub   { param($M) Write-Host "    $M" }

# =============================================================================
#  AZURE-CLI-HELFER
# =============================================================================
$script:LastAzError = $null

function Assert-AzSuccess {
    <#
      Externe Programme melden Fehler ueber den Exitcode, nicht ueber
      Exceptions. try/catch allein wuerde sie nicht sehen.
    #>
    param([int]$ExitCode, [string]$ErrorText, [string]$Context)
    if ($ExitCode -ne 0) {
        $script:LastAzError = "$Context (Exitcode $ExitCode): $ErrorText"
        return $false
    }
    return $true
}

function Invoke-AzQuiet {
    <#
      Ruft Azure CLI auf und liefert sauberes JSON zurueck. Trennt stdout und
      stderr, damit Python-Warnungen der CLI-Extensions das JSON nicht
      zerstoeren. Argumente als Array, damit die Kommandozeile nichts zerlegt.
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)

    $script:LastAzError = $null
    $errFile = [System.IO.Path]::GetTempFileName()

    try {
        $raw  = & az @Arguments 2>$errFile
        $code = $LASTEXITCODE
        $err  = if (Test-Path $errFile) { (Get-Content $errFile -Raw) } else { "" }

        if (-not (Assert-AzSuccess -ExitCode $code -ErrorText ($err | Out-String).Trim() `
                                   -Context ("az " + (@($Arguments)[0..1] -join " ")))) {
            return $null
        }

        $text = ($raw | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }

        $start = $text.IndexOfAny([char[]]@('{', '['))
        if ($start -lt 0) { $script:LastAzError = "Keine JSON-Antwort erhalten: $text"; return $null }
        if ($start -gt 0) { $text = $text.Substring($start) }

        try   { return ($text | ConvertFrom-Json) }
        catch { $script:LastAzError = "JSON-Parsing fehlgeschlagen: $($_.Exception.Message)"; return $null }
    }
    finally { Remove-Item $errFile -ErrorAction SilentlyContinue }
}

function Confirm-AzExtension {
    # KORREKTUR (8): hiess frueher Ensure-Extension - 'Ensure' ist kein
    # genehmigtes PowerShell-Verb.
    param([Parameter(Mandatory)][string]$Name)

    $exts = Invoke-AzQuiet @("extension", "list")
    if ($exts | Where-Object { $_.name -eq $Name }) { return $true }

    Write-Warn2 "Extension '$Name' fehlt - wird installiert."
    az extension add --name $Name --only-show-errors 2>$null
    if (-not (Assert-AzSuccess -ExitCode $LASTEXITCODE -ErrorText "" -Context "az extension add $Name")) {
        Write-Fail "Installation von '$Name' fehlgeschlagen."
        return $false
    }
    return $true
}

function ConvertTo-KqlTimespan {
    <#
      Wandelt eine ISO-8601-Dauer in einen KQL-Timespan:
        PT5M -> 5m, PT15M -> 15m, PT1H -> 1h, PT30S -> 30s, P1D -> 1d
      Wird gebraucht, damit die bin()-Groesse in der Query IMMER zur
      konfigurierten $WindowSize passt.
    #>
    param([Parameter(Mandatory)][string]$Iso)

    $m = [regex]::Match($Iso, '^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$')
    if (-not $m.Success) { return $null }

    if ($m.Groups[1].Success) { return "$($m.Groups[1].Value)d" }
    if ($m.Groups[2].Success) { return "$($m.Groups[2].Value)h" }
    if ($m.Groups[3].Success) { return "$($m.Groups[3].Value)m" }
    if ($m.Groups[4].Success) { return "$($m.Groups[4].Value)s" }
    return $null
}

function Get-KqlListe {
    <#
      Baut eine KQL-Liste aus Strings: 'a','b','c'
      Leere Eingabe liefert $null - der Aufrufer laesst die Zeile dann weg,
      denn 'in~ ()' waere ein Syntaxfehler.
    #>
    param([string[]]$Werte)
    $w = @($Werte | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($w.Count -eq 0) { return $null }
    return (($w | ForEach-Object { "'$_'" }) -join ", ")
}

function Set-AlertEmailSubject {
    <#
      Setzt actionProperties/Email.Subject per REST-PATCH nach, weil die CLI
      dafuer keinen Parameter anbietet.

      KORREKTUR (7):
        - Der actions-Block wird beim PATCH KOMPLETT ersetzt. actionGroups
          UND customProperties muessen deshalb mitgeschickt werden, sonst
          gehen die bei der Anlage gesetzten Custom Properties verloren.
        - Der Body geht ueber eine Temp-Datei, weil az.cmd Inline-JSON unter
          Windows falsch zerlegt. Die Datei wird jetzt als UTF-8 OHNE BOM
          geschrieben; Set-Content -Encoding UTF8 erzeugt unter Windows
          PowerShell 5.1 ein BOM, an dem 'az rest --body @datei' scheitert.
        - Temp-Pfad ueber GetTempPath() statt $env:TEMP, damit es auch unter
          PowerShell 7 auf Linux funktioniert.
    #>
    param(
        [Parameter(Mandatory)][string]$ActionGroupId,
        [Parameter(Mandatory)][string]$Subject,
        [hashtable]$CustomProperties
    )

    $ruleId = "/subscriptions/$SubscriptionId/resourceGroups/$AlertResourceGroup" `
            + "/providers/Microsoft.Insights/scheduledQueryRules/$RuleName"

    $actions = @{
        actionGroups     = @($ActionGroupId)
        actionProperties = @{ "Email.Subject" = $Subject }
    }
    if ($CustomProperties -and $CustomProperties.Count -gt 0) {
        $actions["customProperties"] = $CustomProperties
    }

    $payload  = @{ properties = @{ actions = $actions } }
    $json     = $payload | ConvertTo-Json -Depth 10
    $bodyFile = Join-Path ([System.IO.Path]::GetTempPath()) "sqr-patch-$([guid]::NewGuid()).json"

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($bodyFile, $json, $utf8NoBom)

        return Invoke-AzQuiet @(
            "rest", "--method", "patch",
            "--url", "https://management.azure.com$($ruleId)?api-version=2023-12-01",
            "--headers", "Content-Type=application/json",
            "--body", "@$bodyFile"
        )
    }
    finally { Remove-Item $bodyFile -ErrorAction SilentlyContinue }
}

# =============================================================================
#  PRE-CHECK
# =============================================================================
Write-Line
Write-Head "PRE-CHECK"

# KORREKTUR (8): PowerShell-Version pruefen
Write-Run "Pruefe PowerShell-Version..."
$psVer = $PSVersionTable.PSVersion
if ($PowerShellMode -eq "Seven" -and $psVer.Major -lt 7) {
    Write-Fail "PowerShellMode 'Seven' verlangt PowerShell 7.x - gefunden $psVer."
    exit 1
}
Write-Ok "PowerShell $psVer (Modus: $PowerShellMode)"
if ($psVer.Major -ge 7 -and ($psVer.Major -gt 7 -or $psVer.Minor -ge 3)) {
    $PSNativeCommandUseErrorActionPreference = $false
    Write-Sub "PSNativeCommandUseErrorActionPreference deaktiviert."
}

Write-Run "Pruefe Azure CLI..."
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Fail "Azure CLI nicht gefunden. Installation: https://aka.ms/installazurecliwindows"
    exit 1
}
$verInfo = Invoke-AzQuiet @("version")
if ($verInfo) {
    Write-Ok "Azure CLI gefunden: $($verInfo.'azure-cli')"
    if ([version]$verInfo.'azure-cli' -lt [version]"2.54.0") {
        Write-Warn2 "Version < 2.54.0 - 'az monitor scheduled-query' benoetigt mindestens 2.54.0."
        Write-Sub "Aktualisierung: az upgrade"
    }
}
else { Write-Warn2 "Version nicht ermittelbar: $script:LastAzError" }

Write-Run "Pruefe Login..."
$account = Invoke-AzQuiet @("account", "show")
if (-not $account) { Write-Fail "Nicht angemeldet. Bitte 'az login' ausfuehren."; exit 1 }
Write-Ok "Login vorhanden: $($account.user.name)"
Write-Sub "Subscription: $($account.name) ($($account.id))"

if ($account.id -ne $SubscriptionId) {
    Write-Warn2 "Aktive Subscription weicht ab - wechsle zu $SubscriptionId"
    az account set --subscription $SubscriptionId 2>$null
    if (-not (Assert-AzSuccess -ExitCode $LASTEXITCODE -ErrorText "" -Context "az account set")) {
        Write-Fail "Subscription-Wechsel fehlgeschlagen."; exit 1
    }
    Write-Ok "Subscription gesetzt."
}

Write-Run "Pruefe benoetigte Extensions..."
$extOk = $true
foreach ($e in @("scheduled-query", "resource-graph", "log-analytics")) {
    if (-not (Confirm-AzExtension -Name $e)) { $extOk = $false }
}
if (-not $extOk) { exit 1 }
Write-Ok "Extensions verfuegbar."

Write-Run "Pruefe Workspace '$WorkspaceName'..."
$ws = Invoke-AzQuiet @("monitor", "log-analytics", "workspace", "show",
                       "--resource-group", $WorkspaceResourceGroup,
                       "--name", $WorkspaceName, "-o", "json")
if (-not $ws) { Write-Fail "Workspace nicht erreichbar: $script:LastAzError"; exit 1 }
Write-Ok "Workspace gefunden: $($ws.name) ($($ws.location))"
$WorkspaceResourceId = $ws.id

Write-Run "Pruefe vorhandene Alert-Regeln..."
$vorhandene = Invoke-AzQuiet @("monitor", "scheduled-query", "list",
                               "--resource-group", $AlertResourceGroup, "-o", "json")
if ($vorhandene) {
    $andere = @($vorhandene | Where-Object { $_.name -ne $RuleName })
    if ($andere.Count -gt 0) {
        Write-Warn2 "$($andere.Count) weitere Regel(n) in '$AlertResourceGroup':"
        foreach ($a in $andere) { Write-Sub "$($a.name)" }
        Write-Sub "Pruefen, ob eine davon dasselbe ueberwacht - sonst doppelte Mails."
    }
    if ($vorhandene | Where-Object { $_.name -eq $RuleName }) {
        Write-Info2 "'$RuleName' existiert bereits und wird ueberschrieben."
    }
}
Write-Line

# =============================================================================
#  STUFE 1 - SERVER-AUSNAHMEN AUS MASCHINEN-TAGS
# =============================================================================
Write-Head "STUFE 1 - MASCHINEN-TAGS"

$tagAusnahmen = @()

if (-not $ApplyMachineTagFilter) {
    Write-Info2 "Uebersprungen (`$ApplyMachineTagFilter = `$false)."
}
else {
    $krit = ($MachineTagFilter.Keys | ForEach-Object { "$_=$($MachineTagFilter[$_])" }) -join " UND "
    Write-Run "Suche Maschinen OHNE $krit..."

    # KORREKTUR (1): case-insensitiver Vergleich.
    # tags wird als JSON-Text komplett auf Kleinschreibung gezogen. Damit sind
    # sowohl die Schluessel (tags['Monitoring'] vs. tags['monitoring']) als
    # auch die Werte ('VirtualServer' vs. 'virtualserver') unempfindlich
    # gegen Schreibweisen. Maschinen ganz ohne Tags liefern null -> tostring
    # ergibt '' -> Bedingung trifft zu -> korrekt ausgeschlossen.
    #
    # Nur einfache Anfuehrungszeichen - doppelte ueberleben az.cmd nicht.
    $bed = ($MachineTagFilter.Keys | ForEach-Object {
                $k = $_.ToLower()
                $v = ([string]$MachineTagFilter[$_]).ToLower()
                "tostring(tl['$k']) != '$v'" }) -join " or "

    $q = "resources " `
       + "| where type =~ 'microsoft.hybridcompute/machines' " `
       + "| extend tl = todynamic(tolower(tostring(tags))) " `
       + "| where $bed " `
       + "| project name, " `
       +   "Monitoring = tostring(tl['monitoring']), " `
       +   "OS = tostring(tl['operatingsystem'])"

    $res = Invoke-AzQuiet @("graph", "query", "-q", $q, "--first", "1000", "-o", "json")
    if (-not $res) {
        Write-Fail "Abfrage fehlgeschlagen: $script:LastAzError"
        exit 1
    }

    $tagAusnahmen = @($res.data | ForEach-Object { $_.name.ToLower() })

    # KORREKTUR (2): Gesamtbestand ermitteln und Ausschlussanteil bewerten.
    $qGesamt = "resources " `
             + "| where type =~ 'microsoft.hybridcompute/machines' " `
             + "| summarize Gesamt = count()"
    $resGesamt = Invoke-AzQuiet @("graph", "query", "-q", $qGesamt, "-o", "json")
    $gesamt = 0
    if ($resGesamt -and $resGesamt.data) { $gesamt = [int]$resGesamt.data[0].Gesamt }

    if ($gesamt -gt 0) {
        $anteil = $tagAusnahmen.Count / [double]$gesamt
        Write-Ok "$($tagAusnahmen.Count) von $gesamt Maschine(n) erfuellen die Tag-Bedingung nicht ($([math]::Round($anteil*100,1)) %)."
    }
    else {
        Write-Ok "$($tagAusnahmen.Count) Maschine(n) erfuellen die Tag-Bedingung nicht."
        $anteil = 0
    }
    Write-Sub "Sie werden namentlich aus der Alert-Query ausgeschlossen."

    if ($null -ne $MaxExclusionRatio -and $gesamt -gt 0 -and $anteil -gt $MaxExclusionRatio) {
        Write-Host ""
        Write-Fail "Ausschlussanteil ueber $([math]::Round($MaxExclusionRatio*100,0)) % - Anlage abgebrochen."
        Write-Sub "So gut wie der ganze Bestand faellt durch den Tag-Filter. Die Regel"
        Write-Sub "wuerde angelegt, aber nie feuern. Wahrscheinliche Ursachen:"
        Write-Sub "  - Tag-Namen oder -Werte weichen ab (`$MachineTagFilter pruefen)"
        Write-Sub "  - Schritt 0 (Set-ArcVirtualServerTag.ps1) lief noch nicht"
        Write-Sub "Kontrolle:"
        Write-Sub "  az graph query -q `"resources | where type =~ 'microsoft.hybridcompute/machines' | summarize count() by tostring(tags)`""
        Write-Sub "Bewusst gewollt? Dann `$MaxExclusionRatio auf `$null setzen."
        exit 1
    }

    # Nur die relevanten anzeigen: solche, die ueberhaupt ein Monitoring-Tag
    # tragen. Voellig untaggte Maschinen liefern ohnehin keine Daten.
    $relevant = @($res.data | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Monitoring) })
    if ($relevant.Count -gt 0) {
        Write-Host ""
        Write-Info2 "Davon mit gesetztem Monitoring-Tag (potenzieller Altbestand):"
        foreach ($r in ($relevant | Sort-Object name)) {
            Write-Sub ("{0,-24} Monitoring={1}, OS={2}" -f $r.name, $r.Monitoring,
                       $(if ($r.OS) { $r.OS } else { "(leer)" }))
        }
    }
}
Write-Line

# =============================================================================
#  STUFE 2 - LAUFWERKS-AUSNAHMEN AUS DISK-TAGS
# =============================================================================
Write-Head "STUFE 2 - DISK-TAGS"

$diskAusnahmen = @()
$mehrdeutig    = @()

if (-not $ApplyDiskTagFilter) {
    Write-Info2 "Uebersprungen (`$ApplyDiskTagFilter = `$false)."
}
else {
    Write-Run "Lade Disks mit '$DiskTagName=$DiskTagValue'..."

    $q = "resources " `
       + "| where tags['$DiskTagName'] =~ '$DiskTagValue' " `
       + "| extend g = coalesce(toreal(properties.diskSizeGB), " `
       +   "toreal(properties.diskSizeBytes) / 1073741824.0, " `
       +   "toreal(properties.diskSizeMB) / 1024.0) " `
       + "| project Disk = name, " `
       +   "Server = tolower(tostring(split(name, '_')[0])), " `
       +   "GroesseGB = g"

    $res = Invoke-AzQuiet @("graph", "query", "-q", $q, "--first", "1000", "-o", "json")
    $tagDisks = if ($res -and $res.data) { @($res.data) } else { @() }

    if ($tagDisks.Count -eq 0) {
        Write-Info2 "Keine getaggten Disks gefunden."
    }
    else {
        Write-Ok "$($tagDisks.Count) getaggte Disk-Ressource(n):"
        foreach ($d in ($tagDisks | Sort-Object Server, Disk)) {
            Write-Sub ("{0,-34} Server={1,-16} {2,7:N1} GB" -f $d.Disk, $d.Server, $d.GroesseGB)
        }

        # --- Laufwerke mit Gesamtgroesse aus Log Analytics ---
        Write-Host ""
        Write-Run "Ermittle Laufwerksgroessen aus dem Workspace..."

        $kql = "InsightsMetrics" `
             + " | where TimeGenerated > ago(2h)" `
             + " | where Origin == 'vm.azm.ms'" `
             + " | where Namespace == 'LogicalDisk'" `
             + " | where Name in~ ('FreeSpacePercentage','FreeSpaceMB')" `
             + " | extend Drive = tostring(todynamic(Tags)['vm.azm.ms/mountId'])" `
             + " | summarize P = avgif(Val, Name == 'FreeSpacePercentage')," `
             +   " M = avgif(Val, Name == 'FreeSpaceMB') by Computer, Drive" `
             + " | where isnotnull(P) and isnotnull(M) and P > 0" `
             + " | project Server = tolower(tostring(split(Computer, '.')[0]))," `
             +   " Drive, GesamtGB = round((M / 1024.0) / (P / 100.0), 1)"

        $rows = Invoke-AzQuiet @("monitor", "log-analytics", "query",
                                 "--workspace", $ws.customerId,
                                 "--analytics-query", $kql, "-o", "json")

        if (-not $rows) {
            Write-Warn2 "Laufwerksgroessen nicht abrufbar - Disk-Tag-Filter entfaellt."
            Write-Sub "Ursache: $script:LastAzError"
            Write-Sub "Ausnahmen ggf. manuell in `$ExcludeDrives eintragen."
        }
        else {
            $rows = @($rows)
            Write-Ok "$($rows.Count) Laufwerk(e) aus dem Workspace."
            Write-Host ""

            foreach ($d in ($tagDisks | Sort-Object Server, Disk)) {
                $treffer = @($rows | Where-Object {
                    $_.Server -eq $d.Server -and
                    [math]::Abs([double]$_.GesamtGB - [double]$d.GroesseGB) -le $SizeToleranceGB
                })

                if ($treffer.Count -eq 1) {
                    $schluessel = "$($d.Server)|$($treffer[0].Drive)"
                    $diskAusnahmen += $schluessel
                    Write-Host ("    {0,-34} -> {1,-12} eindeutig" -f $d.Disk, $schluessel) -ForegroundColor Green
                }
                elseif ($treffer.Count -gt 1) {
                    $kandidaten = ($treffer | ForEach-Object { $_.Drive }) -join ", "
                    $mehrdeutig += [PSCustomObject]@{ Disk = $d.Disk; Server = $d.Server; Kandidaten = $kandidaten }
                    Write-Host ("    {0,-34} -> {1,-12} MEHRDEUTIG ({2})" -f `
                                $d.Disk, "?", $kandidaten) -ForegroundColor Yellow
                }
                else {
                    Write-Host ("    {0,-34} -> {1,-12} kein Treffer" -f $d.Disk, "-") -ForegroundColor DarkGray
                }
            }

            if ($mehrdeutig.Count -gt 0) {
                Write-Host ""
                Write-Warn2 "$($mehrdeutig.Count) Disk(s) nicht eindeutig zuordenbar - NICHT ausgeschlossen."
                Write-Sub "Zwei gleich grosse Laufwerke auf demselben Server. Eine geratene"
                Write-Sub "Ausnahme wuerde einen echten Alarm unterdruecken, ohne dass es"
                Write-Sub "auffaellt. Bitte manuell entscheiden und in `$ExcludeDrives eintragen:"
                foreach ($m in $mehrdeutig) {
                    Write-Sub "  $($m.Server)|<Laufwerk>   Kandidaten: $($m.Kandidaten)"
                }
            }
        }
    }
}
Write-Line

# =============================================================================
#  STUFE 3 - ABDECKUNG PRUEFEN
# =============================================================================
# KORREKTUR (5): Bisher wirkten $Drives und $ExcludeNamePatterns still. Jetzt
# wird vor der Anlage sichtbar gemacht, was dadurch aus der Ueberwachung
# faellt.
Write-Head "STUFE 3 - ABDECKUNG"

Write-Run "Ermittle vorhandene Server und Laufwerke im Workspace..."

$kqlBestand = "InsightsMetrics" `
            + " | where TimeGenerated > ago(2h)" `
            + " | where Origin == 'vm.azm.ms'" `
            + " | where Namespace == 'LogicalDisk' and Name == 'FreeSpacePercentage'" `
            + " | extend Drive = tostring(todynamic(Tags)['vm.azm.ms/mountId'])" `
            + " | extend Kurz = tolower(tostring(split(Computer, '.')[0]))" `
            + " | summarize FreePercent = round(avg(Val), 2) by Kurz, Drive"

$bestand = Invoke-AzQuiet @("monitor", "log-analytics", "query",
                            "--workspace", $ws.customerId,
                            "--analytics-query", $kqlBestand, "-o", "json")

if (-not $bestand) {
    Write-Warn2 "Bestand nicht abrufbar - Abdeckungspruefung entfaellt."
    Write-Sub "Ursache: $script:LastAzError"
    $bestand = @()
}
else {
    $bestand = @($bestand)
    $serverAlle = @($bestand | ForEach-Object { $_.Kurz } | Select-Object -Unique)
    Write-Ok "$($bestand.Count) Laufwerk(e) auf $($serverAlle.Count) Server(n) liefern Daten."

    # Laufwerksbuchstaben, die nicht in $Drives stehen
    $fremdeDrives = @($bestand | Where-Object { $Drives -notcontains $_.Drive } |
                      Group-Object Drive | Sort-Object Name)
    if ($fremdeDrives.Count -gt 0) {
        Write-Host ""
        Write-Warn2 "Nicht ueberwachte Laufwerksbuchstaben (nicht in `$Drives):"
        foreach ($g in $fremdeDrives) {
            $knapp = @($g.Group | Where-Object { [double]$_.FreePercent -lt $ThresholdPercent })
            $txt = "{0,-8} {1,4} Laufwerk(e)" -f $g.Name, $g.Count
            if ($knapp.Count -gt 0) {
                Write-Host ("    $txt  davon $($knapp.Count) unter $ThresholdPercent %") -ForegroundColor Red
            }
            else { Write-Sub $txt }
        }
        Write-Sub "Bei Bedarf in `$Drives aufnehmen."
    }

    # Server, die durch Namensmuster wegfallen
    $viaMuster = @()
    foreach ($s in $serverAlle) {
        foreach ($pat in $ExcludeNamePatterns) {
            if ($s -match $pat) { $viaMuster += $s; break }
        }
    }
    if ($viaMuster.Count -gt 0) {
        Write-Host ""
        Write-Warn2 "$($viaMuster.Count) Server fallen durch `$ExcludeNamePatterns weg:"
        Write-Sub (($viaMuster | Sort-Object) -join ", ")
    }
}
Write-Line

# =============================================================================
#  STUFE 4 - QUERY BAUEN
# =============================================================================
Write-Head "STUFE 4 - ALERT-QUERY"

$alleServerAusnahmen = @($ExcludeServers + $tagAusnahmen | ForEach-Object { $_.ToLower() })
$alleDriveAusnahmen  = @($ExcludeDrives + $diskAusnahmen | ForEach-Object { $_.ToLower() })

# Nur einfache Anfuehrungszeichen im KQL - doppelte ueberleben az.cmd nicht.
$p = New-Object System.Collections.Generic.List[string]
$p.Add("InsightsMetrics")
$p.Add("where Origin == 'vm.azm.ms'")
$p.Add("where Namespace == 'LogicalDisk' and Name == 'FreeSpacePercentage'")

# KORREKTUR (4): contains statt has.
# has sucht termbasiert; '/microsoft.hybridcompute/machines/' enthaelt / und .
# als Termtrenner und ist damit kein sauberer Term. contains prueft den
# Teilstring case-insensitiv und ist hier eindeutig.
$p.Add("where _ResourceId contains '/microsoft.hybridcompute/machines/'")

# KQL kennt KEIN '!matches regex' - die Negation laeuft ueber not().
foreach ($pat in $ExcludeNamePatterns) {
    $p.Add("where not(Computer matches regex '(?i)$pat')")
}

$p.Add("extend Drive = tostring(todynamic(Tags)['vm.azm.ms/mountId'])")
$lst = Get-KqlListe -Werte $Drives
if (-not $lst) {
    Write-Fail "`$Drives ist leer - die Regel haette keinen Bezug."
    exit 1
}
# KORREKTUR (4): in~ statt in - unempfindlich gegen 'c:' vs. 'C:'.
$p.Add("where Drive in~ ($lst)")

# Kurzname als Dimension - der FQDN macht den Mail-Betreff unleserlich.
$p.Add("extend Kurz = tolower(tostring(split(Computer, '.')[0]))")

$lst = Get-KqlListe -Werte $alleServerAusnahmen
if ($lst) { $p.Add("where Kurz !in~ ($lst)") }

$lst = Get-KqlListe -Werte $alleDriveAusnahmen
if ($lst) { $p.Add("where strcat(Kurz, '|', Drive) !in~ ($lst)") }

# TimeGenerated ist PFLICHT, sobald mehr als eine Auswertungsperiode
# konfiguriert ist. Die API lehnt sonst ab mit:
#   "Number of evaluation periods must be 1 for queries that do not
#    project the 'TimeGenerated' column of type 'datetime'"
$bin = ConvertTo-KqlTimespan -Iso $WindowSize
if (-not $bin) {
    Write-Fail "`$WindowSize = '$WindowSize' ist keine gueltige ISO-8601-Dauer."
    Write-Sub "Erwartet z. B. PT5M, PT15M, PT1H."
    exit 1
}

$p.Add("summarize FreePercent = avg(Val) by bin(TimeGenerated, $bin), Computer = Kurz, Drive, _ResourceId")
$p.Add("project TimeGenerated, Computer, Drive, FreePercent, resourceId = _ResourceId")

$query = ($p -join " | ")

# Gegenpruefung: die Metric Measure Column muss in der Query vorkommen.
if ($query -notmatch [regex]::Escape($MetricColumn)) {
    Write-Fail "Spalte '$MetricColumn' kommt in der Query nicht vor."
    Write-Sub "`$MetricColumn muss zum project der Query passen."
    exit 1
}

if ($NumberOfEvalPeriods -gt 1 -and $query -notmatch "TimeGenerated") {
    Write-Fail "Bei mehr als einer Auswertungsperiode muss die Query TimeGenerated liefern."
    Write-Sub "Entweder bin(TimeGenerated, ...) in die Query aufnehmen"
    Write-Sub "oder `$NumberOfEvalPeriods auf 1 setzen."
    exit 1
}

if ($MinFailingPeriods -gt $NumberOfEvalPeriods) {
    Write-Fail "`$MinFailingPeriods ($MinFailingPeriods) ist groesser als `$NumberOfEvalPeriods ($NumberOfEvalPeriods)."
    exit 1
}
if ($MinFailingPeriods -eq $NumberOfEvalPeriods -and $NumberOfEvalPeriods -gt 1) {
    Write-Warn2 "'$MinFailingPeriods von $NumberOfEvalPeriods' verlangt, dass JEDER Punkt verletzt."
    Write-Sub "bin() schneidet auf absolute Uhrzeitgrenzen, das Lookback-Fenster haengt"
    Write-Sub "am Auswertungszeitpunkt. Angeschnittene Randbins koennen die Bedingung"
    Write-Sub "still kippen. `$MinFailingPeriods = 1 ist deutlich robuster."
}

# --- Dimension-Splitting auf Computer UND Drive -----------------------------
# Je Kombination eine eigene Alert-Instanz. Die Reihenfolge hier bestimmt die
# dimensions[]-Indizes im Mail-Betreff.
#
# "'FreePercent' from" ist die METRIC MEASURE COLUMN. Laut CLI-Grammatik
# optional, bei ZWEI Dimensionen lehnt die API die Regel ohne diese Angabe
# aber mit 'Metric Measure Column was not specified' ab.
$condition = "min '$MetricColumn' from 'Placeholder_1' < $ThresholdPercent " `
           + "resource id resourceId " `
           + "where Computer includes * and Drive includes * " `
           + "at least $MinFailingPeriods violations out of $NumberOfEvalPeriods aggregated points"

$description = "Feuert, wenn auf einem Arc Windows Server der freie Speicher eines " `
             + "ueberwachten Laufwerks ($($Drives -join ', ')) unter " `
             + "$ThresholdPercent % sinkt."

# --- Dokumentierte Grenzwerte pruefen ---------------------------------
$eigenschaftenGroesse = ($query.Length + $condition.Length + $description.Length +
                         $RuleDisplayName.Length + $EmailSubjectTemplate.Length)

if ($description.Length -gt 4096) {
    Write-Fail "Beschreibung hat $($description.Length) Zeichen - erlaubt sind 4096."
    exit 1
}

if ($eigenschaftenGroesse -gt 65536) {
    Write-Fail "Regel-Eigenschaften ca. $([math]::Round($eigenschaftenGroesse/1024,1)) KB - Grenze 64 KB."
    Write-Sub "Meist verursacht durch zu viele Ausnahmen in der Query."
    Write-Sub "Abhilfe: Ausnahmen zusammenfassen oder Server verschieben."
    exit 1
}
elseif ($eigenschaftenGroesse -gt 49152) {
    Write-Warn2 "Regel-Eigenschaften ca. $([math]::Round($eigenschaftenGroesse/1024,1)) KB - Grenze 64 KB."
    Write-Sub "Bei weiter wachsender Ausnahmeliste wird das eng."
}

Write-Sub "Regel        : $RuleName"
Write-Sub "Anzeigename  : $RuleDisplayName"
Write-Sub "Laufwerke    : $($Drives -join ', ')"
Write-Sub "Schwellwert  : < $ThresholdPercent % frei (Spalte: $MetricColumn)"
Write-Sub "Modus        : $NotificationMode"
Write-Sub "Zeitfenster  : $WindowSize (bin: $bin)"
Write-Sub "Ausloesung   : $MinFailingPeriods von $NumberOfEvalPeriods Perioden"
Write-Sub "Server-Ausnahmen : $($alleServerAusnahmen.Count)"
Write-Sub "Laufwerks-Ausnahmen : $($alleDriveAusnahmen.Count)"
if ($alleDriveAusnahmen.Count -gt 0) {
    foreach ($a in ($alleDriveAusnahmen | Sort-Object)) { Write-Sub "  $a" }
}
Write-Line

# =============================================================================
#  STUFE 5 - QUERY-PROBELAUF
# =============================================================================
# KORREKTUR (6): Die fertige Query einmal ausfuehren, bevor eine Regel darauf
# gebaut wird. Eine Regel auf einer leeren Query wird anstandslos angelegt und
# feuert nie - genau das war der Fehlerfall.
Write-Head "STUFE 5 - QUERY-PROBELAUF"

$lookbackMin = 0
$mWin = [regex]::Match($WindowSize, '^PT(?:(\d+)H)?(?:(\d+)M)?$')
if ($mWin.Success) {
    if ($mWin.Groups[1].Success) { $lookbackMin += [int]$mWin.Groups[1].Value * 60 }
    if ($mWin.Groups[2].Success) { $lookbackMin += [int]$mWin.Groups[2].Value }
}
if ($lookbackMin -eq 0) { $lookbackMin = 15 }
$lookbackMin = $lookbackMin * $NumberOfEvalPeriods

Write-Run "Fuehre die Query ueber $lookbackMin Minuten aus..."
$probe = Invoke-AzQuiet @("monitor", "log-analytics", "query",
                          "--workspace", $ws.customerId,
                          "--analytics-query", $query,
                          "--timespan", "PT$($lookbackMin)M", "-o", "json")

if ($null -eq $probe) {
    Write-Fail "Die Query liefert keine Zeilen oder ist fehlerhaft."
    Write-Sub "Ursache: $script:LastAzError"
    Write-Sub "Eine Regel auf dieser Query wuerde nie feuern - Anlage abgebrochen."
    Write-Host ""
    Write-Sub "Query zum Nachstellen im Portal:"
    Write-Host "    $query" -ForegroundColor DarkGray
    exit 1
}

$probe = @($probe)
if ($probe.Count -eq 0) {
    Write-Fail "Die Query liefert 0 Zeilen - Anlage abgebrochen."
    Write-Sub "Haeufigste Ursachen: zu viele Tag-Ausnahmen, falsche Laufwerksliste,"
    Write-Sub "oder es kommen keine InsightsMetrics-Daten im Workspace an."
    Write-Host ""
    Write-Sub "Query zum Nachstellen im Portal:"
    Write-Host "    $query" -ForegroundColor DarkGray
    exit 1
}

$serien = $probe | Group-Object -Property { "$($_.Computer)|$($_.Drive)" }
Write-Ok "$($probe.Count) Zeile(n) in $($serien.Count) Serie(n)."

$unterSchwelle = @()
foreach ($g in $serien) {
    $werte = @($g.Group | ForEach-Object { [double]$_.$MetricColumn })
    $verletzt = @($werte | Where-Object { $_ -lt $ThresholdPercent })
    if ($verletzt.Count -gt 0) {
        $unterSchwelle += [PSCustomObject]@{
            Serie    = $g.Name
            Bins     = $g.Group.Count
            Verletzt = $verletzt.Count
            Min      = ($werte | Measure-Object -Minimum).Minimum
            Feuert   = ($g.Group.Count -ge $NumberOfEvalPeriods -and $verletzt.Count -ge $MinFailingPeriods)
        }
    }
}

if ($unterSchwelle.Count -eq 0) {
    Write-Info2 "Aktuell liegt keine Serie unter $ThresholdPercent %."
}
else {
    Write-Host ""
    Write-Info2 "Serien unter $ThresholdPercent % - so wuerde die Regel jetzt entscheiden:"
    Write-Host ""
    foreach ($u in ($unterSchwelle | Sort-Object Min)) {
        $farbe  = if ($u.Feuert) { "Green" } else { "Yellow" }
        $urteil = if ($u.Feuert) { "FEUERT" } else { "$($u.Verletzt)/$($u.Bins) Bins - zu wenig" }
        Write-Host ("    {0,-26} {1,8:N2} %  {2}" -f $u.Serie, $u.Min, $urteil) -ForegroundColor $farbe
    }

    $stumm = @($unterSchwelle | Where-Object { -not $_.Feuert })
    if ($stumm.Count -gt 0) {
        Write-Host ""
        Write-Warn2 "$($stumm.Count) Serie(n) unter Schwellwert wuerden NICHT feuern."
        Write-Sub "Entweder liegen zu wenige Bins vor (frisch angebundene Server) oder"
        Write-Sub "die Bedingung '$MinFailingPeriods von $NumberOfEvalPeriods' ist zu scharf."
    }
}
Write-Line

# =============================================================================
#  STUFE 6 - ACTION GROUP
# =============================================================================
Write-Head "STUFE 6 - ACTION GROUP"

if ($EmailRecipients.Count -eq 0) {
    Write-Fail "Keine Empfaenger in `$EmailRecipients."
    exit 1
}

Write-Sub "Empfaenger:"
foreach ($e in $EmailRecipients) { Write-Sub "  $($e.Name)  <$($e.Address)>" }
Write-Host ""
Write-Warn2 "'az monitor action-group create' ersetzt die Ressource vollstaendig."
Write-Sub "Im Portal ergaenzte Empfaenger, SMS oder Webhooks gehen dabei verloren."

if ($WhatIfMode) {
    Write-Line
    Write-Head "WHATIF"
    Write-Info2 "Es wird nichts angelegt."
    Write-Host ""
    Write-Sub "Query:"
    Write-Host "    $query" -ForegroundColor DarkGray
    Write-Host ""
    Write-Sub "Condition:"
    Write-Host "    $condition" -ForegroundColor DarkGray
    Write-Host ""
    Write-Sub "Betreff:"
    Write-Host "    $EmailSubjectTemplate" -ForegroundColor DarkGray
    Write-Line
    exit 0
}

# --action email <Name> <Adresse> je Empfaenger
$agArgs = @("monitor", "action-group", "create",
            "--resource-group", $AlertResourceGroup,
            "--name", $ActionGroupName,
            "--short-name", $ActionGroupShortName)
foreach ($e in $EmailRecipients) {
    $agArgs += @("--action", "email", $e.Name, $e.Address)
}
$agArgs += @("-o", "json")

Write-Run "Lege Action Group an bzw. aktualisiere sie..."
$ag = Invoke-AzQuiet $agArgs
if (-not $ag) {
    Write-Fail "Action Group fehlgeschlagen."
    Write-Sub "Ursache: $script:LastAzError"
    exit 1
}
$ActionGroupId = $ag.id
Write-Ok "Action Group bereit: $($ag.name)"
Write-Sub "Empfaenger aktiv: $(@($ag.emailReceivers).Count)"

# Status der Empfaenger pruefen. Azure deaktiviert Adressen nach Bounces oder
# Spam-Meldungen; die Regel feuert dann korrekt, es kommt nur nichts an.
$gesperrt = @($ag.emailReceivers | Where-Object { $_.status -and $_.status -ne "Enabled" })
if ($gesperrt.Count -gt 0) {
    Write-Host ""
    Write-Warn2 "$($gesperrt.Count) Empfaenger sind nicht auf 'Enabled':"
    foreach ($g in $gesperrt) {
        Write-Host ("    {0,-40} {1}" -f $g.emailAddress, $g.status) -ForegroundColor Red
    }
    Write-Sub "Azure stellt dorthin nicht zu. Im Portal reaktivieren."
}
Write-Line

# =============================================================================
#  STUFE 7 - ALERT-REGEL
# =============================================================================
Write-Head "STUFE 7 - ALERT-REGEL"

Write-Run "Lege Alert-Regel an..."

# Genau einen der beiden Parameter setzen - die API lehnt beide ab.
$modusArgs = switch ($NotificationMode) {
    "AutoResolve" { @("--auto-mitigate", "true") }
    "Suppress"    { @("--auto-mitigate", "false", "--mute-actions-duration", $MuteActionsDuration) }
    default       { $null }
}
if ($null -eq $modusArgs) {
    Write-Fail "`$NotificationMode = '$NotificationMode' ist unbekannt."
    Write-Sub "Erlaubt: 'AutoResolve' oder 'Suppress'."
    exit 1
}

# Custom Properties an einer Stelle definieren - sie werden sowohl bei der
# Anlage als auch im spaeteren PATCH gebraucht (siehe Korrektur 7).
$customProps = @{
    "Laufwerke"   = ($Drives -join ',')
    "Schwellwert" = "$ThresholdPercent"
}

$ruleArgs = @(
    "monitor", "scheduled-query", "create",
    "--name", $RuleName,
    "--resource-group", $AlertResourceGroup,
    "--scopes", $WorkspaceResourceId,
    "--location", $Location,
    "--description", $description,
    "--severity", "$Severity",
    "--evaluation-frequency", $EvaluationFrequency,
    "--window-size", $WindowSize,
    "--action-groups", $ActionGroupId,
    "--condition", $condition,
    "--condition-query", "Placeholder_1=$query",
    "--target-resource-type", "Microsoft.HybridCompute/machines",
    "--custom-properties", "Laufwerke=$($customProps['Laufwerke'])", "Schwellwert=$($customProps['Schwellwert'])",
    "-o", "json"
) + $modusArgs

$rule = Invoke-AzQuiet $ruleArgs

if (-not $rule) {
    Write-Fail "Anlage der Alert-Regel fehlgeschlagen."
    Write-Sub "Ursache: $script:LastAzError"
    exit 1
}
Write-Ok "Alert-Regel erstellt."

if ($RuleDisplayName -ne $RuleName) {
    Write-Run "Setze Anzeigenamen..."
    $upd = Invoke-AzQuiet @("resource", "update", "--ids", $rule.id,
                            "--set", "properties.displayName=$RuleDisplayName",
                            "--api-version", "2023-12-01", "-o", "json")
    if ($upd) { Write-Ok "Anzeigename gesetzt." }
    else      { Write-Warn2 "Anzeigename nicht gesetzt: $script:LastAzError" }
}

Write-Run "Setze dynamischen E-Mail-Betreff..."
$patched = Set-AlertEmailSubject -ActionGroupId $ActionGroupId `
                                 -Subject $EmailSubjectTemplate `
                                 -CustomProperties $customProps
if ($patched) {
    Write-Ok "Betreff gesetzt."
    Write-Sub $EmailSubjectTemplate
}
else {
    Write-Warn2 "Betreff nicht gesetzt: $script:LastAzError"
    Write-Sub "Die Regel funktioniert trotzdem - nur mit Standard-Betreff."
}

Write-Run "Pruefe den Endzustand der Regel..."
$check = Invoke-AzQuiet @("monitor", "scheduled-query", "show",
                          "--resource-group", $AlertResourceGroup,
                          "--name", $RuleName, "-o", "json")
if ($check) {
    if ($check.enabled -eq $true) { Write-Ok "enabled = true" }
    else { Write-Fail "Die Regel ist DEAKTIVIERT - sie wird nicht ausgewertet." }
    Write-Sub "provisioningState: $($check.provisioningState)"
    Write-Sub "actionGroups     : $(@($check.actions.actionGroups).Count)"
    if (@($check.actions.actionGroups).Count -eq 0) {
        Write-Fail "Der Regel ist keine Action Group zugeordnet - es kann keine Mail geben."
    }
}
else { Write-Warn2 "Endzustand nicht abrufbar: $script:LastAzError" }
Write-Line

# =============================================================================
#  ZUSAMMENFASSUNG
# =============================================================================
Write-Head "ZUSAMMENFASSUNG"
Write-Sub "Regel               : $RuleName"
Write-Sub "Workspace           : $WorkspaceName"
Write-Sub "Laufwerke           : $($Drives -join ', ')"
Write-Sub "Schwellwert         : < $ThresholdPercent % frei"
Write-Sub "Auswertung          : alle $EvaluationFrequency ueber $WindowSize"
Write-Sub "Ausloesung          : $MinFailingPeriods von $NumberOfEvalPeriods Perioden"
Write-Sub "Benachrichtigung    : $NotificationMode$(if ($NotificationMode -eq 'Suppress') { " ($MuteActionsDuration)" })"
Write-Sub "Splitting           : je Server UND Laufwerk eine eigene Alert-Instanz"
Write-Sub "Empfaenger          : $(@($EmailRecipients).Count)"
Write-Sub "Server-Ausnahmen    : $($alleServerAusnahmen.Count)"
Write-Sub "Laufwerks-Ausnahmen : $($alleDriveAusnahmen.Count)"
Write-Sub "Serien im Probelauf : $($serien.Count), davon unter Schwellwert: $($unterSchwelle.Count)"
Write-Host ""
Write-Info2 "Beispiel-Betreff im Alarmfall:"
Write-Sub "mxkkr8 D: - unter 15 % frei (Fired, 0.92 % frei)"
Write-Host ""

if ($NotificationMode -eq "AutoResolve") {
    Write-Warn2 "Stateful-Verhalten:"
    Write-Sub "Pro Instanz (Server + Laufwerk) geht genau EINE Mail raus. Solange der"
    Write-Sub "Alarm offen steht, kommt keine weitere - auch wenn der Platz weiter"
    Write-Sub "schrumpft. Erst nach der Aufloesung kann dieselbe Instanz erneut feuern."
    Write-Sub "Wer wiederkehrende Erinnerungen will, braucht `$NotificationMode = 'Suppress'"
    Write-Sub "mit `$MuteActionsDuration als Wiederholungsintervall."
    Write-Host ""
}

Write-Info2 "Dokumentierte Grenzwerte im Blick behalten:"
Write-Sub "Stateful-Regel: max. 300 Alarme JE AUSWERTUNG. Bei $(@($Drives).Count) Laufwerken"
Write-Sub "  und wachsendem Serverbestand kann ein Grossereignis das erreichen -"
Write-Sub "  Azure kappt dann still."
Write-Sub "E-Mail: max. 100 Mails pro Stunde JE ADRESSE und Region, und 100"
Write-Sub "  Benachrichtigungen alle 5 Minuten je Alert-Regel."
Write-Sub "Regel-Eigenschaften: aktuell ca. $([math]::Round($eigenschaftenGroesse/1024,1)) KB von 64 KB."
Write-Host ""
Write-Warn2 "Momentaufnahme:"
Write-Sub "Tag-Ausnahmen wurden JETZT aufgeloest und fest in die Query geschrieben."
Write-Sub "Neue Disk-Tags oder neue Server ohne Maschinen-Tags wirken erst nach"
Write-Sub "einem erneuten Lauf dieses Scripts."
Write-Host ""
Write-Info2 "Kontrolle:"
Write-Sub "az monitor scheduled-query show -g $AlertResourceGroup -n $RuleName --query actions"
Write-Sub ".\Test-ArcDiskSpaceAlert.ps1"
Write-Line
