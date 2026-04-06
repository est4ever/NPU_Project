param(
    [string]$ModelPath = "./models/Qwen2.5-0.5B-Instruct",
    [string]$Device = "",
    [int]$ApiPort = 8000,
    [int]$AppPort = 5173,
    [int]$TimeoutSeconds = 120,
    [switch]$HideServiceWindows,
    [string[]]$BackendArgs = @()
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

function Test-TcpPort {
    param(
        [string]$Hostname,
        [int]$Port,
        [int]$TimeoutMs = 500
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Hostname, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Open-Url {
    param([string]$Url)

    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = "cmd.exe"
        $startInfo.Arguments = "/c start `"Browser`" `"$Url`""
        $startInfo.CreateNoWindow = $true
        $startInfo.UseShellExecute = $false
        [System.Diagnostics.Process]::Start($startInfo) | Out-Null
        return $true
    } catch {
        try {
            Start-Process $Url -ErrorAction Stop
            return $true
        } catch {
            return $false
        }
    }
}

function Stop-AppShellServer {
    param([int]$Port)

    Get-CimInstance Win32_Process -Filter "name = 'python.exe' OR name = 'pythonw.exe'" |
        Where-Object {
            $_.CommandLine -like "*http.server $Port*" -and
            $_.CommandLine -like "*--directory app_shell*"
        } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Stop-BackendServer {
    Get-Process npu_wrapper -ErrorAction SilentlyContinue |
        ForEach-Object {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
}

function Start-BackendServer {
    param(
        [string]$Model,
        [string]$DeviceOverride,
        [int]$Port,
        [switch]$HideWindow,
        [string[]]$Args
    )

    $runScript = Join-Path $scriptDir "run.ps1"
    if (-not (Test-Path $runScript)) {
        throw "[App] Missing run script: $runScript"
    }

    $escapedBackendArgs = @()
    foreach ($arg in $Args) {
        if ($null -eq $arg -or $arg -eq "") { continue }
        $escaped = $arg.Replace('"', '`"')
        if ($escaped -match '\s') {
            $escapedBackendArgs += '"' + $escaped + '"'
        } else {
            $escapedBackendArgs += $escaped
        }
    }

    $backendCmd = "Set-Location '$scriptDir'; & '$runScript' '$Model' --server --port $Port"
    if ($DeviceOverride -and $DeviceOverride -ne "") {
        $backendCmd += " --device $DeviceOverride"
    }
    if ($escapedBackendArgs.Count -gt 0) {
        $backendCmd += " " + ($escapedBackendArgs -join " ")
    }

    $windowStyle = if ($HideWindow) { "Hidden" } else { "Normal" }
    Start-Process powershell -ArgumentList "-NoExit", "-Command", $backendCmd -WindowStyle $windowStyle | Out-Null
}

function Wait-ForApiReady {
    param(
        [int]$Port,
        [int]$TimeoutSec
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort -Hostname "127.0.0.1" -Port $Port -TimeoutMs 500) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

Write-Host "[App] Project root: $scriptDir" -ForegroundColor Cyan
Write-Host "[App] Starting backend API + App Shell (OpenWebUI disabled)..." -ForegroundColor Cyan

Write-Host "[App] Stopping stale backend/app shell processes..." -ForegroundColor Yellow
Stop-BackendServer
Stop-AppShellServer -Port $AppPort

Start-BackendServer -Model $ModelPath -DeviceOverride $Device -Port $ApiPort -HideWindow:$HideServiceWindows -Args $BackendArgs

if (Wait-ForApiReady -Port $ApiPort -TimeoutSec $TimeoutSeconds) {
    Write-Host "[App] Backend API is ready at http://localhost:$ApiPort/v1" -ForegroundColor Green
} else {
    throw "[App] Backend API did not become ready on port $ApiPort within $TimeoutSeconds seconds."
}

Write-Host "[App] Preparing app shell on port $AppPort..." -ForegroundColor Cyan

$pythonExe = Join-Path $scriptDir "venv\Scripts\python.exe"
$pythonCmd = if (Test-Path $pythonExe) { "& '$pythonExe'" } else { "python" }
$appShellCmd = "Set-Location '$scriptDir'; $pythonCmd -m http.server $AppPort --directory app_shell"
$windowStyle = if ($HideServiceWindows) { "Hidden" } else { "Normal" }
Start-Process powershell -ArgumentList "-NoExit", "-Command", $appShellCmd -WindowStyle $windowStyle | Out-Null

$deadline = (Get-Date).AddSeconds(30)
$appReady = $false
while ((Get-Date) -lt $deadline) {
    if (Test-TcpPort -Hostname "127.0.0.1" -Port $AppPort -TimeoutMs 500) {
        $appReady = $true
        break
    }
    Start-Sleep -Milliseconds 500
}

$appUrl = "http://localhost:$AppPort"
$apiBase = "http://localhost:$ApiPort/v1"

if ($appReady) {
    Write-Host "[App] App shell is ready at $appUrl" -ForegroundColor Green
} else {
    Write-Host "[App] App shell did not report ready within timeout, but process was started." -ForegroundColor Yellow
}

if (Open-Url -Url $appUrl) {
    Write-Host "[App] Opened app shell in browser." -ForegroundColor Green
} else {
    Write-Host "[App] Could not auto-open browser. Open manually: $appUrl" -ForegroundColor Yellow
}

Write-Host "`n[App] Ready." -ForegroundColor Green
Write-Host "Primary UI (App Shell): $appUrl"
Write-Host "API base: $apiBase"
