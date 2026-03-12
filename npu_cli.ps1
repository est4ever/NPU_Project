#requires -Version 5.0
<#
.SYNOPSIS
    CLI tool for controlling NPU backend model performance, device configuration, and status monitoring.
    The chat interface should be used only for actual conversations - all control commands go through this terminal tool.

.DESCRIPTION
    Provides terminal-based commands for:
    - Device management (switch, list devices)
    - Scheduling policies (PERFORMANCE, BATTERY_SAVER, BALANCED)
    - Feature toggles (split-prefill, context-routing, optimize-memory)
    - Performance monitoring (stats, metrics, benchmarks)
    - Server health checks

.EXAMPLE
    .\npu_cli.ps1 -Command status
    .\npu_cli.ps1 -Command switch -Arguments "GPU"
    .\npu_cli.ps1 -Command policy -Arguments "PERFORMANCE"
    .\npu_cli.ps1 -Command metrics -Arguments "last"
#>

param(
    [string]$ApiBase = "http://localhost:8000",
    [string]$Command,
    [string[]]$Arguments = @()
)

$ErrorActionPreference = "Stop"

# Color output functions for terminal readability
function Write-Success {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Green
}

function Write-NpuError {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
}

# Helper to make API calls
function Invoke-NpuApiCommand {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [object]$Body = $null
    )
    
    try {
        $url = "$ApiBase$Endpoint"
        $params = @{
            Uri             = $url
            Method          = $Method
            TimeoutSec      = 10
            ErrorAction     = "Stop"
        }
        
        if ($null -ne $Body) {
            $params.Headers = @{ "Content-Type" = "application/json" }
            if ($Body -is [string]) {
                $params.Body = $Body
            } else {
                $params.Body = $Body | ConvertTo-Json -Compress
            }
        }
        
        $response = Invoke-RestMethod @params
        return $response
    } catch {
        throw "API call failed to $url : $_"
    }
}

# Command implementations
function Show-NpuHelp {
        $lines = @(
                "NPU CLI - Model Control Interface",
                "Available Commands:",
                "",
                "INFORMATIONAL:",
                "  help              - Show this help message",
                "  status            - Show all current settings and performance stats",
                "  health            - Quick server/backend health check",
                "  model             - Model manager (list/import/select/download)",
                "  backend           - Backend manager (list/add/select)",
                "  devices           - List loaded devices and active device",
                "  stats             - Show performance metrics (TTFT, TPOT, throughput)",
                "  metrics [MODE]    - Show metrics (modes: last, summary, clear)",
                "",
                "DEVICE MANAGEMENT:",
                "  switch DEVICE     - Switch active device (CPU|GPU|NPU)",
                "  policy POLICY     - Set scheduling policy (PERFORMANCE|BATTERY_SAVER|BALANCED)",
                "",
                "FEATURE TOGGLES:",
                "  json on|off       - Toggle JSON metrics output",
                "  split-prefill on|off   - Toggle split prefill/decode routing by device",
                "  context-routing on|off - Toggle context-aware device routing",
                "  optimize-memory on|off - Toggle INT8 KV-cache compression",
                "",
                "ADVANCED:",
                "  threshold N       - Set prefill token threshold (e.g.: threshold 50)",
                "  calibrate         - Start calibration (terminal mode)",
                "  benchmark         - Run benchmark (terminal mode)",
                "",
                "MODEL REGISTRY:",
                "  model list                                - List registered models",
                "  model import <id> <path> [format]         - Register model path",
                "  model select <id>                         - Select active model (next restart)",
                "  model download <hf_repo> [id]             - Download from Hugging Face then register",
                "",
                "BACKEND REGISTRY:",
                "  backend list                              - List registered backends",
                "  backend add <id> <type> <entrypoint>      - Register a backend",
                "  backend select <id>                       - Select active backend (next restart)",
                "",
                "NOTES:",
                "  - Commands take effect immediately, no restart needed",
                "  - Chat interface is for conversations only",
                "  - Use this CLI for all system configuration",
                "  - For subcommands, pass arrays: -Arguments @(""import"",""id"",""path"",""openvino"")",
                "",
                "Example Usage:",
                "  .\\npu_cli.ps1 -Command status                    # View current configuration",
                "  .\\npu_cli.ps1 -Command switch -Arguments ""GPU""   # Switch to GPU device",
                "  .\\npu_cli.ps1 -Command metrics -Arguments ""last"" # View latest metrics",
                "  .\\npu_cli.ps1 -Command model -Arguments ""list""   # Show model registry",
                "  .\\npu_cli.ps1 -Command model -Arguments @(""import"",""qwen-local"",""./models/Qwen2.5-0.5B-Instruct"",""openvino"")",
                "  .\\npu_cli.ps1 -Command backend -Arguments ""list"" # Show backend registry"
        )

        $lines | ForEach-Object { Write-Host $_ }
}

