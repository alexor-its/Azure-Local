#Requires -RunAsAdministrator
# Setup2-DeOnly.ps1 - Executed via Azure Custom Script Extension
# Logs: C:\Windows\Temp\cse-setup.log
# Variante: GUI vollständig auf Deutsch, en-US wird entfernt
#
# WICHTIG: Registry-basierter Ansatz, da Script im SYSTEM-Kontext läuft.
# Set-WinUILanguageOverride etc. wirken nur auf den aktuellen User (SYSTEM),
# nicht auf spätere Login-User. Daher werden DefaultUser-Hive und alle
# vorhandenen Profile-Hives direkt per reg.exe load beschrieben.

param (
    [string]$InstallPath = "C:\Tools"
)

$ErrorActionPreference = "Stop"

$LogFile = "C:\Windows\Temp\cse-setup.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

Write-Log "=== Setup2-DeOnly.ps1 started ==="
Write-Log "User     : $($env:USERDOMAIN)\$($env:USERNAME)"
Write-Log "Computer : $($env:COMPUTERNAME)"

# ─── Step 1 - Bring offline disks online ─────────────────────────────────────
Write-Log "Step 1: Bringing offline disks online..."
$offlineDisks = Get-Disk | Where-Object { $_.OperationalStatus -eq "Offline" }
foreach ($d in $offlineDisks) {
    Write-Log "  Setting disk $($d.Number) online"
    Set-Disk -Number $d.Number -IsOffline $false
    Set-Disk -Number $d.Number -IsReadOnly $false
}
Write-Log "Step 1: Done."

# ─── Step 2 - Initialise RAW disks ───────────────────────────────────────────
Write-Log "Step 2: Initialising RAW disks..."
$rawDisks = Get-Disk | Where-Object { $_.PartitionStyle -eq "RAW" }
foreach ($d in $rawDisks) {
    Write-Log "  Initialising disk $($d.Number)"
    Initialize-Disk -Number $d.Number -PartitionStyle GPT
    $part = New-Partition -DiskNumber $d.Number -AssignDriveLetter -UseMaximumSize
    Format-Volume -DriveLetter $part.DriveLetter -FileSystem NTFS -NewFileSystemLabel "DataDisk$($d.Number)" -Confirm:$false
}
Write-Log "Step 2: Done."

# ─── Step 3 - Install de-DE Language Pack (MUI) ──────────────────────────────
# Muss VOR allen Locale-Steps laufen. Azure WS2025-Images liefern nur en-US.
# Ohne installiertes MUI-Pack zeigt die GUI weiterhin Englisch.
Write-Log "Step 3: Installing de-DE language pack..."
try {
    $installed = Get-InstalledLanguage | Where-Object { $_.LanguageId -eq "de-DE" }
    if ($installed) {
        Write-Log "  de-DE language pack already installed, skipping."
    } else {
        Write-Log "  Downloading and installing de-DE from Windows Update..."
        Install-Language -Language de-DE -CopyCulture -ErrorAction Stop
        Write-Log "  de-DE language pack installed successfully."
    }
    Write-Log "Step 3: Done."
} catch {
    Write-Log "Step 3: Failed - $_" "ERROR"
    throw  # Abbruch – ohne Language Pack bringen alle weiteren Schritte nichts
}

