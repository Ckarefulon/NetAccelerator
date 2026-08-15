# NetAccelerator certificate setup (Watt-style local TLS reverse proxy)
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ConfigDir = Join-Path $ProjectRoot 'config'
$CertificateDir = Join-Path $ProjectRoot 'certificates'
$CertInfoPath = Join-Path $ConfigDir 'certificate-info.json'
$DomainsPath = Join-Path $ConfigDir 'domains.txt'
$RootCerPath = Join-Path $CertificateDir 'NetAcceleratorRootCA.cer'
New-Item -ItemType Directory -Path $ConfigDir, $CertificateDir -Force | Out-Null

function Remove-PrivateRootCertificate {
    param([string]$Thumbprint)
    $privateRootPath = "Cert:\CurrentUser\My\$Thumbprint"
    if (Test-Path -LiteralPath $privateRootPath) {
        Remove-Item -LiteralPath $privateRootPath -Force
    }
}

if (-not (Test-Path -LiteralPath $DomainsPath -PathType Leaf)) {
    throw 'domains.txt is missing.'
}

$domains = @(Get-Content -LiteralPath $DomainsPath -Encoding UTF8 |
    ForEach-Object { $_.Trim().TrimEnd('.') } |
    Where-Object { $_ -and -not $_.StartsWith('#') } |
    Sort-Object -Unique)

if (-not $Force -and (Test-Path -LiteralPath $CertInfoPath -PathType Leaf)) {
    try {
        $old = Get-Content -LiteralPath $CertInfoPath -Encoding UTF8 -Raw | ConvertFrom-Json
        $existing = Get-Item -LiteralPath "Cert:\CurrentUser\My\$($old.ServerThumbprint)" -ErrorAction Stop
        $names = ($existing.Extensions | ForEach-Object { $_.Format($true) }) -join "`n"
        if ($existing.HasPrivateKey -and $existing.NotAfter -gt (Get-Date).AddDays(30) -and $names -match 'github\.com') {
            if (-not (Test-Path -LiteralPath "Cert:\CurrentUser\Root\$($old.RootThumbprint)")) {
                $existingRoot = Get-Item -LiteralPath "Cert:\CurrentUser\My\$($old.RootThumbprint)" -ErrorAction Stop
                Export-Certificate -Cert $existingRoot -FilePath $RootCerPath -Force | Out-Null
                Write-Host "Trusting the existing NetAccelerator root $($old.RootThumbprint) for the current user..."
                Import-Certificate -FilePath $RootCerPath -CertStoreLocation 'Cert:\CurrentUser\Root' | Out-Null
            }
            Remove-PrivateRootCertificate -Thumbprint $old.RootThumbprint
            Write-Host "NetAccelerator certificate is ready: $($old.RootThumbprint)."
            exit 0
        }
    } catch { }
}

$root = Get-ChildItem 'Cert:\CurrentUser\My' -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Subject -eq 'CN=NetAccelerator Root CA, O=NetAccelerator' -and
        $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30)
    } | Sort-Object NotBefore -Descending | Select-Object -First 1

if (-not $root) {
    Write-Host 'Creating the private NetAccelerator root certificate...'
    $root = New-SelfSignedCertificate -Type Custom `
        -Subject 'CN=NetAccelerator Root CA, O=NetAccelerator' `
        -FriendlyName 'NetAccelerator Root CA' `
        -KeyExportPolicy NonExportable `
        -KeyLength 2048 `
        -KeyAlgorithm RSA `
        -HashAlgorithm SHA256 `
        -KeyUsage CertSign, CRLSign, DigitalSignature `
        -TextExtension @('2.5.29.19={critical}{text}ca=1&pathlength=1') `
        -NotAfter (Get-Date).AddYears(5) `
        -CertStoreLocation 'Cert:\CurrentUser\My'
} else {
    Write-Host "Reusing NetAccelerator root certificate $($root.Thumbprint)."
}

Export-Certificate -Cert $root -FilePath $RootCerPath -Force | Out-Null

Write-Host 'Creating the server certificate for the enabled Watt domains...'
$server = New-SelfSignedCertificate -Type Custom `
    -Subject 'CN=github.com, O=NetAccelerator' `
    -FriendlyName 'NetAccelerator Local Reverse Proxy' `
    -DnsName $domains `
    -Signer $root `
    -KeyExportPolicy NonExportable `
    -KeyLength 2048 `
    -KeyAlgorithm RSA `
    -HashAlgorithm SHA256 `
    -KeyUsage DigitalSignature, KeyEncipherment `
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.1') `
    -NotAfter (Get-Date).AddYears(2) `
    -CertStoreLocation 'Cert:\CurrentUser\My'

[ordered]@{
    Mode = 'HostsReverseProxy'
    RootThumbprint = $root.Thumbprint
    ServerThumbprint = $server.Thumbprint
    DomainCount = $domains.Count
    Created = (Get-Date).ToString('o')
} | ConvertTo-Json | Out-File -LiteralPath $CertInfoPath -Encoding utf8 -Force

if (-not (Test-Path -LiteralPath "Cert:\CurrentUser\Root\$($root.Thumbprint)")) {
    Write-Host 'Trusting the private NetAccelerator root certificate for the current user...'
    Import-Certificate -FilePath $RootCerPath -CertStoreLocation 'Cert:\CurrentUser\Root' | Out-Null
}

Remove-PrivateRootCertificate -Thumbprint $root.Thumbprint
Write-Host "Certificate setup complete. Domains: $($domains.Count)"
