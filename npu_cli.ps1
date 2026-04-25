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
    [string]$Prompt  = "",
    [string]$Command = "",
    [string[]]$Arguments = @()
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

function Test-ConnectionFailure {
    param($Exception)
    $t = "$Exception"
    if ($Exception.Exception -and $Exception.Exception.Message) {
        $t += " " + $Exception.Exception.Message
    }
    return $t -match '(?i)unable to connect|actively refused|connection refused|timed out|no connection|could not establish|target machine|remote name|name could not be resolved'
}

function Write-BackendUnreachableHint {
    Write-Dim "  Hint: Nothing is listening at $ApiBase (or it is still starting). If you switched model/backend"
    Write-Dim "  in the browser, wait ~5–10s and try again. Otherwise run .\start_app.ps1 or check the PowerShell"
    Write-Dim "  window running run.ps1 for errors (bad entrypoint, crash on load, or wrong port)."
}

function Get-ScriptDir {
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
        return Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    return (Get-Location).ProviderPath
}

function Read-JsonFile {
    param(
        [string]$Path,
        [object]$Default = $null
    )
    if (-not (Test-Path $Path)) {
        return $Default
    }
    try {
        return Get-Content -Path $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $Default
    }
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Data
    )
    $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
}

function Download-Model {
    param(
        [string]$Repo,
        [string]$ModelId,
        [string]$FileName = ""
    )

    if ([string]::IsNullOrWhiteSpace($Repo)) {
        throw "Model repo is required for download"
    }
    if ([string]::IsNullOrWhiteSpace($ModelId)) {
        $ModelId = ($Repo -split "/")[-1]
    }

    $scriptDir = Get-ScriptDir
    $modelsRoot = Join-Path $scriptDir "models"
    $target = Join-Path $modelsRoot $ModelId
    if (-not (Test-Path $target)) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($FileName)) {
        Write-Host "Downloading model '$Repo' into '$target'..." -ForegroundColor Cyan
    } else {
        Write-Host "Downloading model file '$FileName' from '$Repo' into '$target'..." -ForegroundColor Cyan
    }

    $hfCmd = Get-Command hf -ErrorAction SilentlyContinue
    if ($hfCmd) {
        $env:PYTHONIOENCODING = 'utf-8'
        if ([string]::IsNullOrWhiteSpace($FileName)) {
            & $hfCmd.Source download $Repo --local-dir "$target"
        } else {
            & $hfCmd.Source download $Repo $FileName --local-dir "$target"
        }
        if ($LASTEXITCODE -ne 0) {
            throw "hf download failed with exit code $LASTEXITCODE"
        }
        return $ModelId
    }

    $hfCli = Get-Command huggingface-cli -ErrorAction SilentlyContinue
    if ($hfCli) {
        $env:PYTHONIOENCODING = 'utf-8'
        if ([string]::IsNullOrWhiteSpace($FileName)) {
            & $hfCli.Source download $Repo --local-dir "$target"
        } else {
            & $hfCli.Source download $Repo $FileName --local-dir "$target"
        }
        if ($LASTEXITCODE -ne 0) {
            throw "huggingface-cli download failed with exit code $LASTEXITCODE"
        }
        return $ModelId
    }

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCmd) {
        throw "Neither huggingface-cli nor git is available. Install one of them to download model files."
    }

    if (Test-Path (Join-Path $target ".git")) {
        Push-Location $target
        try {
            git pull
            if ($LASTEXITCODE -ne 0) {
                throw "git pull failed with exit code $LASTEXITCODE"
            }
        } finally {
            Pop-Location
        }
    } else {
        if (Test-Path $target) {
            Remove-Item -Recurse -Force $target
        }
        git clone "https://huggingface.co/$Repo" $target
        if ($LASTEXITCODE -ne 0) {
            throw "git clone failed with exit code $LASTEXITCODE"
        }
    }

    return $ModelId
}

