# NetAccelerator - Launch Script
# Launches the tray application

$ErrorActionPreference = 'Stop'

$TrayScript = Join-Path $PSScriptRoot 'tray.ps1'

# Check if already running using createdNew flag
$createdNew = $false
$Mutex = New-Object System.Threading.Mutex($true, 'Local\NetAcceleratorTray', [ref]$createdNew)
if (-not $createdNew) {
    $Mutex.Dispose()
    Write-Host "NetAccelerator is already running."
    exit 0
}
$Mutex.ReleaseMutex()
$Mutex.Dispose()

$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

Start-Process -FilePath $PowerShellExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$TrayScript`"" -WindowStyle Hidden

Write-Host "NetAccelerator started."
