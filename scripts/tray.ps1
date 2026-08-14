# NetAccelerator tray application
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$RuntimeDir = Join-Path $ProjectRoot 'runtime'
$ServerDll = Join-Path $ProjectRoot 'bin\NetAcceleratorServer.dll'
$DotnetExe = (Get-Command 'dotnet.exe' -ErrorAction Stop).Source
$StatusFile = Join-Path $RuntimeDir 'proxy-status.json'
$StopFlag = Join-Path $RuntimeDir 'stop.flag'
New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
$createdNew = $false
$Mutex = New-Object System.Threading.Mutex($true, 'Local\NetAcceleratorTray', [ref]$createdNew)
if (-not $createdNew) { $Mutex.Dispose(); exit 0 }
$script:ServerPid = $null

function Get-ServiceStatus {
    try {
        if (Test-Path -LiteralPath $StatusFile) {
            return Get-Content -LiteralPath $StatusFile -Encoding UTF8 -Raw | ConvertFrom-Json
        }
    } catch { }
    return $null
}

function Test-ServerRunning {
    if ($script:ServerPid -and (Get-Process -Id $script:ServerPid -ErrorAction SilentlyContinue)) { return $true }
    $process = Get-CimInstance Win32_Process -Filter "Name='dotnet.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($ServerDll, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
        Select-Object -First 1
    if ($process) { $script:ServerPid = $process.ProcessId; return $true }
    $script:ServerPid = $null
    return $false
}

function Start-Accelerator {
    if (Test-ServerRunning) { return $true }
    Remove-Item -LiteralPath $StopFlag -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StatusFile -Force -ErrorAction SilentlyContinue
    try {
        $process = Start-Process -FilePath $DotnetExe -ArgumentList "`"$ServerDll`"" `
            -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru
        $script:ServerPid = $process.Id
    } catch {
        $TrayIcon.ShowBalloonTip(5000, 'NetAccelerator', "启动失败：$($_.Exception.Message)", 'Error')
        return $false
    }

    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        $status = Get-ServiceStatus
        if ($status -and $status.State -eq 'ready') {
            $TrayIcon.ShowBalloonTip(4000, 'NetAccelerator', 'GitHub 与国外验证码平台加速已真实就绪', 'Info')
            return $true
        }
        if ($status -and $status.State -in @('error', 'conflict')) {
            $TrayIcon.ShowBalloonTip(8000, 'NetAccelerator', [string]$status.Message, 'Error')
            return $false
        }
        if (-not (Test-ServerRunning)) { break }
        Start-Sleep -Milliseconds 300
    }
    $status = Get-ServiceStatus
    $message = if ($status) { [string]$status.Message } else { '服务未能完成真实链路自检。' }
    $TrayIcon.ShowBalloonTip(8000, 'NetAccelerator', $message, 'Error')
    return $false
}

function Stop-Accelerator {
    if (-not (Test-ServerRunning)) { return $true }
    Set-Content -LiteralPath $StopFlag -Value 'stop' -Encoding ascii
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and (Test-ServerRunning)) { Start-Sleep -Milliseconds 300 }
    if (Test-ServerRunning) {
        $TrayIcon.ShowBalloonTip(8000, 'NetAccelerator', '服务尚未安全恢复 Hosts，未强制结束。请使用“恢复网络.bat”。', 'Warning')
        return $false
    }
    $script:ServerPid = $null
    return $true
}

function Update-TrayStatus {
    $status = Get-ServiceStatus
    if (Test-ServerRunning -and $status -and $status.State -eq 'ready') {
        $StatusItem.Text = '状态：加速中（Watt Hosts 模式）'
        $TrayIcon.Text = 'NetAccelerator - 加速中'
    } elseif ($status -and $status.State -eq 'conflict') {
        $StatusItem.Text = '状态：端口冲突（请手动停止 Watt 加速）'
        $TrayIcon.Text = 'NetAccelerator - 等待释放端口'
    } else {
        $StatusItem.Text = '状态：已停止'
        $TrayIcon.Text = 'NetAccelerator - 已停止'
    }
}

$TrayIcon = New-Object System.Windows.Forms.NotifyIcon
$TrayIcon.Icon = [System.Drawing.SystemIcons]::Application
$TrayIcon.Visible = $true
$ContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$StatusItem = New-Object System.Windows.Forms.ToolStripMenuItem
$StatusItem.Enabled = $false
$RestartItem = New-Object System.Windows.Forms.ToolStripMenuItem
$RestartItem.Text = '重新开启加速'
$ExitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$ExitItem.Text = '退出并恢复 Hosts'
[void]$ContextMenu.Items.Add($StatusItem)
[void]$ContextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$ContextMenu.Items.Add($RestartItem)
[void]$ContextMenu.Items.Add($ExitItem)
$TrayIcon.ContextMenuStrip = $ContextMenu

$RestartItem.Add_Click({
    if (Test-ServerRunning) { if (-not (Stop-Accelerator)) { return } }
    [void](Start-Accelerator)
    Update-TrayStatus
})
$ExitItem.Add_Click({
    if (-not (Stop-Accelerator)) { return }
    $Timer.Stop(); $TrayIcon.Visible = $false
    [System.Windows.Forms.Application]::ExitThread()
})

$Timer = New-Object System.Windows.Forms.Timer
$Timer.Interval = 1500
$Timer.Add_Tick({ Update-TrayStatus })
$Timer.Start()

try {
    [void](Start-Accelerator)
    Update-TrayStatus
    [System.Windows.Forms.Application]::Run()
} finally {
    $Timer.Stop(); $Timer.Dispose()
    $TrayIcon.Visible = $false; $TrayIcon.Dispose(); $ContextMenu.Dispose()
    try { $Mutex.ReleaseMutex() } catch { }
    $Mutex.Dispose()
}
