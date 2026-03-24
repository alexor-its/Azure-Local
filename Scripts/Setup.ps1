<#
.SYNOPSIS
    Example setup script executed via the Azure Custom Script Extension on an HCI VM.

.DESCRIPTION
    This script runs on the VM after deployment (and optionally after domain join).
    Adjust it freely – it is just a starting point.

    Execution policy on the VM must allow the script to run.
    The CSE handler calls it like:
        powershell -ExecutionPolicy Unrestricted -File Setup.ps1

.NOTES
    Logs are written to C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\
    and also to C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\
    You can inspect these in the Azure Portal under the VM deployment details.
#>

param (
    # Optional parameters can be passed via -commandToExecute in the template
    [string]$InstallPath = "C:\Tools"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Logging helper ────────────────────────────────────────────────────────────
$LogFile = "C:\Windows\Temp\cse-setup-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

Write-Log "=== Custom Script Extension – Setup.ps1 started ==="
Write-Log "Running as: $($env:USERDOMAIN)\$($env:USERNAME)"
Write-Log "Computer  : $($env:COMPUTERNAME)"

# ── 1. Initialise and online-all data disks ───────────────────────────────────
Write-Log "Initialising offline disks …"
$offlineDisks = Get-Disk | Where-Object { $_.OperationalStatus -eq 'Offline' }
foreach ($disk in $offlineDisks) {
    Write-Log "  Disk $($disk.Number) ($($disk.Size / 1GB) GB) – bringing online"
    Set-Disk -Number $disk.Number -IsOffline $false
    Set-Disk -Number $disk.Number -IsReadOnly $false
}

$rawDisks = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' }
foreach ($disk in $rawDisks) {
    Write-Log "  Initialising RAW disk $($disk.Number)"
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru |
        New-Partition -AssignDriveLetter -UseMaximumSize |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel "DataDisk$($disk.Number)" -Confirm:$false
}
Write-Log "Disk initialisation complete."

# ── 2. Set Windows timezone ───────────────────────────────────────────────────
Write-Log "Setting timezone to W. Europe Standard Time …"
try {
    Set-TimeZone -Id "W. Europe Standard Time"
    Write-Log "Timezone set successfully."
} catch {
    Write-Log "Timezone change failed: $_" "WARN"
}

# ── 3. Enable WinRM (HTTPS) for remote management ────────────────────────────
Write-Log "Enabling WinRM …"
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
Set-Item WSMan:\localhost\MaxEnvelopeSizekb -Value 8192
Write-Log "WinRM enabled."

# ── 4. Create install directory ───────────────────────────────────────────────
Write-Log "Creating install path: $InstallPath"
if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}

# ── 5. Disable IE Enhanced Security (common for servers) ─────────────────────
Write-Log "Disabling IE Enhanced Security Configuration …"
$AdminKey  = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
$UserKey   = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
Set-ItemProperty -Path $AdminKey -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue
Set-ItemProperty -Path $UserKey  -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue

# ── 6. (Optional) Install Chocolatey and packages ────────────────────────────
# Uncomment the block below if you want Chocolatey + packages:
<#
Write-Log "Installing Chocolatey …"
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
choco install -y notepadplusplus 7zip googlechrome --no-progress
Write-Log "Chocolatey packages installed."
#>

# ── 7. Custom application install placeholder ─────────────────────────────────
# Replace this section with your actual installation logic.
Write-Log "Running application setup placeholder …"
# Example: Invoke-WebRequest -Uri "https://example.com/app.msi" -OutFile "$InstallPath\app.msi"
#          Start-Process msiexec.exe -ArgumentList "/i $InstallPath\app.msi /quiet /norestart" -Wait

Write-Log "=== Setup.ps1 completed successfully ==="
