#Requires -RunAsAdministrator
# Setup.ps1 - Executed via Azure Custom Script Extension
# Logs: C:\Windows\Temp\cse-setup.log

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

Write-Log "=== Setup2.ps1 started ==="
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

# ─── Step 3 - Set German Locale (System, User, DefaultUser, Keyboard) ─────────
Write-Log "Step 3: Configuring German locale (de-DE)..."
try {
    # System Locale (Non-Unicode-Apps)
    Set-WinSystemLocale -SystemLocale de-DE
    Write-Log "  SystemLocale set to de-DE"

    # UI-Sprache, Culture, Region
    Set-WinUILanguageOverride -Language de-DE
    Set-Culture -CultureInfo de-DE
    Set-WinHomeLocation -GeoId 0x5E   # Germany
    Write-Log "  UI language, culture and home location set"

    # Sprachliste: DE primär (DE-Tastatur), EN sekundär (EN-Tastatur)
    $LangList = New-WinUserLanguageList de-DE
    $LangList[0].InputMethodTips.Clear()
    $LangList[0].InputMethodTips.Add("0407:00000407")  # DE Tastatur
    $LangList.Add("en-US")
    $LangList[1].InputMethodTips.Clear()
    $LangList[1].InputMethodTips.Add("0409:00000409")  # EN Tastatur
    Set-WinUserLanguageList $LangList -Force
    Write-Log "  Language list and keyboard layouts set"

    # intl.cpl XML – kopiert Einstellungen auf DefaultUser- und System-Konto.
    # Namespace muss "urn:longhornGlobalizationUnattend" sein; w3.org wird
    # von intl.cpl stillschweigend ignoriert.
    # UTF-8 ohne BOM (WriteAllText), da intl.cpl mit BOM abbricht.
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
    <gs:MUIFallback Value="en-US"/>
  </gs:MUILanguagePreferences>
  <gs:SystemLocale Name="de-DE"/>
  <gs:InputPreferences>
    <gs:InputLanguageID Action="add" ID="0407:00000407" Default="true"/>
    <gs:InputLanguageID Action="add" ID="0409:00000409"/>
  </gs:InputPreferences>
  <gs:UserLocale>
    <gs:Locale Name="de-DE" SetAsCurrent="true" ResetAllSettings="true"/>
  </gs:UserLocale>
</gs:GlobalizationServices>
"@
    $xmlPath = "$env:TEMP\de-DE-intl.xml"
    [System.IO.File]::WriteAllText($xmlPath, $intlXml, [System.Text.UTF8Encoding]::new($false))

    $proc = Start-Process -FilePath "control.exe" `
        -ArgumentList "intl.cpl,,/f:`"$xmlPath`"" `
        -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Log "  intl.cpl returned exit code $($proc.ExitCode)" "WARN"
    } else {
        Write-Log "  intl.cpl XML applied (DefaultUser + System accounts)"
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

Write-Log "=== Setup2.ps1 completed successfully ==="
Write-Log "Rebooting in 20 seconds to apply locale changes..."
Start-Sleep -Seconds 20
Restart-Computer -Force