function Process-Command {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    switch ($Command.ToLower()) {
        "model" {
            if ($Arguments.Count -lt 1) {
                Write-Err "model command requires a subcommand: download, list, import, select, rename"
                return 1
            }
            $sub = $Arguments[0].ToLower()
            switch ($sub) {
                "download" {
                    if ($Arguments.Count -lt 2) {
                        Write-Err "Usage: -Command model -Arguments \"download\",\"<huggingface_repo>\",\"<local-id>\",\"[filename]\""
                        Write-Err "  filename is optional - if omitted, all files are downloaded"
                        return 1
                    }
                    $repo = $Arguments[1]
                    $id = if ($Arguments.Count -ge 3) { $Arguments[2] } else { "" }
                    $file = if ($Arguments.Count -ge 4) { $Arguments[3] } else { "" }
                    $downloadedId = Download-Model -Repo $repo -ModelId $id -FileName $file
                    Write-Success "Downloaded model '$repo' to './models/$downloadedId'"
                    return 0
                }
                "list" {
                    $scriptDir = Get-ScriptDir
                    $modelsPath = Join-Path $scriptDir "registry\models_registry.json"
                    $registry = Read-JsonFile -Path $modelsPath -Default ([ordered]@{ models = @(); selected_model = "" })
                    foreach ($model in $registry.models) {
                        Write-Host "$($model.id) -> $($model.path) ($($model.format))"
                    }
                    return 0
                }
                "rename" {
                    if ($Arguments.Count -lt 3) {
                        Write-Err "Usage: -Command model -Arguments \"rename\",\"<from-id>\",\"<to-id>\""
                        return 1
                    }
                    try {
                        $resp = Invoke-Api "/v1/cli/model/rename" -Method "POST" -Body @{
                            from_id = $Arguments[1].Trim()
                            to_id   = $Arguments[2].Trim()
                        }
                        Write-Success "Renamed model id '$($resp.from_id)' -> '$($resp.to_id)'"
                        if ($resp.note) { Write-Info $resp.note }
                        return 0
                    } catch {
                        Write-Err (Get-ApiErrorMessage -Exception $_)
                        return 1
                    }
                }
                default {
                    Write-Err "Unknown model subcommand '$sub'"
                    return 1
                }
            }
        }
        default {
            Write-Err "Unknown command '$Command'"
            return 1
        }
    }
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

if (-not [string]::IsNullOrWhiteSpace($Command)) {
    if ($Command.Trim().ToLower() -eq "chat") {
        if ($Arguments.Count -ge 1 -and [string]::IsNullOrWhiteSpace($Prompt)) {
            $Prompt = ($Arguments -join " ").Trim()
        }
        $Command = ""
    } else {
    $exitCode = Process-Command -Command $Command -Arguments $Arguments
    exit $exitCode
    }
}

# ---------------------------------------------------------------------------
# Status banner shown at startup
# ---------------------------------------------------------------------------

function Show-RuntimeBanner {
    $s = $null
    for ($i = 0; $i -lt 6; $i++) {
        try {
            $s = Invoke-Api "/v1/cli/status"
            break
        } catch {
            Start-Sleep -Milliseconds 350
        }
    }

    if ($null -eq $s) {
        Write-Dim  "  Runtime  :  starting... (chat will work as soon as backend is ready)"
        Write-Dim  "  Control  :  http://localhost:5173"
        Write-Info ""
        return
    }

    $device = if ($s.active_device)  { $s.active_device }  else { "?" }
    $policy = if ($s.policy)         { $s.policy }         else { "?" }
    $model  = if ($s.selected_model) { $s.selected_model } else { "?" }
    $loaded = if ($s.devices)        { $s.devices -join ", " } else { "-" }
    Write-Info ""
    Write-Info "  Runtime  :  $device  |  $policy  |  $model"
    Write-Info "  Loaded   :  $loaded"
    Write-Info "  Control  :  http://localhost:5173"
    Write-Info ""
    Write-Dim  "  Type your message and press Enter. Type '/exit' to quit."
    Write-Dim  "  Type '/status' to see current device / model / metrics."
    Write-Info ""
}

# ---------------------------------------------------------------------------
# AcouLM splash (shown when chat starts)
# ---------------------------------------------------------------------------

function Show-AcouLMSplash {
    $art = @(
        "  _      ___   ___   __  __ ___ ___ ",
        " | |    / _ \ / _ \ |  \/  |_ _/ __|",
        " | |__ | (_) | (_) || |\/| || |\__ \",
        " |____| \___/ \___/ |_|  |_|___|___/"
    )
    Write-Host ""
    foreach ($line in $art) {
        Write-Host $line -ForegroundColor Magenta
    }
    Write-Host "  (^-^) AcouLM local chat is ready" -ForegroundColor DarkMagenta
    Write-Host ""
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
        if (Test-ConnectionFailure -Exception $_) {
            Write-Host ""
            Write-BackendUnreachableHint
        }
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
    $command = $Input.Trim().ToLower().TrimStart([char[]]('/','\'))

    switch ($command) {
        "status" {
            try {
                $s = Invoke-Api "/v1/cli/status"
                $device = if ($s.active_device) { $s.active_device } else { "-" }
                $policy = if ($s.policy) { $s.policy } else { "-" }
                $model  = if ($s.selected_model) { $s.selected_model } else { "-" }
                Write-Info "status: device=$device policy=$policy model=$model"
            } catch {
                Write-Err "Could not reach backend."
                Write-BackendUnreachableHint
            }
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

    Show-AcouLMSplash
    Write-Info "Chat"
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
        $command = $line.Trim().ToLower().TrimStart([char[]]('/','\'))
        if ($command -eq "exit") { break }

        if (-not (Handle-InlineCommand -Input $line)) {
            Send-ChatMessage -UserPrompt $line
        }
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

Start-ChatLoop -InitialPrompt $Prompt
