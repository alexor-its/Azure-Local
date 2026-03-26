#Requires -RunAsAdministrator
# Setup2-DeOnly.ps1 - Executed via Azure Custom Script Extension
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

Write-Log "=== Setup2-DeOnly.ps1 started ==="
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

# Step 3 - Install de-DE Language Pack
# Must run BEFORE locale steps. Azure WS2025 images ship en-US only.
Write-Log "Step 3: Installing de-DE language pack..."
try {
    $installed = Get-InstalledLanguage | Where-Object { $_.LanguageId -eq "de-DE" }
    if ($installed) {
        Write-Log "  de-DE already installed, skipping."
    } else {
        Write-Log "  Downloading de-DE from Windows Update..."
        Install-Language -Language de-DE -ErrorAction Stop
        Write-Log "  de-DE language pack installed."
    }
    Write-Log "Step 3: Done."
} catch {
    Write-Log "Step 3: Failed - $_" "ERROR"
    throw
}

# Step 4 - Locale via Registry (safe for SYSTEM context)
#
# Set-WinUILanguageOverride / Set-WinUserLanguageList only write to the
# calling user hive (SYSTEM here). After reboot the real login user has
# their own untouched hive -> GUI stays English.
# Fix: write directly into HKLM (system-wide), DefaultUser hive and all
# existing profile hives using reg.exe load.
#
Write-Log "Step 4: Configuring de-DE locale via registry..."
try {

    # Helper: write all locale values into a mounted hive
    function Set-LocaleInHive {
        param([string]$HiveRoot, [string]$Label)

        # MUI / UI language
        $desktop = "$HiveRoot\Control Panel\Desktop"
        $null = New-Item -Path $desktop -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $desktop -Name "PreferredUILanguages"        -Value ([string[]]@("de-DE")) -Type MultiString
        Set-ItemProperty -Path $desktop -Name "PreferredUILanguagesPending" -Value ([string[]]@("de-DE")) -Type MultiString
        Set-ItemProperty -Path $desktop -Name "MultiUILanguageId"           -Value "00000407"

        $muiCached = "$HiveRoot\Control Panel\Desktop\MuiCached"
        $null = New-Item -Path $muiCached -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $muiCached -Name "MachinePreferredUILanguages" -Value ([string[]]@("de-DE")) -Type MultiString

        # Locale / formats
        $intl = "$HiveRoot\Control Panel\International"
        $null = New-Item -Path $intl -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $intl -Name "Locale"      -Value "00000407"           -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $intl -Name "LocaleName"  -Value "de-DE"              -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $intl -Name "sLanguage"   -Value "DEU"                -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $intl -Name "sCountry"    -Value "Deutschland"        -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $intl -Name "iCountry"    -Value "49"                 -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $intl -Name "sCurrency"   -Value "EUR"                -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $intl -Name "sThousand"   -Value "."                  -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $intl -Name "sDecimal"    -Value ","                  -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $intl -Name "sDate"       -Value "."                  -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $intl -Name "iDate"       -Value "1"                  -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $intl -Name "sShortDate"  -Value "dd.MM.yyyy"         -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $intl -Name "sLongDate"   -Value "dddd, d. MMMM yyyy" -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $intl -Name "sTimeFormat" -Value "HH:mm:ss"           -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $intl -Name "s1159"       -Value ""                   -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $intl -Name "s2359"       -Value ""                   -ErrorAction SilentlyContinue

        # GeoID - Germany = 94 decimal (0x5E)
        # Must be set in registry directly; Set-WinHomeLocation only affects
        # the current user context and does not work under SYSTEM.
        $geoPath = "$HiveRoot\Control Panel\International\Geo"
        $null = New-Item -Path $geoPath -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $geoPath -Name "Nation"  -Value "94"  -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $geoPath -Name "Name"    -Value "DE"  -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $geoPath -Name "Nation2" -Value "276" -ErrorAction SilentlyContinue

        # Keyboard: DE only (00000407), remove EN completely.
        # Preload:     which layouts are loaded
        # Substitutes: remapping entries (often 00000409 -> en-US), must be cleared
        # Toggle:      hotkey to switch layouts, remove since only one layout remains
        $kbBase = "$HiveRoot\Keyboard Layout"
        $null = New-Item -Path "$kbBase\Preload"     -Force -ErrorAction SilentlyContinue
        $null = New-Item -Path "$kbBase\Substitutes" -Force -ErrorAction SilentlyContinue

        # Clear all existing preload entries then set DE only
        $preloadItem = Get-Item -Path "$kbBase\Preload" -ErrorAction SilentlyContinue
        if ($preloadItem) {
            $preloadItem.Property | ForEach-Object {
                Remove-ItemProperty -Path "$kbBase\Preload" -Name $_ -ErrorAction SilentlyContinue
            }
        }
        Set-ItemProperty -Path "$kbBase\Preload" -Name "1" -Value "00000407"

        # Clear substitutes (removes en-US 00000409 mappings)
        $subsItem = Get-Item -Path "$kbBase\Substitutes" -ErrorAction SilentlyContinue
        if ($subsItem) {
            $subsItem.Property | ForEach-Object {
                Remove-ItemProperty -Path "$kbBase\Substitutes" -Name $_ -ErrorAction SilentlyContinue
            }
        }

        # Remove toggle key config (not needed with single layout)
        Remove-Item -Path "$kbBase\Toggle" -Recurse -Force -ErrorAction SilentlyContinue

        Write-Log "  [$Label] UI language, locale, GeoID=94 (DE), keyboard=DE only"
    }

    # 4a: HKLM system-wide (login screen, non-unicode apps)
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

    # Login screen keyboard: DE only
    $null = New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout\Preload" -Force -ErrorAction SilentlyContinue
    $kbHklm = Get-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout\Preload" -ErrorAction SilentlyContinue
    if ($kbHklm) {
        $kbHklm.Property | ForEach-Object {
            Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout\Preload" -Name $_ -ErrorAction SilentlyContinue
        }
    }
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout\Preload" -Name "1" -Value "00000407"
    Write-Log "  [HKLM] Keyboard Preload = 00000407 (de-DE)"

    # 4b: SYSTEM profile hive (used by LogonUI.exe to render the lock screen date/time)
    # This hive has no Control Panel\International by default -> LogonUI falls back to en-US.
    $systemHive    = "C:\Windows\system32\config\systemprofile\NTUSER.DAT"
    $systemMountKey = "HKLM\TEMP_SYSTEMPROFILE"
    if (Test-Path $systemHive) {
        Write-Log "  Loading SYSTEM profile hive (LogonUI locale)..."
        $rls = & reg.exe load $systemMountKey $systemHive 2>&1
        if ($LASTEXITCODE -eq 0) {
            try {
                Set-LocaleInHive -HiveRoot "HKLM:\TEMP_SYSTEMPROFILE" -Label "SYSTEM-Profile"
            } finally {
                [GC]::Collect()
                Start-Sleep -Seconds 2
                $rus = & reg.exe unload $systemMountKey 2>&1
                if ($LASTEXITCODE -ne 0) { Write-Log "  reg unload SYSTEM profile warning: $rus" "WARN" }
                else { Write-Log "  SYSTEM profile hive unloaded" }
            }
        } else {
            Write-Log "  Could not load SYSTEM profile hive: $rls" "WARN"
        }
    }

    # 4c: DefaultUser hive (all future new users)
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

    # 4d: Existing user profiles (e.g. local admin)
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

    # 4e: Uninstall en-US language pack
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

Write-Log "=== Setup2-DeOnly.ps1 completed successfully ==="
Write-Log "Rebooting in 10 seconds to apply locale changes..."
Start-Sleep -Seconds 10
Restart-Computer -Force
