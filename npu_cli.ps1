#requires -Version 5.0
<#
.SYNOPSIS
    Terminal chat interface for the NPU backend.

.DESCRIPTION
    Chat with your local AI model from the terminal.
    Use the browser control panel (http://localhost:5173) to change
    devices, policies, models, and features.

.EXAMPLE
    .\npu_cli.ps1                              # interactive chat (default)
    .\npu_cli.ps1 -Prompt "What is OpenVINO?"  # single prompt, then continues loop
#>

param(
    [string]$ApiBase = "http://localhost:8000",
    [string]$Prompt  = ""
)

$ErrorActionPreference = "Continue"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Success { param([string]$M) Write-Host $M -ForegroundColor Green }
function Write-Info    { param([string]$M) Write-Host $M -ForegroundColor Cyan  }
function Write-Dim     { param([string]$M) Write-Host $M -ForegroundColor DarkGray }
function Write-Err     { param([string]$M) Write-Host "Error: $M" -ForegroundColor Red }

function Get-ApiErrorMessage {
    param($Exception)
    try {
        $stream = $Exception.Exception.Response.GetResponseStream()
        if ($null -eq $stream) { return "$Exception" }
        $body = [System.IO.StreamReader]::new($stream).ReadToEnd()
        $parsed = $body | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($parsed.error.message) { return $parsed.error.message }
        if ($parsed.error -is [string]) { return $parsed.error }
        if ($body) { return $body }
    } catch {}
    return "$Exception"
}

function Invoke-Api {
    param(
        [string]$Path,
        [string]$Method = "GET",
        [object]$Body   = $null
    )
    $url = "$ApiBase$Path"
    $params = @{ Uri = $url; Method = $Method; TimeoutSec = 30; ErrorAction = "Stop" }
    if ($null -ne $Body) {
        $params.Headers = @{ "Content-Type" = "application/json" }
        $params.Body    = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 8 -Compress }
    }
    return Invoke-RestMethod @params
}

# ---------------------------------------------------------------------------
# Status banner shown at startup
# ---------------------------------------------------------------------------

function Show-RuntimeBanner {
    try {
        $s = Invoke-Api "/v1/cli/status"
        $device = if ($s.active_device)  { $s.active_device }  else { "?" }
        $policy = if ($s.policy)         { $s.policy }         else { "?" }
        $model  = if ($s.selected_model) { $s.selected_model } else { "?" }
        $loaded = if ($s.devices)        { $s.devices -join ", " } else { "-" }
        Write-Info ""
        Write-Info "  Runtime  :  $device  |  $policy  |  $model"
        Write-Info "  Loaded   :  $loaded"
        Write-Info "  Control  :  http://localhost:5173"
        Write-Info ""
        Write-Dim  "  Type your message and press Enter. Type 'exit' to quit."
        Write-Dim  "  Type 'status' to see current device / model / metrics."
        Write-Info ""
    } catch {
        Write-Dim "  (backend not reachable — start with .\start_app.ps1)"
        Write-Info ""
    }
}

# ---------------------------------------------------------------------------
# Metrics block printed after every response
# ---------------------------------------------------------------------------

function Show-MetricsBlock {
    try {
        $s = Invoke-Api "/v1/cli/status"
    } catch { return }

    $device  = if ($s.active_device)  { $s.active_device }  else { "-" }
    $policy  = if ($s.policy)         { $s.policy }         else { "-" }
    $model   = if ($s.selected_model) { $s.selected_model } else { "-" }

    $ttft    = if ($s.ttft_ms    -and [double]$s.ttft_ms    -gt 0) { "{0:N1}ms"     -f [double]$s.ttft_ms }    else { "-" }
    $tpot    = if ($s.tpot_ms    -and [double]$s.tpot_ms    -gt 0) { "{0:N2}ms/tok" -f [double]$s.tpot_ms }   else { "-" }
    $tps     = if ($s.throughput -and [double]$s.throughput -gt 0) { "{0:N1}t/s"    -f [double]$s.throughput } else { "-" }

    $latency = "-"
    try {
        $m = Invoke-Api "/v1/cli/metrics?mode=last"
        if ($m.total_ms -and [double]$m.total_ms -gt 0) {
            $latency = "{0:N0}ms" -f [double]$m.total_ms
        }
    } catch {}

    $ram = "-"
    try {
        $mem = Invoke-Api "/v1/cli/memory"
        $used  = [double]($mem.ram.used_mb)
        $total = [double]($mem.ram.total_mb)
        if ($used -gt 0) {
            $ram = if ($total -gt 0) { "{0:N0}/{1:N0}MB" -f $used, $total } else { "{0:N0}MB" -f $used }
        }
    } catch {}

    Write-Dim  "  $device · $policy · $model  |  TTFT $ttft  TPOT $tpot  TPS $tps  Latency $latency  RAM $ram"
}

