#Requires -Version 5.1
<#
.SYNOPSIS
    Setup script executed via Azure Custom Script Extension on an HCI VM.
.DESCRIPTION
    Runs on the VM after deployment (and optionally after domain join).
    Adjust as needed.
    Called by CSE like:
        powershell -ExecutionPolicy Unrestricted -File Setup.ps1
.NOTES
    Logs: C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\
#>

param (
    [string]$InstallPath = "C:\Tools"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Logging helper ---
$LogFile = "C:\Windows\Temp\cse-setup-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

Write-Log "=== Setup.ps1 started ==="
Write-Log "Running as : $($env:USERDOMAIN)\$($env:USERNAME)"
Write-Log "Computer   : $($env:COMPUTERNAME)"

# --- 1. Bring offline disks online ---
Write-Log "Initialising offline disks..."
$offlineDisks = Get-Disk | Where-Object { $_.OperationalStatus -eq 'Offline' }
foreach ($disk in $offlineDisks) {
    Write-Log "  Disk $($disk.Number) ($([math]::Round($disk.Size / 1GB, 0)) GB) - bringing online"
    Set-Disk -Number $disk.Number -IsOffline $false
    Set-Disk -Number $disk.Number -IsReadOnly $false
}

# --- 2. Initialise RAW disks ---
$rawDisks = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' }
foreach ($disk in $rawDisks) {
    Write-Log "  Initialising RAW disk $($disk.Number)"
    $partition = Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru |
                 New-Partition -AssignDriveLetter -UseMaximumSize
    Format-Volume -DriveLetter $partition.DriveLetter `
                  -FileSystem NTFS `
                  -NewFileSystemLabel "DataDisk$($disk.Number)" `
                  -Confirm:$false | Out-Null
}
Write-Log "Disk initialisation complete."

# --- 3. Set Windows timezone ---
Write-Log "Setting timezone to W. Europe Standard Time..."
try {
    Set-TimeZone -Id "W. Europe Standard Time"
    Write-Log "Timezone set successfully."
} catch {
    Write-Log "Timezone change failed: $_" "WARN"
}

# --- 4. Enable WinRM ---
Write-Log "Enabling WinRM..."
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
Set-Item WSMan:\localhost\MaxEnvelopeSizekb -Value 8192
Write-Log "WinRM enabled."

# --- 5. Create install directory ---
Write-Log "Creating install path: $InstallPath"
if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}

# --- 6. Disable IE Enhanced Security ---
Write-Log "Disabling IE Enhanced Security Configuration..."
$AdminKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
$UserKey  = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
Set-ItemProperty -Path $AdminKey -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue
Set-ItemProperty -Path $UserKey  -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue
Write-Log "IE ESC disabled."

# --- 7. Custom application install placeholder ---
# Replace this section with your actual installation logic.
# Example:
#   Invoke-WebRequest -Uri "https://example.com/app.msi" -OutFile "$InstallPath\app.msi"
#   Start-Process msiexec.exe -ArgumentList "/i `"$InstallPath\app.msi`" /quiet /norestart" -Wait
Write-Log "Application setup placeholder - no action taken."

Write-Log "=== Setup.ps1 completed successfully ==="
