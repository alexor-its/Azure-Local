# Setup.ps1 - Executed via Azure Custom Script Extension
# Logs: C:\Windows\Temp\cse-setup-*.log

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

Write-Log "=== Setup.ps1 started ==="
Write-Log "User     : $($env:USERDOMAIN)\$($env:USERNAME)"
Write-Log "Computer : $($env:COMPUTERNAME)"

# 1 - Bring offline disks online
Write-Log "Step 1: Bringing offline disks online..."
$offlineDisks = Get-Disk | Where-Object { $_.OperationalStatus -eq "Offline" }
foreach ($d in $offlineDisks) {
    Write-Log "  Setting disk $($d.Number) online"
    Set-Disk -Number $d.Number -IsOffline $false
    Set-Disk -Number $d.Number -IsReadOnly $false
}
Write-Log "Step 1: Done."

# 2 - Initialise RAW disks
Write-Log "Step 2: Initialising RAW disks..."
$rawDisks = Get-Disk | Where-Object { $_.PartitionStyle -eq "RAW" }
foreach ($d in $rawDisks) {
    Write-Log "  Initialising disk $($d.Number)"
    Initialize-Disk -Number $d.Number -PartitionStyle GPT
    $part = New-Partition -DiskNumber $d.Number -AssignDriveLetter -UseMaximumSize
    Format-Volume -DriveLetter $part.DriveLetter -FileSystem NTFS -NewFileSystemLabel "DataDisk$($d.Number)" -Confirm:$false
}
Write-Log "Step 2: Done."

# 3 - System Locale setzen (für Non-Unicode-Apps)
Write-Log "Step 3: Setting System Locale"
Set-WinSystemLocale -SystemLocale de-DE 
Write-Log "Step 3: Done."

# 4 - User Locale (MUI, Formats, Währung)
Write-Log "Step 4: Setting User Locale"
Set-WinUILanguageOverride -Language de-DE
Set-WinUserLanguageList -LanguageList de-DE -Force
Set-Culture de-DE
Set-WinHomeLocation -GeoId 0x5E # Germany
Write-Log "Step 4: Done."

# 5- Keyboard Layouts (DE primär, EN sec)
Write-Log "Step 5: Setting Keyboard Layouts"
$LangList = New-WinUserLanguageList de-DE
$LangList.Add("en-US")
Set-WinUserLanguageList $LangList -Force
Write-Log "Step 5: Done."

# 6- Intl. Einstellungen via XML (Time, Formats, Keyboard - kopiert zu DefaultUser/System)
Write-Log "Step 6: Setting Intl. Einstellungen via XML"
$intl = @"
<?xml version="1.0" encoding="UTF-8"?>
<gs:GlobalizationServices xmlns:gs="http://www.w3.org/2001/XMLSchema">
  <sxs:Win32Locale>
    <locale>1041:00000407</locale>  <!-- de-DE, Keyboard DE -->
  </sxs:Win32Locale>
  <gs:UserList>
    <gs:User userSID="*" copySettingsToDefaultUserAcct="true" copySettingsToSystemAcct="true"/>
  </gs:UserList>
  <gs:InputPreferences>
    <gs:Keyboard enabled="1" id="00000407"/>  <!-- DE Keyboard -->
    <gs:Keyboard enabled="1" id="00000409"/>  <!-- EN Keyboard -->
  </gs:InputPreferences>
  <gs:MUILanguages>
    <gs:Language locale="de-DE" enabled="true"/>
  </gs:MUILanguages>
</gs:GlobalizationServices>
"@
$intl | Out-File -FilePath "$env:TEMP\de-DE.xml" -Encoding UTF8
control intl.cpl, /f:"$env:TEMP\de-DE.xml"  # Anwenden [web:24]
Write-Log "Step 6: Done."

# 7 - Set timezone
Write-Log "Step 7: Setting timezone..."
try {
    Set-TimeZone -Id "W. Europe Standard Time"
    Write-Log "Step 7: Done."
} catch {
    Write-Log "Step 7: Failed - $_" "WARN"
}

# 8 - Enable WinRM
Write-Log "Step 8: Enabling WinRM..."
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Item WSMan:\localhost\MaxEnvelopeSizekb -Value 8192
Write-Log "Step 8: Done."

# 9 - Create install directory
Write-Log "Step 9: Creating $InstallPath..."
if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force
}
Write-Log "Step 9: Done."

# 10 - Disable IE Enhanced Security
Write-Log "Step 10: Disabling IE ESC..."
$k1 = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
$k2 = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
Set-ItemProperty -Path $k1 -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue
Set-ItemProperty -Path $k2 -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue
Write-Log "Step 10: Done."

# 11 - Custom application placeholder
Write-Log "Step 11: Custom application placeholder - no action."
# Add your installation logic here, e.g.:
# Invoke-WebRequest -Uri "https://example.com/app.msi" -OutFile "$InstallPath\app.msi"
# Start-Process msiexec.exe -ArgumentList "/i `"$InstallPath\app.msi`" /quiet /norestart" -Wait
Write-Log "Step 11: Done."
    
Write-Log "=== Setup.ps1 completed successfully ==="
