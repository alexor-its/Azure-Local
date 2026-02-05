<#
.SYNOPSIS
Script set for a Windows Server all reginal settings to Germany DE-DE

.DESCRIPTION
The Script could use for EN-US Images like from the Azure Local Marketplace to switch the OS to german reginal settings.
It could be used via Arc VM/Server custom Script Extension through ARM Template or Az CLI

.AUTHOR
Alexander Ortha
AzureHybridInsider@ortha-solutions.de

.VERSION
1.0.0

.DATE
2026-02-05

.LICENSE
Dieses Skript wird ohne jegliche Garantie bereitgestellt.
Die Nutzung erfolgt auf eigenes Risiko. Der Autor übernimmt keinerlei
Haftung für Schäden, die direkt oder indirekt aus der Verwendung
dieses Skripts entstehen.

.NOTES
Getestet unter: Azure Local 2601, Windows Server 2025
#>

# === Beginn Skriptcode ===

# System Locale setzen (für Non-Unicode-Apps)
Set-WinSystemLocale -SystemLocale de-DE 

# User Locale (MUI, Formats, Währung)
Set-WinUILanguageOverride -Language de-DE
Set-WinUserLanguageList -LanguageList de-DE -Force
Set-Culture de-DE
Set-WinHomeLocation -GeoId 0x5E # Germany

# Keyboard Layouts (DE primär, EN sec)
$LangList = New-WinUserLanguageList de-DE
$LangList.Add("en-US")
Set-WinUserLanguageList $LangList -Force

# Intl. Einstellungen via XML (Time, Formats, Keyboard - kopiert zu DefaultUser/System)
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

# TimeZone (CET/CEST)
Set-TimeZone -Id "W. Europe Standard Time"

# Language Pack installieren (falls fehlt, z.B. für Client-Images)
# Install-Language de-DE 
# Oder: Add-WindowsPackage -Online -PackagePath (Pfad zu .cab)

Write-Output "Locale de-DE gesetzt. Reboot erforderlich."
Restart-Computer -Force
