# ======================================================================================
# Script      : Setup-DeOnly-AVD.ps1
# Description : Configure a en-US deployed Windows 11 Multi-Session AVD host
#               with German UI, locale, keyboard and region.
#               Executed via Azure Arc/VM Custom Script Extension.
#               Requires -RunAsAdministrator
#               Logs: C:\Windows\Temp\cse-setup.log
# --------------------------------------------------------------------------------------
# Author      : Alexander Ortha
# Company     : Alexander Ortha IT Solutions
# Contact     : https://ortha-itsolutions.de/
# Created     : 2026-03-30
# Version     : 1.1.0
# Based on    : Setup-DeOnly.ps1 v1.0.0
# --------------------------------------------------------------------------------------
# Differences vs Setup-DeOnly.ps1 (Windows Server 2025):
#   - Install-Language is NOT used. Microsoft requires DISM + FOD packages
#     for Windows 11 Enterprise Multi-Session pooled host pools.
#   - Language Pack CAB + FOD capabilities installed via DISM /Online /Add-Package
#     and DISM /Online /Add-Capability WITHOUT /LimitAccess - packages are pulled
#     directly from Windows Update, no ISO or file share required.
#   - Scheduled tasks for LXP auto-cleanup disabled to prevent Windows
#     from silently removing the language pack after reboot.
#   - intl.cpl + CopySettingsToSystemAcct for DefaultUser + lock screen.
# ======================================================================================

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

Write-Log "=== Setup-DeOnly-AVD.ps1 started ==="
Write-Log "User     : $($env:USERDOMAIN)\$($env:USERNAME)"
Write-Log "Computer : $($env:COMPUTERNAME)"

# Step 1 - Bring offline disks online
Write-Log "Step 1: Bringing offline disks online..."
$offlineDisks = Get-Disk | Where-Object { $_.OperationalStatus -eq "Offline" }
foreach ($d in $offlineDisks) {
    Write-Log "  Setting disk $($d.Number) online"
    Set-Disk -Number $d.Number -IsOffline $false
    Set-Disk -Number $d.Number -IsReadOnly $false
}
Write-Log "Step 1: Done."

# Step 2 - Initialise RAW disks
Write-Log "Step 2: Initialising RAW disks..."
$rawDisks = Get-Disk | Where-Object { $_.PartitionStyle -eq "RAW" }
foreach ($d in $rawDisks) {
    Write-Log "  Initialising disk $($d.Number)"
    Initialize-Disk -Number $d.Number -PartitionStyle GPT
    $part = New-Partition -DiskNumber $d.Number -AssignDriveLetter -UseMaximumSize
    Format-Volume -DriveLetter $part.DriveLetter -FileSystem NTFS -NewFileSystemLabel "DataDisk$($d.Number)" -Confirm:$false
}
Write-Log "Step 2: Done."

# Step 3 - Install de-DE language pack + FOD capabilities via DISM from Windows Update
# DISM /Add-Capability without /LimitAccess pulls packages directly from Windows Update.
# This is the recommended approach for AVD Multi-Session when no ISO/file share is available.
# Note: Install-Language is not officially supported for pooled Multi-Session host pools.
Write-Log "Step 3: Installing de-DE language pack and FOD capabilities via DISM..."
try {

    # Step 3a - Disable LXP cleanup scheduled tasks BEFORE installing.
    # Windows silently removes language packs it considers "unused" after reboot.
    Write-Log "  Disabling LXP cleanup scheduled tasks..."
    Disable-ScheduledTask -TaskPath "\Microsoft\Windows\AppxDeploymentClient\" -TaskName "Pre-staged app cleanup" -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskPath "\Microsoft\Windows\MUI\"                   -TaskName "LPRemove"              -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskPath "\Microsoft\Windows\LanguageComponentsInstaller" -TaskName "Uninstallation"   -ErrorAction SilentlyContinue
    reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Control Panel\International" /v "BlockCleanupOfUnusedPreinstalledLangPacks" /t REG_DWORD /d 1 /f 2>&1 | Out-Null
    Write-Log "  LXP cleanup tasks disabled."

    # Step 3b - Install Language Pack CAB via DISM from Windows Update
    # DISM contacts Windows Update directly when no /Source is specified.
    Write-Log "  Installing Language Pack de-de via DISM (Windows Update)..."
    $result = & dism.exe /Online /Add-Capability /CapabilityName:"Language.Basic~~~de-de~0.0.1.0" /NoRestart 2>&1
    Write-Log "  DISM Language.Basic exit code: $LASTEXITCODE"
    if ($LASTEXITCODE -notin @(0, 3010)) {
        Write-Log "  DISM output: $($result -join ' ')" "WARN"
    }

    # Step 3c - Install remaining FOD capabilities from Windows Update
    # Basic must be installed first (dependency for all others).
    $capabilities = @(
        "Language.Handwriting~~~de-de~0.0.1.0",
        "Language.OCR~~~de-de~0.0.1.0",
        "Language.Speech~~~de-de~0.0.1.0",
        "Language.TextToSpeech~~~de-de~0.0.1.0"
    )
    foreach ($cap in $capabilities) {
        Write-Log "  Installing capability: $cap"
        $result = & dism.exe /Online /Add-Capability /CapabilityName:"$cap" /NoRestart 2>&1
        Write-Log "  DISM $cap exit code: $LASTEXITCODE"
        if ($LASTEXITCODE -notin @(0, 3010)) {
            Write-Log "  DISM output: $($result -join ' ')" "WARN"
        }
    }

    Write-Log "Step 3: Done."
} catch {
    Write-Log "Step 3: Failed - $_" "ERROR"
    throw
}

