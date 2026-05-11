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
    [string]$ApiBase = "http://127.0.0.1:8000",
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
    Write-Dim "  in the browser, wait ~5-10s and try again. Otherwise run .\start_app.ps1 or check the PowerShell"
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

function Test-GgufFileMagic {
    param([string]$Path)
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 4
            if ($fs.Read($buf, 0, 4) -lt 4) { return $false }
            return ($buf[0] -eq 0x47 -and $buf[1] -eq 0x47 -and $buf[2] -eq 0x55 -and $buf[3] -eq 0x46)
        } finally {
            $fs.Dispose()
        }
    } catch {
        return $false
    }
}

function Get-GgufMinBytesHint {
    param([string]$FileName)
    $n = ($FileName + "").ToLowerInvariant()
    # Rough lower bounds so truncated HTTP downloads are rejected (full Qwen2.5-3B Q4_K_M is ~1.9GB).
    if ($n -match 'qwen2\.5-3b.*q4_k_m') { return [long]1200000000 }
    if ($n -match 'qwen2\.5-3b') { return [long]500000000 }
    return [long]0
}

function Assert-GgufDownloadOk {
    param(
        [string]$DestFile,
        [string]$FileName
    )
    $len = (Get-Item -LiteralPath $DestFile).Length
    $fs = [System.IO.File]::OpenRead($DestFile)
    try {
        $head = New-Object byte[] ([Math]::Min(512, [int]$len))
        [void]$fs.Read($head, 0, $head.Length)
    } finally {
        $fs.Dispose()
    }
    if ($head.Length -ge 4 -and $head[0] -eq 0x3C) {
        throw "Download looks like HTML (login page or wrong URL). Install 'hf' from Hugging Face or check repo/filename."
    }
    if (-not (Test-GgufFileMagic -Path $DestFile)) {
        throw "File is not a valid GGUF (missing GGUF magic). Delete it and retry download."
    }
    $min = Get-GgufMinBytesHint -FileName $FileName
    if ($min -gt 0 -and $len -lt $min) {
        throw "GGUF looks incomplete ($len bytes; expected at least ~$min for this variant). Delete '$DestFile' and run download again with a stable connection."
    }
}