function Show-NpuModelRegistry {
    try {
        $response = Invoke-NpuApiCommand -Endpoint "/v1/cli/model/list"
        Write-Info "=== Model Registry ==="
        Write-Host "Selected Model: $($response.selected_model)"
        if (-not $response.models -or $response.models.Count -eq 0) {
            Write-Host "No models registered."
            return
        }
        foreach ($model in $response.models) {
            $active = if ($model.id -eq $response.selected_model) { " (selected)" } else { "" }
            Write-Host "- $($model.id)$active"
            Write-Host "  path: $($model.path)"
            Write-Host "  format: $($model.format) | backend: $($model.backend) | status: $($model.status)"
        }
    } catch {
        Write-NpuError $_
        exit 1
    }
}

function Import-NpuModel {
    param(
        [string]$Id,
        [string]$Path,
        [string]$Format = "openvino"
    )

    if (-not $Id -or -not $Path) {
        Write-NpuError "Usage: model import <id> <path> [format]"
        exit 1
    }

    try {
        $body = @{
            id = $Id
            path = $Path
            format = $Format
            backend = "openvino"
            status = "ready"
        }
        $response = Invoke-NpuApiCommand -Endpoint "/v1/cli/model/import" -Method "POST" -Body $body
        Write-Success "Model registered: $($response.id)"
        Write-Host "$($response.note)"
    } catch {
        Write-NpuError $_
        exit 1
    }
}

function Select-NpuModel {
    param([string]$Id)

    if (-not $Id) {
        Write-NpuError "Usage: model select <id>"
        exit 1
    }

    try {
        $response = Invoke-NpuApiCommand -Endpoint "/v1/cli/model/select" -Method "POST" -Body @{ id = $Id }
        Write-Success "Selected model: $($response.selected_model)"
        Write-Host "$($response.note)"
    } catch {
        Write-NpuError $_
        exit 1
    }
}

function Get-NpuModelDownload {
    param(
        [string]$Repo,
        [string]$ModelId
    )

    if (-not $Repo) {
        Write-NpuError "Usage: model download <hf_repo> [id]"
        exit 1
    }

    $repoTail = ($Repo -split "/")[-1]
    if (-not $ModelId) {
        $ModelId = $repoTail
    }

    $targetDir = Join-Path (Get-Location) (Join-Path "models" $ModelId)
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    Write-Info "Downloading model '$Repo' into '$targetDir'..."

    try {
        $hfCli = Get-Command huggingface-cli -ErrorAction SilentlyContinue
        if ($hfCli) {
            & huggingface-cli download $Repo --local-dir $targetDir --local-dir-use-symlinks False | Out-Host
        } else {
            $gitCmd = Get-Command git -ErrorAction SilentlyContinue
            if (-not $gitCmd) {
                throw "Neither huggingface-cli nor git is available. Install one of them first."
            }
            if (Test-Path (Join-Path $targetDir ".git")) {
                Write-Info "Model folder is already a git repo. Pulling latest..."
                Push-Location $targetDir
                git pull | Out-Host
                Pop-Location
            } else {
                Remove-Item -Recurse -Force $targetDir
                git clone "https://huggingface.co/$Repo" $targetDir | Out-Host
            }
        }

        $format = if (Test-Path (Join-Path $targetDir "openvino_model.xml")) { "openvino" } else { "unknown" }
        Import-NpuModel -Id $ModelId -Path ("./models/" + $ModelId) -Format $format
        Write-Success "Download + import complete for model '$ModelId'."
    } catch {
        Write-NpuError $_
        exit 1
    }
}