# Step 4 - Configure de-DE locale, UI language, keyboard and region
# intl.cpl with CopySettingsToDefaultUserAcct + CopySettingsToSystemAcct
# propagates settings to DefaultUser profile and SYSTEM account (LogonUI/lock screen).
Write-Log "Step 4: Configuring de-DE locale..."
try {
    Set-WinSystemLocale -SystemLocale de-DE
    Write-Log "  SystemLocale = de-DE"

    Set-WinUILanguageOverride -Language de-DE
    Write-Log "  UILanguageOverride = de-DE"

    Set-Culture -CultureInfo de-DE
    Set-WinHomeLocation -GeoId 0x5E
    Write-Log "  Culture = de-DE, GeoId = 0x5E (Germany)"

    # Language list: de-DE only, DE keyboard only, no en-US
    $LangList = New-WinUserLanguageList de-DE
    $LangList[0].InputMethodTips.Clear()
    $LangList[0].InputMethodTips.Add("0407:00000407")
    Set-WinUserLanguageList $LangList -Force
    Write-Log "  Language list = de-DE only, keyboard = 00000407 (DE)"

    # intl.cpl XML - applies to DefaultUser + SYSTEM account (lock screen)
    # UTF-8 without BOM required (intl.cpl rejects BOM)
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
    $xmlPath = "$env:TEMP\de-DE-intl.xml"
    [System.IO.File]::WriteAllText($xmlPath, $intlXml, [System.Text.UTF8Encoding]::new($false))

    $proc = Start-Process -FilePath "control.exe" `
        -ArgumentList "intl.cpl,,/f:`"$xmlPath`"" `
        -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Log "  intl.cpl exited with code $($proc.ExitCode)" "WARN"
    } else {
        Write-Log "  intl.cpl applied (DefaultUser + SYSTEM account updated)"
    }

    # Remove en-US language pack to prevent Windows re-adding EN keyboard on login
    try {
        $enPack = Get-InstalledLanguage | Where-Object { $_.LanguageId -eq "en-US" }
        if ($enPack) {
            Uninstall-Language -Language "en-US" -ErrorAction Stop
            Write-Log "  en-US language pack removed"
        } else {
            Write-Log "  en-US language pack not present, skipping"
        }
    } catch {
        Write-Log "  en-US removal failed (non-critical): $_" "WARN"
    }

    Write-Log "Step 4: Done."
} catch {
    Write-Log "Step 4: Failed - $_" "WARN"
}

# Step 5 - Set timezone
Write-Log "Step 5: Setting timezone..."
try {
    Set-TimeZone -Id "W. Europe Standard Time"
    Write-Log "Step 5: Done."
} catch {
    Write-Log "Step 5: Failed - $_" "WARN"
}

# Step 6 - Enable WinRM
Write-Log "Step 6: Enabling WinRM..."
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Item WSMan:\localhost\MaxEnvelopeSizekb -Value 8192
Write-Log "Step 6: Done."

# Step 7 - Create install directory
Write-Log "Step 7: Creating $InstallPath..."
if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force
}
Write-Log "Step 7: Done."

# Step 8 - Disable IE Enhanced Security
Write-Log "Step 8: Disabling IE ESC..."
$k1 = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
$k2 = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
Set-ItemProperty -Path $k1 -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue
Set-ItemProperty -Path $k2 -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue
Write-Log "Step 8: Done."

# Step 9 - Custom application placeholder
Write-Log "Step 9: Custom application placeholder - no action."
# Add your installation logic here, e.g.:
# Invoke-WebRequest -Uri "https://example.com/app.msi" -OutFile "$InstallPath\app.msi"
# Start-Process msiexec.exe -ArgumentList "/i `"$InstallPath\app.msi`" /quiet /norestart" -Wait

Write-Log "=== Setup-DeOnly-AVD.ps1 completed successfully ==="
Write-Log "Rebooting in 20 seconds to apply locale changes..."
Start-Sleep -Seconds 20
Restart-Computer -Force
