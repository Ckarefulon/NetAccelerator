# NetAccelerator - Proxy Server
# Implements lightweight reverse proxy following Watt Toolkit architecture
# Uses TcpClient + SslStream for direct IP connection (bypassing DNS poisoning)

$ErrorActionPreference = 'Stop'

# Import configuration
. (Join-Path $PSScriptRoot 'config.ps1')

# Certificate management
$CertInfoPath = Join-Path $PSScriptRoot 'certificate-info.json'

# Mutex for single instance
$MutexName = 'Local\NetAcceleratorProxy'
$CreatedNew = $false
$Mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$CreatedNew)

if (-not $CreatedNew) {
    exit 0
}

# Verify certificate info exists
if (-not (Test-Path $CertInfoPath)) {
    Write-Host "Certificate info not found. Run setup_https.ps1 first."
    exit 1
}

$Info = Get-Content $CertInfoPath | ConvertFrom-Json
$ServerThumbprint = $Info.ServerThumbprint

# Create HTTPS listener
$BaseUrl = "https://localhost:$ProxyPort/"
$HttpListener = New-Object System.Net.HttpListener

try {
    $HttpListener.Prefixes.Add($BaseUrl)
    $HttpListener.Start()
    
    Write-Host "Proxy server started on $BaseUrl"
    Write-Host "Certificate: $ServerThumbprint"
    
    $DomainsToProxy = Get-DomainsToProxy
    Write-Host "Monitoring domains: $($DomainsToProxy -join ', ')"
    
    while ($HttpListener.IsListening) {
        $Context = $null
        $Response = $null
        
        try {
            $Context = $HttpListener.GetContext()
            $Request = $Context.Request
            $Response = $Context.Response
            
            $HostHeader = $Request.Headers['Host']
            $RequestPath = $Request.Url.PathAndQuery
            
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $($Request.HttpMethod) $HostHeader$RequestPath"
            
            # Check if domain is configured for proxying
            $ShouldProxy = $false
            $TargetDomain = $null
            
            foreach ($domain in $DomainsToProxy) {
                if ($HostHeader -eq $domain -or $HostHeader.EndsWith(".$domain")) {
                    $ShouldProxy = $true
                    $TargetDomain = $HostHeader
                    break
                }
            }
            
            if (-not $ShouldProxy) {
                Write-ErrorResponse -Response $Response -StatusCode 404 -Message 'Domain not configured for acceleration'
                continue
            }
            
            # Resolve domain with fallback DNS
            $ResolvedIps = Resolve-DomainWithFallback -Domain $TargetDomain
            if (-not $ResolvedIps -or $ResolvedIps.Count -eq 0) {
                Write-ErrorResponse -Response $Response -StatusCode 502 -Message 'DNS resolution failed'
                continue
            }
            
            $TargetIp = $ResolvedIps[0].IPAddressToString
            Write-Host "  -> $($TargetDomain) @ $TargetIp`:443"
            
            # Forward request via direct socket connection
            $result = Forward-RequestViaSocket -Request $Request -TargetHost $TargetDomain -TargetIp $TargetIp -TargetPort 443 -Response $Response
            
            if (-not $result) {
                Write-ErrorResponse -Response $Response -StatusCode 502 -Message 'Proxy connection failed'
            }
            
        }
        catch [System.Net.HttpListenerException] {
            break
        }
        catch {
            Write-Host "Error: $_"
            if ($Response) {
                try {
                    Write-ErrorResponse -Response $Response -StatusCode 500 -Message $_.Exception.Message
                } catch {}
            }
        }
    }
}
finally {
    if ($HttpListener.IsListening) {
        $HttpListener.Stop()
    }
    $HttpListener.Close()
    $Mutex.ReleaseMutex()
    $Mutex.Dispose()
    Write-Host "Proxy server stopped"
}

function Write-ErrorResponse {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [int]$StatusCode,
        [string]$Message
    )
    try {
        $body = "{`"error`": `"$($Message -replace '"','\"')`"}"
        $Buffer = [System.Text.Encoding]::UTF8.GetBytes($body)
        $Response.StatusCode = $StatusCode
        $Response.ContentType = 'application/json'
        $Response.ContentLength64 = $Buffer.Length
        $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
        $Response.OutputStream.Flush()
        $Response.Close()
    } catch {}
}

