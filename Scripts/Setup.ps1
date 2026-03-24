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

# 3 - Set timezone
Write-Log "Step 3: Setting timezone..."
try {
    Set-TimeZone -Id "W. Europe Standard Time"
    Write-Log "Step 3: Done."
} catch {
    Write-Log "Step 3: Failed - $_" "WARN"
}

# 4 - Enable WinRM
Write-Log "Step 4: Enabling WinRM..."
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Item WSMan:\localhost\MaxEnvelopeSizekb -Value 8192
Write-Log "Step 4: Done."

# 5 - Create install directory
Write-Log "Step 5: Creating $InstallPath..."
if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force
}
Write-Log "Step 5: Done."

# 6 - Disable IE Enhanced Security
Write-Log "Step 6: Disabling IE ESC..."
$k1 = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
$k2 = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
Set-ItemProperty -Path $k1 -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue
Set-ItemProperty -Path $k2 -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue
Write-Log "Step 6: Done."

# 7 - Custom application placeholder
Write-Log "Step 7: Custom application placeholder - no action."
# Add your installation logic here, e.g.:
# Invoke-WebRequest -Uri "https://example.com/app.msi" -OutFile "$InstallPath\app.msi"
# Start-Process msiexec.exe -ArgumentList "/i `"$InstallPath\app.msi`" /quiet /norestart" -Wait

Write-Log "=== Setup.ps1 completed successfully ==="
