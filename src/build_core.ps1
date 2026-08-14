$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$binDir = Join-Path $projectRoot 'bin'
New-Item -ItemType Directory -Path $binDir -Force | Out-Null
$runtimeRoot = Join-Path $env:ProgramFiles 'dotnet\shared\Microsoft.NETCore.App'
$runtime = Get-ChildItem -LiteralPath $runtimeRoot -Directory |
    Where-Object { [version]$_.Name -ge [version]'10.0.0' } |
    Sort-Object { [version]$_.Name } -Descending |
    Select-Object -First 1
if (-not $runtime) { throw '.NET 10 Desktop Runtime is required.' }

$references = Get-ChildItem -LiteralPath $runtime.FullName -Filter '*.dll' |
    Where-Object {
        if ($_.Name -eq 'System.Text.Encodings.Web.dll') { return $false }
        try { [Reflection.AssemblyName]::GetAssemblyName($_.FullName) | Out-Null; $true }
        catch { $false }
    } |
    ForEach-Object { '/r:"' + $_.FullName + '"' }

$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo /noconfig /nostdlib+ /target:exe /optimize+ /codepage:65001 `
    "/out:$binDir\NetAcceleratorServer.dll" $references `
    "$PSScriptRoot\NetAcceleratorServer.cs"
if ($LASTEXITCODE -ne 0) { throw "Compilation failed with exit code $LASTEXITCODE." }