# ─── Step 4 - Locale via Registry (SYSTEM-Kontext-sicher) ────────────────────
Write-Log "Step 4: Configuring German-only locale via registry..."
try {

    # ── Hilfsfunktion: Locale-Werte in einen geladenen Hive schreiben ─────────
    function Set-LocaleInHive {
        param([string]$HiveRoot, [string]$Label)

        # UI-Sprache (MUI)
        $desktop = "$HiveRoot\Control Panel\Desktop"
        $null = New-Item -Path $desktop -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $desktop -Name "PreferredUILanguages"        -Value ([string[]]@("de-DE")) -Type MultiString
        Set-ItemProperty -Path $desktop -Name "PreferredUILanguagesPending" -Value ([string[]]@("de-DE")) -Type MultiString
        Set-ItemProperty -Path $desktop -Name "MultiUILanguageId"           -Value "00000407"

        # MUI-Cache
        $muiCached = "$HiveRoot\Control Panel\Desktop\MuiCached"
        $null = New-Item -Path $muiCached -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $muiCached -Name "MachinePreferredUILanguages" -Value ([string[]]@("de-DE")) -Type MultiString

        # Locale / Formate
        $intl = "$HiveRoot\Control Panel\International"
        $null = New-Item -Path $intl -Force -ErrorAction SilentlyContinue
        @{
            Locale      = "00000407"
            LocaleName  = "de-DE"
            sLanguage   = "DEU"
            sCountry    = "Deutschland"
            iCountry    = "49"
            sCurrency   = "€"
            sThousand   = "."
            sDecimal    = ","
            sDate       = "."
            iDate       = "1"
            sShortDate  = "dd.MM.yyyy"
            sLongDate   = "dddd, d. MMMM yyyy"
            sTimeFormat = "HH:mm:ss"
            s1159       = ""
            s2359       = ""
        }.GetEnumerator() | ForEach-Object {
            Set-ItemProperty -Path $intl -Name $_.Key -Value $_.Value -ErrorAction SilentlyContinue
        }

        # Tastatur: nur DE (00000407), EN-Einträge entfernen
        $kbPreload = "$HiveRoot\Keyboard Layout\Preload"
        $null = New-Item -Path $kbPreload -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $kbPreload -Name "1" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $kbPreload -Name "2" -ErrorAction SilentlyContinue
        Set-ItemProperty    -Path $kbPreload -Name "1" -Value "00000407"

        Write-Log "  [$Label] UI language, locale, keyboard written"
    }

    # ── 4a: HKLM – systemweite Einstellungen (Login-Screen, Non-Unicode) ──────

    Set-WinSystemLocale -SystemLocale de-DE
    Write-Log "  [HKLM] SystemLocale = de-DE"

    $null = New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\MUI\Settings" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\MUI\Settings" `
        -Name "PreferredUILanguages" -Value ([string[]]@("de-DE")) -Type MultiString
    Write-Log "  [HKLM] MUI PreferredUILanguages = de-DE"

    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language" `
        -Name "Default"         -Value "0407"
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language" `
        -Name "InstallLanguage" -Value "0407"
    Write-Log "  [HKLM] NLS Language = 0407 (de-DE)"

    # Login-Screen Tastatur: nur DE
    $null = New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout\Preload" -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout\Preload" -Name "1" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout\Preload" -Name "2" -ErrorAction SilentlyContinue
    Set-ItemProperty    -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout\Preload" -Name "1" -Value "00000407"
    Write-Log "  [HKLM] Keyboard Preload = 00000407 (de-DE)"

    # ── 4b: DefaultUser-Hive (alle künftigen neuen User) ──────────────────────
    $defaultHive = "C:\Users\Default\NTUSER.DAT"
    $mountKey    = "HKLM\TEMP_DEFAULT"

    Write-Log "  Loading DefaultUser hive..."
    $rl = & reg.exe load $mountKey $defaultHive 2>&1
    if ($LASTEXITCODE -ne 0) { throw "reg load DefaultUser failed: $rl" }

    try {
        Set-LocaleInHive -HiveRoot "HKLM:\TEMP_DEFAULT" -Label "DefaultUser"
    } finally {
        [GC]::Collect()
        Start-Sleep -Seconds 2
        $ru = & reg.exe unload $mountKey 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Log "  reg unload DefaultUser warning: $ru" "WARN" }
        else { Write-Log "  DefaultUser hive unloaded" }
    }

    # ── 4c: Vorhandene User-Profile (z.B. lokaler Admin) ──────────────────────
    $profileList = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" |
        ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
        Where-Object {
            $_.ProfileImagePath -and
            (Test-Path "$($_.ProfileImagePath)\NTUSER.DAT") -and
            $_.ProfileImagePath -notmatch "systemprofile|LocalService|NetworkService"
        }

    foreach ($prof in $profileList) {
        $profilePath  = $prof.ProfileImagePath
        $hivePath     = "$profilePath\NTUSER.DAT"
        $safeName     = $prof.PSChildName -replace '[^a-zA-Z0-9]', '_'
        $mountPoint   = "HKLM\TEMP_USER_$safeName"
        $mountPointPS = "HKLM:\TEMP_USER_$safeName"
        $label        = Split-Path $profilePath -Leaf

        Write-Log "  Loading profile hive: $label"
        $rl2 = & reg.exe load $mountPoint $hivePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  Cannot load hive for $label (user may be logged in): $rl2" "WARN"
            continue
        }

        try {
            Set-LocaleInHive -HiveRoot $mountPointPS -Label $label
        } finally {
            [GC]::Collect()
            Start-Sleep -Seconds 2
            $ru2 = & reg.exe unload $mountPoint 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Log "  reg unload warning ($label): $ru2" "WARN" }
        }
    }

    # ── 4d: en-US Language Pack deinstallieren ────────────────────────────────
    try {
        $enPack = Get-InstalledLanguage | Where-Object { $_.LanguageId -eq "en-US" }
        if ($enPack) {
            Uninstall-Language -Language "en-US" -ErrorAction Stop
            Write-Log "  Language pack en-US uninstalled"
        } else {
            Write-Log "  Language pack en-US not present, skipping"
        }
    } catch {
        Write-Log "  en-US uninstall failed (non-critical, may be base language): $_" "WARN"
    }

    Write-Log "Step 4: Done."
} catch {
    Write-Log "Step 4: Failed - $_" "ERROR"
}

# ─── Step 5 - Set timezone ────────────────────────────────────────────────────
Write-Log "Step 5: Setting timezone..."
try {
    Set-TimeZone -Id "W. Europe Standard Time"
    Write-Log "Step 5: Done."
} catch {
    Write-Log "Step 5: Failed - $_" "WARN"
}

# ─── Step 6 - Enable WinRM ────────────────────────────────────────────────────
Write-Log "Step 6: Enabling WinRM..."
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Item WSMan:\localhost\MaxEnvelopeSizekb -Value 8192
Write-Log "Step 6: Done."

# ─── Step 7 - Create install directory ───────────────────────────────────────
Write-Log "Step 7: Creating $InstallPath..."
if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force
}
Write-Log "Step 7: Done."

# ─── Step 8 - Disable IE Enhanced Security ───────────────────────────────────
Write-Log "Step 8: Disabling IE ESC..."
$k1 = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
$k2 = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
Set-ItemProperty -Path $k1 -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue
Set-ItemProperty -Path $k2 -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue
Write-Log "Step 8: Done."

# ─── Step 9 - Custom application placeholder ─────────────────────────────────
Write-Log "Step 9: Custom application placeholder - no action."
# Add your installation logic here, e.g.:
# Invoke-WebRequest -Uri "https://example.com/app.msi" -OutFile "$InstallPath\app.msi"
# Start-Process msiexec.exe -ArgumentList "/i `"$InstallPath\app.msi`" /quiet /norestart" -Wait

Write-Log "=== Setup2-DeOnly.ps1 completed successfully ==="
Write-Log "Rebooting in 10 seconds to apply locale changes..."
Start-Sleep -Seconds 10
Restart-Computer -Force
