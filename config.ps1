# NetAccelerator - Configuration
# Domain configurations and utility functions

# Certificate configuration
$CertInfoPath = Join-Path $PSScriptRoot 'certificate-info.json'
$SetupScript = Join-Path $PSScriptRoot 'setup_https.ps1'

# Proxy configuration
$ProxyPort = 26501
$ProxyHost = '127.0.0.1'

# Domain configuration for acceleration targets
$DomainConfigs = @(
    @{
        Name = 'GitHub'
        Domains = @('github.com', 'www.github.com', 'api.github.com', 'raw.githubusercontent.com', 'gist.githubusercontent.com', 'github.githubassets.com', 'avatars.githubusercontent.com', 'codeload.github.com')
        Enabled = $true
    },
    @{
        Name = '验证码平台'
        Domains = @('2captcha.com', 'anti-captcha.com', 'capmonster.cloud', 'rucaptcha.com', 'hcaptcha.com', 'recaptcha.net', 'www.google.com', 'www.gstatic.com')
        Enabled = $true
    },
    @{
        Name = 'Google'
        Domains = @('google.com', 'www.google.com', 'accounts.google.com', 'gstatic.com', 'fonts.googleapis.com', 'ajax.googleapis.com')
        Enabled = $false
    },
    @{
        Name = 'Twitter/X'
        Domains = @('twitter.com', 'x.com', 't.co', 'twimg.com', 'abs.twimg.com')
        Enabled = $false
    },
    @{
        Name = 'Discord'
        Domains = @('discord.com', 'discord.gg', 'media.discordapp.net', 'cdn.discordapp.com')
        Enabled = $false
    },
    @{
        Name = 'YouTube'
        Domains = @('youtube.com', 'www.youtube.com', 'ytimg.com', 'ggpht.com', 'googleapis.com')
        Enabled = $false
    }
)

function Get-DomainsToProxy {
    $allDomains = @()
    foreach ($config in $DomainConfigs) {
        if ($config.Enabled) {
            $allDomains += $config.Domains
        }
    }
    return $allDomains
}

function Test-CertificateReady {
    param([string]$ExpectedIp = '127.0.0.1')
    
    if (-not (Test-Path -LiteralPath $CertInfoPath -PathType Leaf)) {
        return $false
    }
    
    try {
        $Info = Get-Content $CertInfoPath | ConvertFrom-Json
        
        if (-not $Info.RootThumbprint -or -not $Info.ServerThumbprint) {
            return $false
        }
        
        $ServerCert = Get-Item -LiteralPath "Cert:\LocalMachine\My\$($Info.ServerThumbprint)" -ErrorAction Stop
        $TrustedRoot = Get-Item -LiteralPath "Cert:\LocalMachine\Root\$($Info.RootThumbprint)" -ErrorAction Stop
        
        return ($null -ne $TrustedRoot -and $ServerCert.NotAfter -gt (Get-Date).AddDays(1))
    }
    catch {
        return $false
    }
}

function Sync-CertificateIfNeeded {
    if (-not (Test-CertificateReady)) {
        try {
            $Process = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$SetupScript`"" -Verb RunAs -Wait -PassThru
            return ($Process.ExitCode -eq 0)
        }
        catch {
            return $false
        }
    }
    return $true
}

# DNS fallback servers (DnsPod, AliDNS, 114DNS)
$DnsFallbackServers = @('119.29.29.29', '223.5.5.5', '114.114.114.114')

function Resolve-DomainWithFallback {
    param([string]$Domain)
    
    # Try default DNS first
    try {
        $results = [System.Net.Dns]::GetHostAddresses($Domain)
        $cleanResults = $results | Where-Object { $_.IPAddressToString -notmatch '^127\.|^\[::1\]$' }
        if ($cleanResults) {
            return $cleanResults
        }
    }
    catch {}
    
    # DNS poisoning detected, try fallback DNS servers via nslookup
    foreach ($dnsServer in $DnsFallbackServers) {
        try {
            $nslookup = & nslookup $Domain $dnsServer 2>$null
            $addresses = $nslookup | Select-String -Pattern 'Addresses?:?\s+(\d+\.\d+\.\d+\.\d+)' -AllMatches |
                ForEach-Object { $_.Matches.Groups | Where-Object { $_.Value -match '^\d+\.\d+\.\d+\.\d+$' } } |
                ForEach-Object { $_.Value }
            
            if ($addresses) {
                $validAddresses = $addresses | Where-Object { $_ -notmatch '^127\.' }
                if ($validAddresses) {
                    $ipList = @()
                    foreach ($addr in $validAddresses) {
                        try {
                            $ipList += [System.Net.IPAddress]::Parse($addr)
                        } catch {}
                    }
                    if ($ipList.Count -gt 0) {
                        return $ipList
                    }
                }
            }
        }
        catch {}
    }
    
    # Last resort: return whatever default DNS gave us
    try {
        return [System.Net.Dns]::GetHostAddresses($Domain)
    }
    catch {
        return @()
    }
}