function Show-NpuBackendRegistry {
    try {
        $response = Invoke-NpuApiCommand -Endpoint "/v1/cli/backend/list"
        Write-Info "=== Backend Registry ==="
        Write-Host "Selected Backend: $($response.selected_backend)"
        if (-not $response.backends -or $response.backends.Count -eq 0) {
            Write-Host "No backends registered."
            return
        }
        foreach ($backend in $response.backends) {
            $active = if ($backend.id -eq $response.selected_backend) { " (selected)" } else { "" }
            $formats = if ($backend.formats) { ($backend.formats -join ",") } else { "n/a" }
            Write-Host "- $($backend.id)$active"
            Write-Host "  type: $($backend.type) | entrypoint: $($backend.entrypoint)"
            Write-Host "  formats: $formats | status: $($backend.status)"
        }
    } catch {
        Write-NpuError $_
        exit 1
    }
}

function Add-NpuBackend {
    param(
        [string]$Id,
        [string]$Type,
        [string]$Entrypoint
    )

    if (-not $Id -or -not $Type -or -not $Entrypoint) {
        Write-NpuError "Usage: backend add <id> <type> <entrypoint>"
        exit 1
    }

    try {
        $body = @{
            id = $Id
            type = $Type
            entrypoint = $Entrypoint
            formats = @("openvino")
        }
        $response = Invoke-NpuApiCommand -Endpoint "/v1/cli/backend/add" -Method "POST" -Body $body
        Write-Success "Backend registered: $($response.id)"
    } catch {
        Write-NpuError $_
        exit 1
    }
}

function Select-NpuBackend {
    param([string]$Id)

    if (-not $Id) {
        Write-NpuError "Usage: backend select <id>"
        exit 1
    }

    try {
        $response = Invoke-NpuApiCommand -Endpoint "/v1/cli/backend/select" -Method "POST" -Body @{ id = $Id }
        Write-Success "Selected backend: $($response.selected_backend)"
        Write-Host "$($response.note)"
    } catch {
        Write-NpuError $_
        exit 1
    }
}

function Show-NpuInfo {
    param([string]$Type = "status")
    
    try {
        $response = Invoke-NpuApiCommand -Endpoint "/v1/cli/status"
        
        switch ($Type) {
            "status" {
                Write-Info "=== Current System Status ==="
                Write-Host "Policy: $($response.policy)"
                Write-Host "Active Device: $($response.active_device)"
                Write-Host "Loaded Devices: $($response.devices -join ', ')"
                Write-Host ""
                Write-Info "=== Feature Configuration ==="
                Write-Host "JSON Output: $($response.json_output)"
                Write-Host "Split-Prefill: $($response.split_prefill)"
                if ($response.split_prefill -eq "ON") {
                    Write-Host "  - Prefill Device: $($response.prefill_device)"
                    Write-Host "  - Decode Device: $($response.decode_device)"
                    Write-Host "  - Threshold: $($response.threshold) tokens"
                }
                Write-Host "Context-Routing: $($response.context_routing)"
                Write-Host "Optimize-Memory: $($response.optimize_memory)"
                if ($response.selected_model) {
                    Write-Host "Selected Model: $($response.selected_model)"
                }
                if ($response.selected_backend) {
                    Write-Host "Selected Backend: $($response.selected_backend)"
                }
                Write-Host ""
                Write-Info "=== Performance Metrics ==="
                Write-Host "TTFT: $($response.ttft_ms) ms"
                Write-Host "TPOT: $($response.tpot_ms) ms/token"
                Write-Host "Throughput: $($response.throughput) tokens/s"
            }
            "health" {
                Write-Info "=== Server Health ==="
                Write-Host "Status: $($response.status)"
                Write-Host "Active Backend: $($response.active_backend)"
                Write-Host "Loaded Devices: $($response.loaded_devices_count)"
                Write-Success "Server is healthy"
            }
            "stats" {
                Write-Info "=== Performance Statistics ==="
                Write-Host "Active Device: $($response.active_device)"
                Write-Host "TTFT (Time to First Token): $($response.ttft_ms) ms"
                Write-Host "TPOT (Time per Output Token): $($response.tpot_ms) ms/token"
                Write-Host "Throughput: $($response.throughput) tokens/s"
            }
            "devices" {
                Write-Info "=== Loaded Devices ==="
                foreach ($device in $response.devices) {
                    $marker = if ($device -eq $response.active_device) { " (active)" } else { "" }
                    Write-Host "- $device$marker"
                }
            }
            "model" {
                Write-Info "=== Model Information ==="
                Write-Host "Model ID: $($response.model_id)"
            }
        }
    } catch {
        Write-NpuError $_
        exit 1
    }
}

