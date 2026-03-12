param(
    [string]$ModelPath = "./models/Qwen2.5-0.5B-Instruct",
    [int]$ApiPort = 8000,
    [int]$WebUiPort = 8080,
    [int]$TimeoutSeconds = 90,
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

Write-Host "[Stack] Project root: $scriptDir" -ForegroundColor Cyan
Write-Host "[Stack] Model: $ModelPath" -ForegroundColor Cyan
Write-Host "[Stack] API port: $ApiPort | WebUI port: $WebUiPort" -ForegroundColor Cyan
if ($BackendArgs -and $BackendArgs.Count -gt 0) {
    Write-Host "[Stack] Backend args: $($BackendArgs -join ' ')" -ForegroundColor Cyan
}

# 1) Stop previous processes
Write-Host "[Stack] Stopping previous npu_wrapper/open-webui processes..." -ForegroundColor Yellow
Get-Process npu_wrapper -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "name = 'python.exe' OR name = 'pythonw.exe'" |
    Where-Object { $_.CommandLine -like '*open-webui*' -or $_.CommandLine -like '*open_webui*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# 2) Start NPU server
$escapedBackendArgs = @()
foreach ($arg in $BackendArgs) {
    if ($null -eq $arg -or $arg -eq "") { continue }
    $escaped = $arg.Replace('"', '`"')
    if ($escaped -match '\s') {
        $escapedBackendArgs += '"' + $escaped + '"'
    } else {
        $escapedBackendArgs += $escaped
    }
}

$serverCmd = "Set-Location '$scriptDir'; .\\run.ps1 '$ModelPath' --server --port $ApiPort"
if ($escapedBackendArgs.Count -gt 0) {
    $serverCmd += " " + ($escapedBackendArgs -join " ")
}
$windowStyle = if ($HideServiceWindows) { "Hidden" } else { "Normal" }
Start-Process powershell -ArgumentList "-NoExit", "-Command", $serverCmd -WindowStyle $windowStyle | Out-Null
Write-Host "[Stack] NPU server window started." -ForegroundColor Green

# 3) Start Open-WebUI (prefer direct venv executable)
$webUiExe = Join-Path $scriptDir "venv\Scripts\open-webui.exe"
if (Test-Path $webUiExe) {
    $webUiCmd = "Set-Location '$scriptDir'; & '$webUiExe' serve --host 0.0.0.0 --port $WebUiPort"
} else {
    $webUiCmd = "Set-Location '$scriptDir'; .\\venv\\Scripts\\Activate.ps1; open-webui serve --host 0.0.0.0 --port $WebUiPort"
}
Start-Process powershell -ArgumentList "-NoExit", "-Command", $webUiCmd -WindowStyle $windowStyle | Out-Null
Write-Host "[Stack] Open-WebUI window started." -ForegroundColor Green

# Give servers a moment to initialize before health checks
Start-Sleep -Seconds 3

# 4) Wait for services
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$startTime = Get-Date
$apiOk = $false
$uiOk = $false
$checkCount = 0

Write-Host "[Stack] Waiting for services to become ready (timeout: ${TimeoutSeconds}s)..." -ForegroundColor Yellow
while ((Get-Date) -lt $deadline) {
    $checkCount++
    
    if (-not $apiOk) {
        if (Test-TcpPort -Hostname "127.0.0.1" -Port $ApiPort -TimeoutMs 500) {
            $apiOk = $true
            Write-Host "[Stack] API port is open at http://localhost:$ApiPort" -ForegroundColor Green
            # Non-fatal health probe for diagnostics only.
            try {
                Invoke-RestMethod -Uri "http://localhost:$ApiPort/health" -TimeoutSec 3 -ErrorAction Stop | Out-Null
                Write-Host "[Stack] API health endpoint responded." -ForegroundColor Green
            } catch {
                Write-Host "[Stack] API port is open, but /health is still warming up." -ForegroundColor DarkYellow
            }
        } else {
            if ($checkCount -eq 1 -or $checkCount % 10 -eq 0) {
                $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds)
                Write-Host "[Stack] Still waiting for API... (${elapsed}s elapsed)" -ForegroundColor DarkYellow
            }
        }
    }

    if (-not $uiOk) {
        if (Test-TcpPort -Hostname "127.0.0.1" -Port $WebUiPort -TimeoutMs 500) {
            $uiOk = $true
            Write-Host "[Stack] Open-WebUI port is open at http://localhost:$WebUiPort" -ForegroundColor Green
        } else {
            if ($checkCount -eq 1 -or ($checkCount % 10 -eq 0 -and $apiOk)) {
                Write-Host "[Stack] API ready, waiting for WebUI..." -ForegroundColor DarkYellow
            }
        }
    }

    if ($apiOk -and $uiOk) { break }
    Start-Sleep -Milliseconds 750
}

# 5) Open browser (best effort, try multiple methods)
if ($apiOk -and $uiOk) {
    $url = "http://localhost:$WebUiPort"
    Write-Host "[Stack] Opening browser: $url" -ForegroundColor Cyan
    
    $opened = $false
    
    # Method 1: cmd.exe start (most reliable on Windows)
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = "cmd.exe"
        $startInfo.Arguments = "/c start `"Browser`" `"$url`""
        $startInfo.CreateNoWindow = $true
        $startInfo.UseShellExecute = $false
        [System.Diagnostics.Process]::Start($startInfo) | Out-Null
        $opened = $true
        Write-Host "[Stack] Browser opened (method: cmd)" -ForegroundColor Green
    } catch {
        Write-Host "[Stack] Method 1 failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
    
    # Method 2: Direct Start-Process if method 1 failed
    if (-not $opened) {
        try {
            Start-Process $url -ErrorAction Stop
            $opened = $true
            Write-Host "[Stack] Browser opened (method: Start-Process)" -ForegroundColor Green
        } catch {
            Write-Host "[Stack] Method 2 failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
    
    # Method 3: explorer.exe as last resort
    if (-not $opened) {
        try {
            Start-Process "explorer.exe" -ArgumentList $url -ErrorAction Stop
            $opened = $true
            Write-Host "[Stack] Browser opened (method: explorer)" -ForegroundColor Green
        } catch {
            Write-Host "[Stack] Method 3 failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
    
    if (-not $opened) {
        Write-Host "[Stack] Could not auto-open browser." -ForegroundColor Yellow
        Write-Host "[Stack] Please open manually: $url" -ForegroundColor Yellow
    }
    
    Start-Sleep -Milliseconds 1000

    Write-Host "`n[Stack] Ready." -ForegroundColor Green
    Write-Host "Open-WebUI: $url"
    Write-Host "Tip: Use HTTP here (not HTTPS): $url"
    Write-Host "API base URL for Open-WebUI: http://localhost:$ApiPort/v1"
    Write-Host "If backend loading fails on startup, try: -BackendArgs @('--device','NPU')"
    Write-Host "If login screen appears, create a local account first."
} else {
    Write-Host "`n[Stack] Timed out waiting for readiness." -ForegroundColor Red
    Write-Host "API ready: $apiOk | WebUI ready: $uiOk"
    Write-Host "Check the two PowerShell windows for startup errors."
    exit 1
}