function Find-ExistingModelFile {
    param(
        [string]$ModelsRoot,
        [string]$TargetModelId,
        [string]$FileName
    )
    if ([string]::IsNullOrWhiteSpace($FileName) -or $FileName -eq "*") {
        return $null
    }
    if (-not (Test-Path -LiteralPath $ModelsRoot)) {
        return $null
    }
    $targetFolder = Join-Path $ModelsRoot $TargetModelId
    $targetResolved = [System.IO.Path]::GetFullPath($targetFolder).TrimEnd("\")
    try {
        $matches = Get-ChildItem -Path $ModelsRoot -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue
        foreach ($m in $matches) {
            $parentResolved = [System.IO.Path]::GetFullPath($m.DirectoryName).TrimEnd("\")
            if ($parentResolved -eq $targetResolved) {
                continue
            }
            if ($FileName -like "*.gguf") {
                try {
                    Assert-GgufDownloadOk -DestFile $m.FullName -FileName $FileName
                } catch {
                    continue
                }
            }
            $ownerId = Split-Path -Path $m.DirectoryName -Leaf
            if (-not [string]::IsNullOrWhiteSpace($ownerId)) {
                return [ordered]@{
                    model_id  = $ownerId
                    file_path = $m.FullName
                }
            }
        }
    } catch {}
    return $null
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
    $Repo = ($Repo + "").Trim().Trim("/")
    if ([string]::IsNullOrWhiteSpace($Repo)) {
        throw "Model repo cannot be empty after trimming. Use form: org/model"
    }
    if ($Repo -notmatch ".+/.+") {
        throw "Model repo must be in Hugging Face format 'org/model' (got '$Repo')"
    }
    if ([string]::IsNullOrWhiteSpace($ModelId)) {
        $ModelId = ($Repo -split "/")[-1]
    }
    $ModelId = ($ModelId + "").Trim()
    if ([string]::IsNullOrWhiteSpace($ModelId) -or $ModelId -in @(".", "..")) {
        throw "Refusing to use unsafe model id '$ModelId'. Provide a non-empty local id under .\models\."
    }
    if ($ModelId.Contains("\") -or $ModelId.Contains("/")) {
        throw "Model id must be a single folder name (no path separators): '$ModelId'"
    }

    $scriptDir = Get-ScriptDir
    $modelsRoot = Join-Path $scriptDir "models"
    $target = Join-Path $modelsRoot $ModelId
    $rootResolved = [System.IO.Path]::GetFullPath($modelsRoot).TrimEnd("\")
    $targetResolved = [System.IO.Path]::GetFullPath($target).TrimEnd("\")
    if ($targetResolved -eq $rootResolved) {
        throw "Refusing to use models root as target: $targetResolved"
    }

    if ([string]::IsNullOrWhiteSpace($FileName)) {
        throw "A filename is required so you pick one variant (not every quantization). Use: -Arguments ""download"",""<repo>"",""<local-id>"",""<filename>"" (or '*' for full repo). Example GGUF: ...,""Qwen2.5-3B-Instruct-Q4_K_M.gguf"""
    }
    if ($FileName -ne "*") {
        $existing = Find-ExistingModelFile -ModelsRoot $modelsRoot -TargetModelId $ModelId -FileName $FileName
        if ($null -ne $existing) {
            Write-Info "Reusing existing model file: $($existing.file_path)"
            Write-Dim  "  Skipping duplicate download. Existing local-id: $($existing.model_id)"
            return $existing.model_id
        }
    }
    if (-not (Test-Path $target)) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
    }
    if ($FileName -eq "*") {
        Write-Host "Downloading full repo '$Repo' into '$target' (explicit full snapshot)..." -ForegroundColor Cyan
    } else {
        Write-Host "Downloading model file '$FileName' from '$Repo' into '$target'..." -ForegroundColor Cyan
    }

    $hfCmd = Get-Command hf -ErrorAction SilentlyContinue
    if ($hfCmd) {
        $env:PYTHONIOENCODING = 'utf-8'
        if ($FileName -eq "*") {
            & $hfCmd.Source download $Repo --local-dir "$target"
        } else {
            & $hfCmd.Source download $Repo $FileName --local-dir "$target"
        }
        if ($LASTEXITCODE -ne 0) {
            throw "hf download failed with exit code $LASTEXITCODE"
        }
        if ($FileName -ne "*" -and ($FileName -like "*.gguf")) {
            $df = Join-Path $target $FileName
            if (Test-Path -LiteralPath $df) {
                Assert-GgufDownloadOk -DestFile $df -FileName $FileName
            }
        }
        return $ModelId
    }

    $hfCli = Get-Command huggingface-cli -ErrorAction SilentlyContinue
    if ($hfCli) {
        $env:PYTHONIOENCODING = 'utf-8'
        if ($FileName -eq "*") {
            & $hfCli.Source download $Repo --local-dir "$target"
        } else {
            & $hfCli.Source download $Repo $FileName --local-dir "$target"
        }
        if ($LASTEXITCODE -ne 0) {
            throw "huggingface-cli download failed with exit code $LASTEXITCODE"
        }
        if ($FileName -ne "*" -and ($FileName -like "*.gguf")) {
            $df = Join-Path $target $FileName
            if (Test-Path -LiteralPath $df) {
                Assert-GgufDownloadOk -DestFile $df -FileName $FileName
            }
        }
        return $ModelId
    }

    # Direct HTTPS: one file only (good when hf / huggingface-cli are not installed).
    if ($FileName -ne "*") {
        $destFile = Join-Path $target $FileName
        $needFetch = -not (Test-Path $destFile)
        if (-not $needFetch -and ($FileName -like "*.gguf")) {
            try {
                Assert-GgufDownloadOk -DestFile $destFile -FileName $FileName
            } catch {
                Write-Err $_.Exception.Message
                Remove-Item -LiteralPath $destFile -Force -ErrorAction SilentlyContinue
                $needFetch = $true
            }
        }
        if ($needFetch) {
            $resolveUrl = "https://huggingface.co/$Repo/resolve/main/$FileName"
            Write-Info "Trying direct download (single file): $resolveUrl"
            Write-Dim "  Large files may take several minutes..."
            try {
                if (-not (Test-Path $target)) {
                    New-Item -ItemType Directory -Path $target -Force | Out-Null
                }
                Invoke-WebRequest -Uri $resolveUrl -OutFile $destFile -UseBasicParsing -TimeoutSec 7200
                if (Test-Path $destFile) {
                    if ($FileName -like "*.gguf") {
                        Assert-GgufDownloadOk -DestFile $destFile -FileName $FileName
                    }
                    Write-Success "Downloaded to $destFile"
                    return $ModelId
                }
                Remove-Item -LiteralPath $destFile -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Dim "  Direct download failed (gated repo, timeout, or wrong file): $($_.Exception.Message)"
                Remove-Item -LiteralPath $destFile -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Success "Using existing file: $destFile"
            return $ModelId
        }
    }

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCmd) {
        throw "Install `hf` (pip install huggingface_hub) or Git + Git LFS, or use a public repo for direct download."
    }

    if (Test-Path (Join-Path $target ".git")) {
        Push-Location $target
        try {
            git pull
            if ($LASTEXITCODE -ne 0) {
                throw "git pull failed with exit code $LASTEXITCODE"
            }
            if ($FileName -ne "*") {
                git lfs pull --include "$FileName"
                if ($LASTEXITCODE -ne 0) {
                    throw "git lfs pull --include failed with exit code $LASTEXITCODE"
                }
            }
        } finally {
            Pop-Location
        }
    } else {
        if (Test-Path $target) {
            Remove-Item -Recurse -Force $target
        }
        $prevLfs = $env:GIT_LFS_SKIP_SMUDGE
        $env:GIT_LFS_SKIP_SMUDGE = "1"
        try {
            git clone "https://huggingface.co/$Repo" $target
            if ($LASTEXITCODE -ne 0) {
                throw "git clone failed with exit code $LASTEXITCODE"
            }
            if ($FileName -ne "*") {
                Push-Location $target
                try {
                    git lfs pull --include "$FileName"
                    if ($LASTEXITCODE -ne 0) {
                        throw "git lfs pull --include failed with exit code $LASTEXITCODE"
                    }
                } finally {
                    Pop-Location
                }
            }
        } finally {
            if ($null -eq $prevLfs) {
                Remove-Item Env:\GIT_LFS_SKIP_SMUDGE -ErrorAction SilentlyContinue
            } else {
                $env:GIT_LFS_SKIP_SMUDGE = $prevLfs
            }
        }
    }

    if ($FileName -ne "*") {
        $finalFile = Join-Path $target $FileName
        if (($FileName -like "*.gguf") -and (Test-Path -LiteralPath $finalFile)) {
            Assert-GgufDownloadOk -DestFile $finalFile -FileName $FileName
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
                    if ($Arguments.Count -lt 4) {
                        Write-Err "Usage: -Command model -Arguments \"download\",\"<huggingface_repo>\",\"<local-id>\",\"<filename>\""
                        Write-Err "  use filename='*' only if you explicitly want full repo download"
                        return 1
                    }
                    $repo = $Arguments[1]
                    $id = if ($Arguments.Count -ge 3) { $Arguments[2] } else { "" }
                    $file = if ($Arguments.Count -ge 4) { $Arguments[3] } else { "" }
                    $downloadedId = Download-Model -Repo $repo -ModelId $id -FileName $file
                    Write-Success "Model '$repo' available at './models/$downloadedId'"
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
    # ASCII-only frames so Windows consoles (e.g. code page 950) do not strip the "logo".
    $danceFrames = @(
        "[@_@] <|>",
        "[@_@] \\|/",
        "[@_@] <|>",
        "[@_@] /|\\"
    )
    $prefetchedStatus = $null

    $art = @(
        "      _    ____   ___   _   _  _      __  __ ",
        "     / \  / ___| / _ \ | | | || |    |  \/  |",
        "    / _ \| |    | | | || | | || |    | |\/| |",
        "   / ___ \ |___ | |_| || |_| || |___ | |  | |",
        "  /_/   \_\____| \___/  \___/ |_____||_|  |_|"
    )
    Write-Host ""

    # Keep robot dancing briefly while probing readiness, but do not block chat startup for minutes.
    $waitSec = 12
    try {
        $envWait = [string]$env:ACOULM_BACKEND_WAIT_SEC
        if (-not [string]::IsNullOrWhiteSpace($envWait)) {
            $parsed = 0
            if ([int]::TryParse($envWait.Trim(), [ref]$parsed) -and $parsed -gt 0) {
                $waitSec = $parsed
            }
        }
    } catch {}
    $deadline = (Get-Date).AddSeconds($waitSec)
    $minFrames = 10
    $maxFrames = [math]::Max($minFrames, [int]($waitSec * 5))
    $i = 0
    while ((Get-Date) -lt $deadline) {
        if (($i % 5) -eq 0) {
            try {
                $prefetchedStatus = Invoke-RestMethod -Uri "$ApiBase/v1/cli/status" -Method Get -TimeoutSec 2 -ErrorAction Stop
            } catch {}
        }
        $frame = $danceFrames[$i % $danceFrames.Count]
        Write-Host -NoNewline ("`r  AcouLM " + $frame + "  ")
        Start-Sleep -Milliseconds 200
        $i++
        if ($null -ne $prefetchedStatus -and $i -ge $minFrames) {
            break
        }
        if ($i -ge $maxFrames) {
            break
        }
    }

    # Erase dance line so it disappears after startup.
    Write-Host -NoNewline "`r"
    Write-Host -NoNewline (" " * 64)
    Write-Host "`r"

    foreach ($line in $art) {
        Write-Host $line -ForegroundColor Magenta
    }
    if ($null -ne $prefetchedStatus) {
        Write-Host "  [ready] chat is online" -ForegroundColor Magenta
    } else {
        Write-Host "  [starting] backend is warming up..." -ForegroundColor Magenta
    }
    Write-Host ""
    return $prefetchedStatus
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
        temperature = 0.3
        max_tokens  = 256
    }

    $sendOnce = {
        Invoke-RestMethod `
            -Uri        "$ApiBase/v1/chat/completions" `
            -Method     Post `
            -Headers    @{ "Content-Type" = "application/json"; "x-npu-cli" = "true" } `
            -Body       ($body | ConvertTo-Json -Depth 8 -Compress) `
            -TimeoutSec 120 `
            -ErrorAction Stop
    }

    try {
        $resp = & $sendOnce
        $content = $resp.choices[0].message.content
        Write-Host ""
        Write-Host $content
    } catch {
        if (Test-ConnectionFailure -Exception $_) {
            Write-Host ""
            Write-Dim "  Backend is still warming up - waiting up to 45s, then retrying once..."
            $deadline = (Get-Date).AddSeconds(45)
            $ready = $false
            while ((Get-Date) -lt $deadline) {
                try {
                    $null = Invoke-RestMethod -Uri "$ApiBase/v1/health" -Method Get -TimeoutSec 2 -ErrorAction Stop
                    $ready = $true
                    break
                } catch {}
                Start-Sleep -Milliseconds 1000
            }
            if ($ready) {
                try {
                    $resp = & $sendOnce
                    $content = $resp.choices[0].message.content
                    Write-Host ""
                    Write-Host $content
                } catch {
                    Write-Err (Get-ApiErrorMessage -Exception $_)
                    Write-Host ""
                    return
                }
            } else {
                Write-Err (Get-ApiErrorMessage -Exception $_)
                Write-Host ""
                Write-BackendUnreachableHint
                Write-Host ""
                return
            }
        } else {
            Write-Err (Get-ApiErrorMessage -Exception $_)
            Write-Host ""
            return
        }
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

    $prefetchedStatus = Show-AcouLMSplash
    Write-Info "Chat"
    if ($null -ne $prefetchedStatus) {
        $device = if ($prefetchedStatus.active_device)  { $prefetchedStatus.active_device }  else { "?" }
        $policy = if ($prefetchedStatus.policy)         { $prefetchedStatus.policy }         else { "?" }
        $model  = if ($prefetchedStatus.selected_model) { $prefetchedStatus.selected_model } else { "?" }
        $loaded = if ($prefetchedStatus.devices)        { $prefetchedStatus.devices -join ", " } else { "-" }
        Write-Info ""
        Write-Info "  Runtime  :  $device  |  $policy  |  $model"
        Write-Info "  Loaded   :  $loaded"
        Write-Info "  Control  :  http://localhost:5173"
        Write-Info ""
        Write-Dim  "  Type your message and press Enter. Type '/exit' to quit."
        Write-Dim  "  Type '/status' to see current device / model / metrics."
        Write-Info ""
    } else {
        Show-RuntimeBanner
    }

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
