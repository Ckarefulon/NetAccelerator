# NetAccelerator - Setup Script
# Sets up HTTPS certificate for proxy server

param([switch]$Force)

$ErrorActionPreference = 'Stop'

$CertInfoPath = Join-Path $PSScriptRoot 'certificate-info.json'

if (-not $Force -and (Test-Path $CertInfoPath)) {
    Write-Host "Certificate already exists. Use -Force to recreate."
    exit 0
}

Write-Host "Generating CA certificate..."
$CAKey = New-SelfSignedCertificate -Type Custom `
    -Subject "CN=NetAccelerator Root CA" `
    -KeyExportPolicy Exportable `
    -KeyLength 4096 `
    -KeyAlgorithm RSA `
    -HashAlgorithm SHA256 `
    -NotBefore (Get-Date) `
    -NotAfter (Get-Date).AddYears(10) `
    -CertStoreLocation Cert:\LocalMachine\My

$CAThumbprint = $CAKey.Thumbprint

Write-Host "Importing CA certificate to trusted root..."
$tempCertPath = Join-Path $env:TEMP "NetAccelerator_CA_$([Guid]::NewGuid()).cer"
$CAKey.Export('Cert') | Set-Content -Path $tempCertPath -Encoding Byte
Import-Certificate -FilePath $tempCertPath -CertStoreLocation Cert:\LocalMachine\Root -ErrorAction SilentlyContinue
Remove-Item $tempCertPath -Force -ErrorAction SilentlyContinue

Write-Host "Generating server certificate..."
$ServerKey = New-SelfSignedCertificate -Type Custom `
    -DnsName "localhost", "127.0.0.1" `
    -Signer $CAKey `
    -KeyExportPolicy Exportable `
    -KeyLength 2048 `
    -KeyAlgorithm RSA `
    -HashAlgorithm SHA256 `
    -NotBefore (Get-Date) `
    -NotAfter (Get-Date).AddYears(5) `
    -CertStoreLocation Cert:\LocalMachine\My

$ServerThumbprint = $ServerKey.Thumbprint

$CAExportPath = Join-Path $PSScriptRoot 'LocalHttpsRootCA.cer'
$CAKey.Export('Cert') | Set-Content -Path $CAExportPath -Encoding Byte

$CertInfo = @{
    Port = 26501
    RootThumbprint = $CAThumbprint
    ServerThumbprint = $ServerThumbprint
    RootCertificateCer = $CAExportPath
    RootCertificateCrt = $CAExportPath
} | ConvertTo-Json

$CertInfo | Out-File -FilePath $CertInfoPath -Encoding utf8

Write-Host "Configuring HTTPS binding..."
netsh http delete sslcert ipport=0.0.0.0:26501 2>$null
netsh http add sslcert ipport=0.0.0.0:26501 certhash=$ServerThumbprint appid='{75A9E0C7-4B6F-4C8A-9F2E-1D3E5F6A7B8C}'

$FirewallRule = "NetAccelerator-Proxy-26501"
if (-not (Get-NetFirewallRule -Name $FirewallRule -ErrorAction SilentlyContinue)) {
    Write-Host "Creating firewall rule..."
    New-NetFirewallRule -DisplayName $FirewallRule -Direction Inbound -Protocol TCP -LocalPort 26501 -Action Allow
}

Write-Host "Setup complete!"
Write-Host "  CA Certificate: $CAThumbprint"
Write-Host "  Server Certificate: $ServerThumbprint"
Write-Host "  Port: 26501"