function Set-NpuDevice {
    param([string]$Device)
    
    if (-not $Device) {
        Write-NpuError "Device not specified. Use: switch CPU|GPU|NPU"
        exit 1
    }
    
    try {
        $body = @{ device = $Device.ToUpper() } | ConvertTo-Json
        $response = Invoke-NpuApiCommand -Endpoint "/v1/cli/device/switch" -Method "POST" -Body $body
        Write-Success "Switched to device: $($response.new_active_device)"
    } catch {
        Write-NpuError $_
        exit 1
    }
}

function Set-NpuPolicy {
    param([string]$PolicyName)
    
    if (-not $PolicyName) {
        Write-NpuError "Policy not specified. Use: policy PERFORMANCE|BATTERY_SAVER|BALANCED"
        exit 1
    }
    
    try {
        $body = @{ policy = $PolicyName.ToUpper() } | ConvertTo-Json
        $response = Invoke-NpuApiCommand -Endpoint "/v1/cli/policy" -Method "POST" -Body $body
        Write-Success "Policy set to: $($response.new_policy)"
    } catch {
        Write-NpuError $_
        exit 1
    }
}

function Set-NpuFeatureState {
    param(
        [string]$Feature,
        [string]$State
    )
    
    if (-not $State -or $State -notin @("on", "off")) {
        Write-NpuError "Usage: $Feature on|off"
        exit 1
    }
    
    try {
        $enabled = $State -eq "on"
        $body = @{ enabled = $enabled } | ConvertTo-Json
        Invoke-NpuApiCommand -Endpoint "/v1/cli/feature/$Feature" -Method "POST" -Body $body | Out-Null
        $status = if ($enabled) { "enabled" } else { "disabled" }
        Write-Success "$Feature $status"
    } catch {
        Write-NpuError $_
        exit 1
    }
}

function Set-NpuThreshold {
    param([int]$TokenCount)
    
    if ($TokenCount -le 0) {
        Write-NpuError "Threshold must be a positive number"
        exit 1
    }
    
    try {
        $body = @{ threshold = $TokenCount } | ConvertTo-Json
        $response = Invoke-NpuApiCommand -Endpoint "/v1/cli/threshold" -Method "POST" -Body $body
        Write-Success "Prefill threshold set to: $($response.new_threshold) tokens"
    } catch {
        Write-NpuError $_
        exit 1
    }
}

function Show-NpuMetrics {
    param([string]$Mode = "last")
    
    try {
        $response = Invoke-NpuApiCommand -Endpoint "/v1/cli/metrics?mode=$Mode"
        
        if ($Mode -eq "last") {
            Write-Info "=== Latest Metrics Record ==="
            Write-Host ($response | ConvertTo-Json)
        } elseif ($Mode -eq "summary") {
            Write-Info "=== Metrics Summary ==="
            Write-Host "Average TTFT: $($response.avg_ttft_ms) ms"
            Write-Host "Average TPOT: $($response.avg_tpot_ms) ms/token"
            Write-Host "Average Throughput: $($response.avg_throughput) tokens/s"
            Write-Host "Record Count: $($response.record_count)"
        } elseif ($Mode -eq "clear") {
            Write-Info "Metrics cleared"
        }
    } catch {
        Write-NpuError $_
        exit 1
    }
}

