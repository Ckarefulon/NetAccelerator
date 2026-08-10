# NetAccelerator - Tray Application
# Lightweight tray app with site selection menu

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Import configuration
. (Join-Path $PSScriptRoot 'config.ps1')

$ProxyScript = Join-Path $PSScriptRoot 'proxy_server.ps1'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Mutex for single instance
$MutexName = 'Local\NetAcceleratorTray'
$CreatedNew = $false
$Mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$CreatedNew)

if (-not $CreatedNew) {
    exit 0
}

$script:ProxyPid = $null
$script:CustomTrayIcon = $null

function Find-ExistingProxy {
    $TargetPath = $ProxyScript.ToLowerInvariant()
    
    return Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ieq 'powershell.exe' -and $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains($TargetPath) } |
        Select-Object -First 1
}

function Test-ProxyRunning {
    if ($script:ProxyPid) {
        $Process = Get-Process -Id $script:ProxyPid -ErrorAction SilentlyContinue
        if ($Process) {
            return $true
        }
        $script:ProxyPid = $null
    }
    
    $ExistingProxy = Find-ExistingProxy
    if ($ExistingProxy) {
        $script:ProxyPid = $ExistingProxy.ProcessId
        return $true
    }
    
    return $false
}

function Update-TrayStatus {
    $Running = Test-ProxyRunning
    
    if ($Running) {
        $StatusItem.Text = 'Status: Running'
        $StartItem.Enabled = $false
        $StopItem.Enabled = $true
        $TrayIcon.Text = 'NetAccelerator - Running'
    }
    else {
        $StatusItem.Text = 'Status: Stopped'
        $StartItem.Enabled = $true
        $StopItem.Enabled = $false
        $TrayIcon.Text = 'NetAccelerator - Stopped'
    }
}

function Start-Proxy {
    if (Test-ProxyRunning) {
        Update-TrayStatus
        return
    }
    
    $Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ProxyScript + '"'
    
    try {
        $Process = Start-Process -FilePath $PowerShellExe -ArgumentList $Arguments -WindowStyle Hidden -PassThru
        $script:ProxyPid = $Process.Id
        
        Start-Sleep -Milliseconds 700
        
        if ($Process.HasExited) {
            $script:ProxyPid = $null
            $TrayIcon.ShowBalloonTip(3000, 'NetAccelerator', 'Proxy failed to start.', [System.Windows.Forms.ToolTipIcon]::Error)
        }
        else {
            $TrayIcon.ShowBalloonTip(2000, 'NetAccelerator', 'Proxy started successfully.', [System.Windows.Forms.ToolTipIcon]::Info)
        }
    }
    catch {
        $script:ProxyPid = $null
        $TrayIcon.ShowBalloonTip(3000, 'NetAccelerator', $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error)
    }
    
    Update-TrayStatus
}

function Stop-Proxy {
    $ExistingProxy = Find-ExistingProxy
    
    if ($ExistingProxy) {
        Stop-Process -Id $ExistingProxy.ProcessId -Force -ErrorAction SilentlyContinue
    }
    
    $script:ProxyPid = $null
    
    $TrayIcon.ShowBalloonTip(1500, 'NetAccelerator', 'Proxy stopped.', [System.Windows.Forms.ToolTipIcon]::Info)
    Update-TrayStatus
}

# Create context menu
$ContextMenu = New-Object System.Windows.Forms.ContextMenuStrip

$StatusItem = New-Object System.Windows.Forms.ToolStripMenuItem
$StatusItem.Text = 'Status: Starting'
$StatusItem.Enabled = $false

$StartItem = New-Object System.Windows.Forms.ToolStripMenuItem
$StartItem.Text = 'Start Proxy'

$StopItem = New-Object System.Windows.Forms.ToolStripMenuItem
$StopItem.Text = 'Stop Proxy'

$Separator1 = New-Object System.Windows.Forms.ToolStripSeparator

# Site selection sub-menu
$SitesMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$SitesMenuItem.Text = '加速站点'

# Create checkboxes for each site
foreach ($config in $DomainConfigs) {
    $checkbox = New-Object System.Windows.Forms.ToolStripMenuItem
    $checkbox.Text = $config.Name
    $checkbox.CheckOnClick = $true
    $checkbox.Checked = $config.Enabled
    $checkbox.Tag = $config
    $SitesMenuItem.DropDownItems.Add($checkbox)
}

$Separator2 = New-Object System.Windows.Forms.ToolStripSeparator
$ExitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$ExitItem.Text = '退出'

[void]$ContextMenu.Items.Add($StatusItem)
[void]$ContextMenu.Items.Add($StartItem)
[void]$ContextMenu.Items.Add($StopItem)
[void]$ContextMenu.Items.Add($Separator1)
[void]$ContextMenu.Items.Add($SitesMenuItem)
[void]$ContextMenu.Items.Add($Separator2)
[void]$ContextMenu.Items.Add($ExitItem)

# Tray icon
$TrayIcon = New-Object System.Windows.Forms.NotifyIcon

# Load custom icon if exists
$IconPath = Join-Path $PSScriptRoot 'favicon.ico'
if (Test-Path -LiteralPath $IconPath -PathType Leaf) {
    $script:CustomTrayIcon = New-Object System.Drawing.Icon($IconPath)
    $TrayIcon.Icon = $script:CustomTrayIcon
}
else {
    $TrayIcon.Icon = [System.Drawing.SystemIcons]::Application
}

$TrayIcon.Text = 'NetAccelerator'
$TrayIcon.ContextMenuStrip = $ContextMenu
$TrayIcon.Visible = $true

# Event handlers
$StartItem.Add_Click({ Start-Proxy })
$StopItem.Add_Click({ Stop-Proxy })

$ExitItem.Add_Click({
    Stop-Proxy
    $Timer.Stop()
    $Timer.Dispose()
    $TrayIcon.Visible = $false
    $TrayIcon.Dispose()
    $ContextMenu.Dispose()
    [System.Windows.Forms.Application]::ExitThread()
})

# Double-click to start/stop proxy
$TrayIcon.Add_DoubleClick({
    if (Test-ProxyRunning) {
        Stop-Proxy
    }
    else {
        Start-Proxy
    }
})

# Timer to refresh status
$Timer = New-Object System.Windows.Forms.Timer
$Timer.Interval = 2000
$Timer.Add_Tick({ Update-TrayStatus })
$Timer.Start()

# Event handler for site toggle
foreach ($item in $SitesMenuItem.DropDownItems) {
    if ($item.GetType().Name -ne 'ToolStripMenuItem') { continue }
    $item.Add_Click({
        param($sender, $e)
        $siteConfig = $sender.Tag
        $siteConfig['Enabled'] = $sender.Checked
        $statusText = if ($sender.Checked) { 'enabled' } else { 'disabled' }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Site '$($siteConfig['Name'])' $statusText"
    })
}

# Main execution
try {
    # Auto-sync certificate if needed
    Sync-CertificateIfNeeded
    
    # Start proxy automatically
    Start-Proxy
    Update-TrayStatus
    
    [System.Windows.Forms.Application]::Run()
}
finally {
    $Timer.Stop()
    $Timer.Dispose()
    $TrayIcon.Visible = $false
    $TrayIcon.Dispose()
    
    if ($script:CustomTrayIcon) {
        $script:CustomTrayIcon.Dispose()
        $script:CustomTrayIcon = $null
    }
    
    $ContextMenu.Dispose()
    $Mutex.ReleaseMutex()
    $Mutex.Dispose()
}
