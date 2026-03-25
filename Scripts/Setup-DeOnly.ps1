#Requires -RunAsAdministrator
# Setup2-DeOnly.ps1 - Executed via Azure Custom Script Extension
# Logs: C:\Windows\Temp\cse-setup.log
# Variante: GUI vollständig auf Deutsch, en-US wird entfernt

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

# ─── Step 3 - Set German Locale (nur de-DE, kein en-US) ──────────────────────
Write-Log "Step 3: Configuring German-only locale (de-DE)..."
try {
    # System Locale (Non-Unicode-Apps)
    Set-WinSystemLocale -SystemLocale de-DE
    Write-Log "  SystemLocale set to de-DE"

    # UI-Sprache, Culture, Region
    Set-WinUILanguageOverride -Language de-DE
    Set-Culture -CultureInfo de-DE
    Set-WinHomeLocation -GeoId 0x5E  # Germany
    Write-Log "  UI language, culture and home location set"

    # Sprachliste: NUR de-DE, en-US wird explizit entfernt.
    # New-WinUserLanguageList erzeugt eine leere Liste (kein Fallback auf
    # die bestehende Systemliste), Set-WinUserLanguageList -Force überschreibt
    # die vorhandene Liste vollständig.
    $LangList = New-WinUserLanguageList de-DE
    $LangList[0].InputMethodTips.Clear()
    $LangList[0].InputMethodTips.Add("0407:00000407")  # DE Tastatur
    Set-WinUserLanguageList $LangList -Force
    Write-Log "  Language list set to de-DE only (en-US removed)"

    # Registry: MUI-Fallback auf de-DE setzen, damit Windows-Komponenten
    # die keinen deutschen String haben, nicht auf en-US ausweichen.
    # (Optionaler Hardening-Schritt – schadet nicht wenn bereits korrekt.)
    $muiPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Nls\MUILanguages"
    if (Test-Path $muiPath) {
        Set-ItemProperty -Path $muiPath -Name "MachinePreferredUILanguages" -Value "de-DE" -ErrorAction SilentlyContinue
        Write-Log "  MUI machine preferred language set to de-DE"
    }

    # intl.cpl XML – überträgt alle Einstellungen auf DefaultUser- und
    # System-Konto. Kein en-US Fallback in MUILanguagePreferences.
    # UTF-8 ohne BOM, Namespace urn:longhornGlobalizationUnattend (Pflicht).
    $intlXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<gs:GlobalizationServices xmlns:gs="urn:longhornGlobalizationUnattend">
  <gs:UserList>
    <gs:User UserID="Current"
             CopySettingsToDefaultUserAcct="true"
             CopySettingsToSystemAcct="true"/>
  </gs:UserList>
  <gs:LocationPreferences>
    <gs:GeoID Value="94"/>
  </gs:LocationPreferences>
  <gs:MUILanguagePreferences>
    <gs:MUILanguage Value="de-DE"/>
  </gs:MUILanguagePreferences>
  <gs:SystemLocale Name="de-DE"/>
  <gs:InputPreferences>
    <gs:InputLanguageID Action="remove" ID="0409:00000409"/>
    <gs:InputLanguageID Action="add"    ID="0407:00000407" Default="true"/>
  </gs:InputPreferences>
  <gs:UserLocale>
    <gs:Locale Name="de-DE" SetAsCurrent="true" ResetAllSettings="true"/>
  </gs:UserLocale>
</gs:GlobalizationServices>
"@
    $xmlPath = "$env:TEMP\de-DE-only-intl.xml"
    [System.IO.File]::WriteAllText($xmlPath, $intlXml, [System.Text.UTF8Encoding]::new($false))

    $proc = Start-Process -FilePath "control.exe" `
        -ArgumentList "intl.cpl,,/f:`"$xmlPath`"" `
        -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Log "  intl.cpl returned exit code $($proc.ExitCode)" "WARN"
    } else {
        Write-Log "  intl.cpl XML applied (DefaultUser + System accounts, en-US removed)"
    }

    # Language Pack: en-US entfernen falls vorhanden (Windows 10/11 / Server 2022+)
    # Auf Server-Core-Images ist Uninstall-Language u.U. nicht verfügbar – daher try/catch.
    try {
        $enPack = Get-InstalledLanguage -Language "en-US" -ErrorAction SilentlyContinue
        if ($enPack) {
            Uninstall-Language -Language "en-US" -ErrorAction Stop
            Write-Log "  Language pack en-US uninstalled"
        } else {
            Write-Log "  Language pack en-US not present, skipping uninstall"
        }
    } catch {
        Write-Log "  Uninstall-Language not available or failed (non-critical): $_" "WARN"
    }

    Write-Log "Step 3: Done."
} catch {
    Write-Log "Step 3: Failed - $_" "WARN"
}

# ─── Step 4 - Set timezone ────────────────────────────────────────────────────
Write-Log "Step 4: Setting timezone..."
try {
    Set-TimeZone -Id "W. Europe Standard Time"
    Write-Log "Step 4: Done."
} catch {
    Write-Log "Step 4: Failed - $_" "WARN"
}

# ─── Step 5 - Enable WinRM ────────────────────────────────────────────────────
Write-Log "Step 5: Enabling WinRM..."
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Item WSMan:\localhost\MaxEnvelopeSizekb -Value 8192
Write-Log "Step 5: Done."

# ─── Step 6 - Create install directory ───────────────────────────────────────
Write-Log "Step 6: Creating $InstallPath..."
if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force
}
Write-Log "Step 6: Done."

# ─── Step 7 - Disable IE Enhanced Security ───────────────────────────────────
Write-Log "Step 7: Disabling IE ESC..."
$k1 = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
$k2 = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
Set-ItemProperty -Path $k1 -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue
Set-ItemProperty -Path $k2 -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue
Write-Log "Step 7: Done."

# ─── Step 8 - Custom application placeholder ─────────────────────────────────
Write-Log "Step 8: Custom application placeholder - no action."
# Add your installation logic here, e.g.:
# Invoke-WebRequest -Uri "https://example.com/app.msi" -OutFile "$InstallPath\app.msi"
# Start-Process msiexec.exe -ArgumentList "/i `"$InstallPath\app.msi`" /quiet /norestart" -Wait

Write-Log "=== Setup2-DeOnly.ps1 completed successfully ==="
Write-Log "Rebooting in 10 seconds to apply locale changes..."
Start-Sleep -Seconds 10
Restart-Computer -Force