# Main command dispatch
function Invoke-NpuCommand {
    param(
        [string]$Cmd,
        [string[]]$ArgList
    )
    
    $cmd = $Cmd.ToLower()
    
    switch ($cmd) {
        # Informational commands
        "help" { Show-NpuHelp }
        "status" { Show-NpuInfo -Type "status" }
        "health" { Show-NpuInfo -Type "health" }
        "stats" { Show-NpuInfo -Type "stats" }
        "devices" { Show-NpuInfo -Type "devices" }
        "model" {
            if (-not $ArgList[0]) {
                Show-NpuModelRegistry
            } else {
                $sub = $ArgList[0].ToLower()
                switch ($sub) {
                    "list" { Show-NpuModelRegistry }
                    "import" { Import-NpuModel -Id $ArgList[1] -Path $ArgList[2] -Format $(if ($ArgList[3]) { $ArgList[3] } else { "openvino" }) }
                    "select" { Select-NpuModel -Id $ArgList[1] }
                    "download" { Get-NpuModelDownload -Repo $ArgList[1] -ModelId $ArgList[2] }
                    default {
                        Write-NpuError "Unknown model subcommand: $sub"
                        Write-Host "Use: model list|import|select|download"
                        exit 1
                    }
                }
            }
        }
        "backend" {
            if (-not $ArgList[0]) {
                Show-NpuBackendRegistry
            } else {
                $sub = $ArgList[0].ToLower()
                switch ($sub) {
                    "list" { Show-NpuBackendRegistry }
                    "add" { Add-NpuBackend -Id $ArgList[1] -Type $ArgList[2] -Entrypoint $ArgList[3] }
                    "select" { Select-NpuBackend -Id $ArgList[1] }
                    default {
                        Write-NpuError "Unknown backend subcommand: $sub"
                        Write-Host "Use: backend list|add|select"
                        exit 1
                    }
                }
            }
        }
        "memory" { Show-NpuInfo -Type "status" }  # Show memory from status endpoint
        
        # Device management
        "switch" { Set-NpuDevice -Device $ArgList[0] }
        "policy" { Set-NpuPolicy -PolicyName $ArgList[0] }
        
        # Feature toggles
        "json" { Set-NpuFeatureState -Feature "json" -State $ArgList[0] }
        "split-prefill" { Set-NpuFeatureState -Feature "split-prefill" -State $ArgList[0] }
        "context-routing" { Set-NpuFeatureState -Feature "context-routing" -State $ArgList[0] }
        "optimize-memory" { Set-NpuFeatureState -Feature "optimize-memory" -State $ArgList[0] }
        
        # Advanced
        "threshold" { 
            if ($ArgList[0] -and [int]::TryParse($ArgList[0], [ref]$null)) {
                Set-NpuThreshold -TokenCount $ArgList[0]
            } else {
                Write-NpuError "Threshold requires a numeric argument (e.g., 'threshold 50')"
                exit 1
            }
        }
        "metrics" { 
            $mode = if ($ArgList[0]) { $ArgList[0] } else { "last" }
            Show-NpuMetrics -Mode $mode
        }
        
        # Terminal-only commands (not from chat)
        "calibrate" {
            Write-Info "Calibration must be run in terminal mode with the backend."
            Write-Host "Use the backend directly for this operation."
        }
        "benchmark" {
            Write-Info "Benchmarking must be run in terminal mode with the backend."
            Write-Host "Use the backend directly for this operation."
        }
        
        default {
            Write-NpuError "Unknown command: $cmd"
            Write-Host ""
            Show-NpuHelp
            exit 1
        }
    }
}

# Entry point
if (-not $Command) {
    Show-NpuHelp
    exit 0
}

Invoke-NpuCommand -Cmd $Command -ArgList $Arguments