# ---------------------------------------------------------------------------
# Core chat call
# ---------------------------------------------------------------------------

function Send-ChatMessage {
    param([string]$UserPrompt)

    $modelId = "openvino"
    try {
        $s = Invoke-Api "/v1/cli/status"
        if ($s.selected_model) { $modelId = $s.selected_model }
    } catch {}

    $body = @{
        model       = $modelId
        messages    = @(@{ role = "user"; content = $UserPrompt })
        stream      = $false
        temperature = 0.7
        max_tokens  = 512
    }

    try {
        $resp = Invoke-RestMethod `
            -Uri        "$ApiBase/v1/chat/completions" `
            -Method     Post `
            -Headers    @{ "Content-Type" = "application/json"; "x-npu-cli" = "true" } `
            -Body       ($body | ConvertTo-Json -Depth 8 -Compress) `
            -TimeoutSec 120 `
            -ErrorAction Stop

        $content = $resp.choices[0].message.content
        Write-Host ""
        Write-Host $content
    } catch {
        Write-Err (Get-ApiErrorMessage -Exception $_)
        Write-Host ""
        return
    }

    Show-MetricsBlock
}

# ---------------------------------------------------------------------------
# Inline commands recognised during a chat session
# ---------------------------------------------------------------------------

function Handle-InlineCommand {
    param([string]$Input)
    switch ($Input.Trim().ToLower()) {
        "status" {
            try {
                $s = Invoke-Api "/v1/cli/status"
                Write-Info ""
                Write-Info "  Device   :  $($s.active_device)"
                Write-Info "  Policy   :  $($s.policy)"
                Write-Info "  Model    :  $($s.selected_model)"
                Write-Info "  Loaded   :  $($s.devices -join ', ')"
                if ($s.ttft_ms     -and [double]$s.ttft_ms     -gt 0) { Write-Info "  TTFT     :  $($s.ttft_ms) ms" }
                if ($s.throughput  -and [double]$s.throughput  -gt 0) { Write-Info "  TPS      :  $($s.throughput) tok/s" }
                Write-Info ""
                Write-Dim  "  Change device / policy / model at http://localhost:5173"
                Write-Info ""
            } catch { Write-Err "Could not reach backend." }
            return $true
        }
        "help" {
            Write-Info ""
            Write-Dim  "  Just type to chat. Special words:"
            Write-Dim  "    status  — current device, policy, model, metrics"
            Write-Dim  "    exit    — quit"
            Write-Dim  "  All other settings live in the browser control panel."
            Write-Info ""
            return $true
        }
        default { return $false }
    }
}

# ---------------------------------------------------------------------------
# Interactive loop
# ---------------------------------------------------------------------------

function Start-ChatLoop {
    param([string]$InitialPrompt = "")

    Write-Info "NPU Chat"
    Show-RuntimeBanner

    # If a prompt was passed on the command line, send it first
    if (-not [string]::IsNullOrWhiteSpace($InitialPrompt)) {
        Write-Host "You: $InitialPrompt"
        Send-ChatMessage -UserPrompt $InitialPrompt
    }

    while ($true) {
        try {
            $line = Read-Host "You"
        } catch {
            break
        }

        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.Trim().ToLower() -eq "exit") { break }

        if (-not (Handle-InlineCommand -Input $line)) {
            Send-ChatMessage -UserPrompt $line
        }
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

Start-ChatLoop -InitialPrompt $Prompt
