#requires -Version 5.0
param(
    [string]$ApiBase = "http://localhost:8000",
    [string]$ModelPath = "./models/Qwen2.5-0.5B-Instruct",
    [int]$ApiPort = 8000,
    [int]$AppPort = 5173,
    [switch]$RequireMultiDevice
)

$ErrorActionPreference = "Stop"

$script:Errors = 0
$script:Warnings = 0

function Write-Ok {
    param([string]$Message)
    Write-Host "OK: $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "WARN: $Message" -ForegroundColor Yellow
    $script:Warnings++
}

function Write-Fail {
    param([string]$Message)
    Write-Host "FAIL: $Message" -ForegroundColor Red
    $script:Errors++
}

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

function Invoke-ApiJson {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [object]$Body = $null,
        [int]$TimeoutSec = 15
    )

    $params = @{
        Uri         = "$ApiBase$Endpoint"
        Method      = $Method
        TimeoutSec  = $TimeoutSec
        ErrorAction = "Stop"
    }

    if ($null -ne $Body) {
        $params.ContentType = "application/json"
        $params.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
    }

    Invoke-RestMethod @params
}

Write-Host "Running preflight check against $ApiBase" -ForegroundColor Cyan

# Local prerequisites
if (Test-Path $ModelPath) {
    Write-Ok "Model path exists: $ModelPath"
} else {
    Write-Fail "Model path missing: $ModelPath"
}

$registryModels = "./registry/models_registry.json"
$registryBackends = "./registry/backends_registry.json"

if (Test-Path $registryModels) {
    Write-Ok "Found model registry: $registryModels"
} else {
    Write-Warn "Model registry missing: $registryModels"
}

if (Test-Path $registryBackends) {
    Write-Ok "Found backend registry: $registryBackends"
} else {
    Write-Warn "Backend registry missing: $registryBackends"
}

# Service ports
if (Test-TcpPort -Hostname "127.0.0.1" -Port $ApiPort) {
    Write-Ok "API port open: $ApiPort"
} else {
    Write-Fail "API port closed: $ApiPort"
}

if (Test-TcpPort -Hostname "127.0.0.1" -Port $AppPort) {
    Write-Ok "App shell port open: $AppPort"
} else {
    Write-Warn "App shell port closed: $AppPort"
}

# API checks
$status = $null
try {
    $health = Invoke-ApiJson -Endpoint "/v1/health"
    if ($health.status -eq "healthy") {
        Write-Ok "Health endpoint is healthy (backend=$($health.backend))"
    } else {
        Write-Fail "Health endpoint returned status '$($health.status)'"
    }
} catch {
    Write-Fail "Health endpoint failed: $($_.Exception.Message)"
}

try {
    $status = Invoke-ApiJson -Endpoint "/v1/cli/status"
    Write-Ok "CLI status endpoint reachable"
    Write-Host "  policy=$($status.policy) active_device=$($status.active_device) selected_model=$($status.selected_model) selected_backend=$($status.selected_backend)"
} catch {
    Write-Fail "CLI status endpoint failed: $($_.Exception.Message)"
}

if ($null -ne $status) {
    $devices = @()
    if ($status.devices -is [System.Array]) {
        $devices = $status.devices
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$status.devices)) {
        $devices = @($status.devices)
    } elseif ($status.loaded_devices -is [System.Array]) {
        $devices = $status.loaded_devices
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$status.loaded_devices)) {
        $devices = @($status.loaded_devices)
    }

    $deviceCount = $devices.Count
    if ($deviceCount -ge 2) {
        Write-Ok "Multi-device loaded ($deviceCount): $($devices -join ', ')"
    } else {
        $msg = "Single-device mode detected ($deviceCount loaded). split-prefill enable will return insufficient_devices."
        if ($RequireMultiDevice) {
            Write-Fail $msg
        } else {
            Write-Warn $msg
        }
    }
}

Write-Host ""
Write-Host "Preflight summary: errors=$script:Errors warnings=$script:Warnings" -ForegroundColor Cyan
if ($script:Errors -gt 0) {
    exit 1
}
exit 0
