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
$target = Join-Path $binDir 'NetAcceleratorServer.dll'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("NetAcceleratorServer-{0}.dll" -f [guid]::NewGuid().ToString('N'))
$responseFile = Join-Path ([IO.Path]::GetTempPath()) ("NetAcceleratorServer-{0}.rsp" -f [guid]::NewGuid().ToString('N'))
try {
    $compilerArguments = @('/nologo', '/nostdlib+', '/target:exe', '/optimize+', '/codepage:65001',
        ('/out:"' + $temporary + '"')) + $references + @('"' + (Join-Path $PSScriptRoot 'NetAcceleratorServer.cs') + '"')
    [IO.File]::WriteAllLines($responseFile, $compilerArguments, [Text.UTF8Encoding]::new($false))
    & $compiler /noconfig "@$responseFile"
    if ($LASTEXITCODE -ne 0) { throw "Compilation failed with exit code $LASTEXITCODE." }
    [IO.File]::Copy($temporary, $target, $true)
} finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $responseFile -Force -ErrorAction SilentlyContinue
}
