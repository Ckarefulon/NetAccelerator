# Emergency rollback: remove only the NetAccelerator-managed Hosts block.
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$RuntimeDir = Join-Path $ProjectRoot 'runtime'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -Wait
    exit $LASTEXITCODE
}

$hostsPath = Join-Path ([Environment]::GetFolderPath('System')) 'drivers\etc\hosts'
$text = Get-Content -LiteralPath $hostsPath -Encoding UTF8 -Raw
$pattern = '(?ms)^\s*# NetAccelerator Start\s*$.*?^\s*# NetAccelerator End\s*$\r?\n?'
$clean = [regex]::Replace($text, $pattern, '').TrimEnd("`r", "`n") + "`r`n"
if ($clean -ne $text) {
    [IO.File]::WriteAllText($hostsPath, $clean, (New-Object Text.UTF8Encoding($false)))
    & ipconfig /flushdns | Out-Null
}
Remove-Item -LiteralPath (Join-Path $RuntimeDir 'hosts-backup.txt') -Force -ErrorAction SilentlyContinue
Write-Host 'NetAccelerator Hosts entries have been removed. System proxy and Clash were not changed.'