function Forward-RequestViaSocket {
    param(
        [System.Net.HttpListenerRequest]$Request,
        [string]$TargetHost,
        [string]$TargetIp,
        [int]$TargetPort,
        [System.Net.HttpListenerResponse]$Response
    )
    
    $TcpClient = $null
    $SslStream = $null
    $StreamWriter = $null
    
    try {
        # Connect directly to target IP (bypasses DNS)
        $TcpClient = New-Object System.Net.Sockets.TcpClient
        $TcpClient.Connect($TargetIp, $TargetPort)
        $TcpClient.SendTimeout = 30000
        $TcpClient.ReceiveTimeout = 30000
        
        # Wrap with SSL
        $SslStream = New-Object System.Net.Security.SslStream($TcpClient.GetStream(), $false)
        $SslStream.AuthenticateAsClient($TargetHost)
        
        $StreamWriter = New-Object System.IO.StreamWriter($SslStream)
        $StreamWriter.AutoFlush = $false
        
        # Build HTTP request line
        $StreamWriter.WriteLine("$($Request.HttpMethod) $($Request.Url.PathAndQuery) HTTP/1.1")
        $StreamWriter.WriteLine("Host: $TargetHost")
        
        # Copy request headers (skip restricted ones)
        $restrictedHeaders = @('Host', 'Connection', 'Keep-Alive', 'Transfer-Encoding', 'Content-Length', 'Proxy-Connection')
        foreach ($key in $Request.Headers.AllKeys) {
            if ($key -and $key -notin $restrictedHeaders) {
                $StreamWriter.WriteLine("$key`: $($Request.Headers[$key])")
            }
        }
        
        # Handle request body
        $bodyBytes = $null
        if ($Request.HasEntityBody -and $Request.ContentLength64 -gt 0) {
            $memStream = New-Object System.IO.MemoryStream
            $Request.InputStream.CopyTo($memStream)
            $bodyBytes = $memStream.ToArray()
            $memStream.Close()
            $StreamWriter.WriteLine("Content-Length: $($bodyBytes.Length)")
        }
        
        $StreamWriter.WriteLine("Connection: close")
        $StreamWriter.WriteLine()
        $StreamWriter.Flush()
        
        # Write body if present
        if ($bodyBytes -and $bodyBytes.Length -gt 0) {
            $SslStream.Write($bodyBytes, 0, $bodyBytes.Length)
            $SslStream.Flush()
        }
        
        # Read response
        $reader = New-Object System.IO.StreamReader($SslStream)
        $responseData = New-Object System.Text.StringBuilder
        
        # Read headers
        $statusLine = $reader.ReadLine()
        if (-not $statusLine) {
            return $false
        }
        
        $statusMatch = [regex]::Match($statusLine, 'HTTP/\d\.\d\s+(\d+)\s+(.*)')
        if ($statusMatch.Success) {
            $Response.StatusCode = [int]$statusMatch.Groups[1].Value
            $Response.StatusDescription = $statusMatch.Groups[2].Value
        }
        
        # Read response headers
        $contentLength = 0
        $isChunked = $false
        $responseHeaderLines = @()
        
        while ($true) {
            $line = $reader.ReadLine()
            if ($line -eq '' -or $line -eq $null) { break }
            $responseHeaderLines += $line
        }
        
        foreach ($line in $responseHeaderLines) {
            $colonIndex = $line.IndexOf(':')
            if ($colonIndex -gt 0) {
                $headerName = $line.Substring(0, $colonIndex).Trim()
                $headerValue = $line.Substring($colonIndex + 1).Trim()
                
                if ($headerName -eq 'Transfer-Encoding' -and $headerValue -eq 'chunked') {
                    $isChunked = $true
                }
                elseif ($headerName -eq 'Content-Length') {
                    [int]::TryParse($headerValue, [ref]$contentLength) | Out-Null
                }
                elseif ($headerName -notin @('Connection', 'Keep-Alive', 'Transfer-Encoding')) {
                    # Set via property for restricted headers, otherwise use Add
                    try {
                        $Response.Headers.Add($headerName, $headerValue)
                    } catch {
                        # Restricted header: set via property
                        try {
                            switch ($headerName) {
                                'Content-Type' { $Response.ContentType = $headerValue }
                                'Content-Encoding' { $Response.Headers['Content-Encoding'] = $headerValue }
                            }
                        } catch {}
                    }
                }
            }
        }
        
        # Read response body
        $bodyStream = New-Object System.IO.MemoryStream
        
        if ($isChunked) {
            # Read chunked encoding
            while ($true) {
                $chunkSizeLine = $reader.ReadLine()
                if (-not $chunkSizeLine) { break }
                $chunkSize = [int]::Parse($chunkSizeLine, [System.Globalization.NumberStyles]::HexNumber)
                if ($chunkSize -eq 0) { 
                    $reader.ReadLine() | Out-Null  # final CRLF
                    break 
                }
                $chunkBuffer = New-Object char[] $chunkSize
                $read = $reader.Read($chunkBuffer, 0, $chunkSize)
                $bodyStream.Write([System.Text.Encoding]::UTF8.GetBytes($chunkBuffer, 0, $read), 0, $read)
                $reader.ReadLine() | Out-Null  # chunk CRLF
            }
        }
        elseif ($contentLength -gt 0) {
            $totalRead = 0
            $buffer = New-Object char[] 8192
            while ($totalRead -lt $contentLength) {
                $toRead = [Math]::Min(8192, $contentLength - $totalRead)
                $read = $reader.Read($buffer, 0, $toRead)
                if ($read -le 0) { break }
                $bodyStream.Write([System.Text.Encoding]::UTF8.GetBytes($buffer, 0, $read), 0, $read)
                $totalRead += $read
            }
        }
        else {
            # Read until connection close
            $buffer = New-Object char[] 8192
            while ($true) {
                $read = $reader.Read($buffer, 0, 8192)
                if ($read -le 0) { break }
                $bodyStream.Write([System.Text.Encoding]::UTF8.GetBytes($buffer, 0, $read), 0, $read)
            }
        }
        
        $bodyBytes = $bodyStream.ToArray()
        $bodyStream.Close()
        
        $Response.ContentLength64 = $bodyBytes.Length
        $Response.OutputStream.Write($bodyBytes, 0, $bodyBytes.Length)
        $Response.OutputStream.Flush()
        $Response.Close()
        
        return $true
    }
    catch {
        Write-Host "  Socket proxy error: $_"
        return $false
    }
    finally {
        if ($StreamWriter) { $StreamWriter.Close() }
        if ($SslStream) { $SslStream.Close() }
        if ($TcpClient) { $TcpClient.Close() }
    }
}

