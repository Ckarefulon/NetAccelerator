# NetAccelerator launcher. Hosts mode and ports 80/443 require elevation.
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $powershell `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
        -Verb RunAs -WindowStyle Hidden
    exit 0
}

$setup = Join-Path $PSScriptRoot 'setup_https.ps1'
$tray = Join-Path $PSScriptRoot 'tray.ps1'
& $setup

$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
Start-Process -FilePath $powershell `
    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tray`"" `
    -WorkingDirectory $ProjectRoot -WindowStyle Hidden
