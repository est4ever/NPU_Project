[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ApiBase = "http://127.0.0.1:8000",
    [string]$Prompt = "",
    [string]$Command = "",
    [string[]]$Arguments = @(),
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Passthrough
)

$ErrorActionPreference = "Stop"

function Test-IsAcouLMRoot {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
    $npu = Join-Path $Dir "npu_cli.ps1"
    $app = Join-Path $Dir "start_app.ps1"
    return ((Test-Path -LiteralPath $npu) -and (Test-Path -LiteralPath $app))
}

# Prefer the folder of this script (works for .\acoulm.ps1 and the path in %USERPROFILE%\.local\bin\acoulm.cmd).
# If you run a stray copy, fall back to user ACOULM_HOME (set by portable_setup).
$scriptDir = $null
if ($MyInvocation.MyCommand.Path) {
    $fromInvoke = [System.IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
    if (Test-IsAcouLMRoot -Dir $fromInvoke) {
        $scriptDir = $fromInvoke
    }
}
if (-not $scriptDir -and (-not [string]::IsNullOrWhiteSpace($env:ACOULM_HOME))) {
    $h = [System.IO.Path]::GetFullPath($env:ACOULM_HOME.Trim())
    if (Test-IsAcouLMRoot -Dir $h) {
        $scriptDir = $h
    }
}
if (-not $scriptDir) {
    throw @"
Cannot find AcouLM install (need folder containing npu_cli.ps1 and start_app.ps1).
  Fix: cd your AcouLM repo and run: .\portable_setup.ps1 -NoLaunch
  Or set user env ACOULM_HOME to that folder, then open a new terminal.
"@
}

$cli = Join-Path $scriptDir "npu_cli.ps1"
$start = Join-Path $scriptDir "start_app.ps1"
$defaultStartupTimeoutSeconds = 600
$autoTuneStatePath = Join-Path $scriptDir "registry\auto_tune_state.json"
$defaultAutoTuneCooldownSec = 900

function Write-AcouLMBanner {
    Write-Host ""
    @(
        "      _    ____   ___   _   _  _      __  __ ",
        "     / \  / ___| / _ \ | | | || |    |  \/  |",
        "    / _ \| |    | | | || | | || |    | |\/| |",
        "   / ___ \ |___ | |_| || |_| || |___ | |  | |",
        "  /_/   \_\____| \___/  \___/ |_____||_|  |_|"
    ) | ForEach-Object { Write-Host $_ -ForegroundColor Magenta }
    Write-Host ""
}

function Start-StackHidden {
    param(
        [int]$TimeoutSeconds = 600,
        [switch]$OpenBrowser,
        # Terminal chat path: start API only (no http.server on :5173) — faster and fewer child consoles.
        [switch]$SkipAppShell,
        # Pass through to start_app.ps1 so backend (and app shell) PowerShell windows are Hidden.
        [switch]$HideServiceWindows,
        # Rare debug: visible run.ps1 window (omit -HideServiceWindows on start_app.ps1).
        [switch]$VisibleBackend
    )
    if (-not (Test-Path -LiteralPath $start)) { throw "Missing start_app.ps1 at $start" }

    # One outer hidden PowerShell runs start_app.ps1; it must pass HideServiceWindows so backend/app-shell
    # processes are also Hidden (otherwise start_app spawns two visible PowerShell windows).
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $start,
        "-TimeoutSeconds", "$TimeoutSeconds"
    )
    if ($HideServiceWindows -and -not $VisibleBackend) {
        $args += "-HideServiceWindows"
    }
    if ($SkipAppShell) {
        $args += "-SkipAppShell"
    }
    if ($OpenBrowser) {
        $args += "-OpenBrowser"
    }

    try {
        Start-Process -FilePath "powershell" -ArgumentList $args -WindowStyle Hidden -ErrorAction Stop | Out-Null
    } catch {
        $hb = $HideServiceWindows -and -not $VisibleBackend
        & $start -TimeoutSeconds $TimeoutSeconds `
            -OpenBrowser:$OpenBrowser `
            -HideServiceWindows:$hb `
            -SkipAppShell:$SkipAppShell
    }
}

function Start-AppShellOnlyHidden {
    param(
        [int]$Port = 5173,
        [switch]$OpenBrowser
    )
    $pythonExe = Join-Path $scriptDir "venv\Scripts\python.exe"
    $pythonCmd = if (Test-Path -LiteralPath $pythonExe) { "& '$pythonExe'" } else { "python" }
    $appCmd = "Set-Location '$scriptDir'; $pythonCmd -m http.server $Port --directory app_shell"
    try {
        Start-Process -FilePath "powershell" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $appCmd) -WindowStyle Hidden -ErrorAction Stop | Out-Null
    } catch {
        # Keep this fallback quiet for user experience.
    }
    if ($OpenBrowser) {
        Open-ControlPanelUrl -Url "http://localhost:$Port/"
    }
}

function Open-ControlPanelUrl {
    param([string]$Url = "http://localhost:5173/")
    # Try multiple launch methods for Windows environments where one method may be blocked.
    try {
        Start-Process -FilePath $Url -ErrorAction Stop | Out-Null
        return $true
    } catch {}
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Url
        $psi.UseShellExecute = $true
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        return $true
    } catch {}
    try {
        Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "start", "", $Url) -WindowStyle Hidden -ErrorAction Stop | Out-Null
        return $true
    } catch {}
    try {
        Start-Process -FilePath "explorer.exe" -ArgumentList @($Url) -ErrorAction Stop | Out-Null
        return $true
    } catch {}
    try {
        Start-Process -FilePath "rundll32.exe" -ArgumentList @("url.dll,FileProtocolHandler", $Url) -WindowStyle Hidden -ErrorAction Stop | Out-Null
        return $true
    } catch {}
    return $false
}

function Test-ApiReady {
    param([string]$Base = "http://localhost:8000")
    $b = $Base.TrimEnd("/")
    try {
        $null = Invoke-RestMethod -Uri "$b/v1/health" -Method Get -TimeoutSec 2 -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Test-AppShellReady {
    param([int]$Port = 5173)
    try {
        $null = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -UseBasicParsing -Method Get -TimeoutSec 2 -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Test-BackendProcessRunning {
    try {
        $p = Get-Process -Name "npu_wrapper" -ErrorAction SilentlyContinue
        return ($null -ne $p)
    } catch {
        return $false
    }
}

function Invoke-ApiJson {
    param(
        [string]$Base = "http://127.0.0.1:8000",
        [string]$Path,
        [string]$Method = "GET",
        [object]$Body = $null,
        [int]$TimeoutSec = 10
    )
    $b = $Base.TrimEnd("/")
    $params = @{
        Uri = "$b$Path"
        Method = $Method
        TimeoutSec = $TimeoutSec
        ErrorAction = "Stop"
    }
    if ($null -ne $Body) {
        $params.Headers = @{ "Content-Type" = "application/json" }
        $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 8 -Compress }
    }
    return Invoke-RestMethod @params
}

function Read-AutoTuneState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Write-AutoTuneState {
    param(
        [string]$Path,
        [string]$Result = "unknown",
        [string]$Note = "",
        [object]$Status = $null
    )
    try {
        $obj = [ordered]@{
            last_run_utc = [DateTime]::UtcNow.ToString("o")
            result = $Result
            note = $Note
        }
        if ($null -ne $Status) {
            $obj.policy = [string]$Status.policy
            $obj.active_device = [string]$Status.active_device
            $obj.context_routing = [string]$Status.context_routing
            $obj.split_prefill = [string]$Status.split_prefill
            $obj.devices = @($Status.devices)
        }
        $obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
    } catch {}
}

function Invoke-AutoTuneFastPreset {
    param([string]$Base = "http://127.0.0.1:8000")
    try {
        $s = Invoke-ApiJson -Base $Base -Path "/v1/cli/status" -TimeoutSec 8
    } catch {
        Write-Host "[AcouLM] Auto-tune skipped (API not reachable yet)." -ForegroundColor DarkGray
        return
    }

    $hasGpu = $false
    foreach ($d in @($s.available_devices)) {
        if (($d.id -as [string]) -eq "GPU") { $hasGpu = $true; break }
    }
    if (-not $hasGpu) {
        Write-Host "[AcouLM] Auto-tune: no GPU detected; keeping current runtime settings." -ForegroundColor DarkGray
        Write-AutoTuneState -Path $autoTuneStatePath -Result "skipped" -Note "no-gpu" -Status $s
        return
    }

    $loaded = @($s.devices)
    $alreadyFast = (($s.policy -as [string]) -eq "PERFORMANCE") -and
                   (($s.active_device -as [string]) -eq "GPU") -and
                   (($s.context_routing -as [string]) -eq "ON") -and
                   (($s.split_prefill -as [string]) -eq "ON") -and
                   ($loaded -contains "GPU")

    if ($alreadyFast) {
        Write-Host "[AcouLM] Auto-tune: fast preset already active." -ForegroundColor DarkGray
        Write-AutoTuneState -Path $autoTuneStatePath -Result "ok" -Note "already-fast" -Status $s
        return
    }

    $cooldownSec = $defaultAutoTuneCooldownSec
    if (-not [string]::IsNullOrWhiteSpace($env:ACOULM_AUTOTUNE_COOLDOWN_SEC)) {
        $parsed = 0
        if ([int]::TryParse($env:ACOULM_AUTOTUNE_COOLDOWN_SEC, [ref]$parsed) -and $parsed -ge 0) {
            $cooldownSec = $parsed
        }
    }
    $st = Read-AutoTuneState -Path $autoTuneStatePath
    if ($cooldownSec -gt 0 -and $st -and ($st.result -as [string]) -eq "ok" -and ($st.active_device -as [string]) -eq "GPU" -and ($st.policy -as [string]) -eq "PERFORMANCE") {
        try {
            $last = [DateTime]::Parse([string]$st.last_run_utc)
            $age = [int](([DateTime]::UtcNow - $last.ToUniversalTime()).TotalSeconds)
            if ($age -ge 0 -and $age -lt $cooldownSec) {
                Write-Host "[AcouLM] Auto-tune cooldown active (${age}s/<${cooldownSec}s); skipping retune." -ForegroundColor DarkGray
                return
            }
        } catch {}
    }

    $changed = $false
    try {
        if (($s.policy -as [string]) -ne "PERFORMANCE") {
            $null = Invoke-ApiJson -Base $Base -Path "/v1/cli/policy" -Method "POST" -Body @{ policy = "PERFORMANCE" } -TimeoutSec 12
            $changed = $true
        }
    } catch {}

    try {
        if (-not ($loaded -contains "GPU")) {
            $null = Invoke-ApiJson -Base $Base -Path "/v1/cli/device/load" -Method "POST" -Body @{ device = "GPU" } -TimeoutSec 180
            $changed = $true
        }
    } catch {}

    try {
        if (($s.active_device -as [string]) -ne "GPU") {
            $null = Invoke-ApiJson -Base $Base -Path "/v1/cli/device/switch" -Method "POST" -Body @{ device = "GPU" } -TimeoutSec 12
            $changed = $true
        }
    } catch {}

    try {
        if (($s.context_routing -as [string]) -ne "ON") {
            $null = Invoke-ApiJson -Base $Base -Path "/v1/cli/feature/context-routing" -Method "POST" -Body @{ enabled = $true } -TimeoutSec 12
            $changed = $true
        }
    } catch {}

    try {
        if (($s.split_prefill -as [string]) -ne "ON") {
            $null = Invoke-ApiJson -Base $Base -Path "/v1/cli/feature/split-prefill" -Method "POST" -Body @{ enabled = $true } -TimeoutSec 12
            $changed = $true
        }
    } catch {}

    if ($changed) {
        # Warm up once after real tuning changes so the user's first prompt pays less setup latency.
        try {
            $s2 = Invoke-ApiJson -Base $Base -Path "/v1/cli/status" -TimeoutSec 8
            $modelId = if ([string]::IsNullOrWhiteSpace([string]$s2.selected_model)) { "openvino" } else { [string]$s2.selected_model }
            $null = Invoke-ApiJson -Base $Base -Path "/v1/chat/completions" -Method "POST" -TimeoutSec 90 -Body @{
                model = $modelId
                messages = @(@{ role = "user"; content = "hi" })
                stream = $false
                temperature = 0.0
                max_tokens = 8
            }
        } catch {}
        Write-Host "[AcouLM] Auto-tune applied: PERFORMANCE + GPU + context-routing + split-prefill." -ForegroundColor Green
        Write-AutoTuneState -Path $autoTuneStatePath -Result "ok" -Note "applied" -Status $s2
    } else {
        Write-Host "[AcouLM] Auto-tune: fast preset already active." -ForegroundColor DarkGray
        Write-AutoTuneState -Path $autoTuneStatePath -Result "ok" -Note "no-change" -Status $s
    }
}

# Visible feedback while a hidden start_app.ps1 loads the model (browser/control panel may already be open).
function Wait-ApiReadyWithTerminalMessage {
    param(
        [string]$Base = "http://localhost:8000",
        [int]$TimeoutSec = 600,
        [string]$Hint = ""
    )
    $b = $Base.TrimEnd("/")
    if (Test-ApiReady -Base $Base) {
        Write-Host "[AcouLM] API is ready ($b/v1/health)." -ForegroundColor Green
        return $true
    }
    Write-Host "[AcouLM] Backend is starting in the background. The control panel may show loading or API offline until the model is ready." -ForegroundColor Cyan
    if (-not [string]::IsNullOrWhiteSpace($Hint)) {
        Write-Host "[AcouLM] $Hint" -ForegroundColor DarkGray
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $t0 = Get-Date
    $nextLine = $t0
    while ((Get-Date) -lt $deadline) {
        if (Test-ApiReady -Base $Base) {
            $elapsed = [int]((Get-Date) - $t0).TotalSeconds
            Write-Host "[AcouLM] API is ready (${elapsed}s)." -ForegroundColor Green
            return $true
        }
        $now = Get-Date
        if (($now - $nextLine).TotalSeconds -ge 10) {
            $elapsed = [int]($now - $t0).TotalSeconds
            $remain = [math]::Max(0, [int]($deadline - $now).TotalSeconds)
            Write-Host "[AcouLM] Still loading... (${elapsed}s elapsed, ~${remain}s until timeout)" -ForegroundColor DarkYellow
            $nextLine = $now
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "[AcouLM] API did not become ready at $b within ${TimeoutSec}s. If the window is hidden, check Task Manager for npu_wrapper or run .\start_app.ps1 without -HideServiceWindows." -ForegroundColor Red
    return $false
}

function Wait-ApiReadyBrief {
    param(
        [string]$Base = "http://127.0.0.1:8000",
        [int]$TimeoutSec = 20
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-ApiReady -Base $Base) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

if (-not (Test-Path -LiteralPath $cli)) {
    throw "Missing CLI script: $cli"
}

$sub = $null
$tail = [string[]]@()
if ($Passthrough -and $Passthrough.Count -gt 0) {
    $first = [string]$Passthrough[0]
    if ($first -notlike "-*" -and $first -in @("start", "chat", "status", "help")) {
        $sub = $first.ToLowerInvariant()
        if ($Passthrough.Count -gt 1) {
            $tail = $Passthrough[1..($Passthrough.Count - 1)]
        }
    }
}

if ($sub) {
    switch ($sub) {
        "start" {
            if (-not (Test-Path -LiteralPath $start)) { throw "Missing start_app.ps1 at $start" }
            Write-AcouLMBanner
            Write-Host "[AcouLM] Launching stack (hidden). Browser may open to the control panel before the API is up." -ForegroundColor Cyan
            # start_app.ps1 -OpenBrowser opens once when the control panel is ready; do not also open from this process (double tab).
            Start-StackHidden -TimeoutSeconds $defaultStartupTimeoutSeconds -OpenBrowser -HideServiceWindows
            $ok = Wait-ApiReadyWithTerminalMessage -Base $ApiBase -TimeoutSec $defaultStartupTimeoutSeconds `
                -Hint "Keep http://localhost:5173/ open — refresh if the page stays on loading."
            if ($ok) {
                Invoke-AutoTuneFastPreset -Base $ApiBase
            }
            exit $(if ($ok) { 0 } else { 1 })
        }
        "status" {
            $base = $ApiBase.TrimEnd("/")
            try {
                $r = Invoke-RestMethod -Uri "$base/v1/cli/status" -Method Get -TimeoutSec 15
                $r | ConvertTo-Json -Depth 6
            } catch {
                Write-Error "Could not reach API at $base. Run 'acoulm' to auto-start and connect."
                exit 1
            }
            exit 0
        }
        "help" {
            @"
AcouLM
  acoulm              Start API + local control panel on localhost:5173, then terminal chat
  acoulm chat         Same as default
  acoulm start        Start API + localhost:5173 control panel (no terminal chat)
  acoulm status       GET /v1/cli/status from default API
  acoulm [npu args]   Forward to npu_cli.ps1

  Default acoulm (no arguments) starts the control panel (:5173) + API like acoulm start, then opens terminal chat (hidden service consoles).
  UI without terminal chat: acoulm start  or  .\start_app.ps1 -OpenBrowser
  Visible backend/debug: .\start_app.ps1  (omit -HideServiceWindows)

  Models (built-in OpenVINO backend): use one runnable artifact — OpenVINO IR folder, or a single .gguf file.
  Raw Hugging Face safetensors folders do not start the API until you export or use a GGUF path in registry.

  Download one GGUF variant (you choose the filename / quantization):
    .\npu_cli.ps1 -Command model -Arguments ""download"",""bartowski/Qwen2.5-3B-Instruct-GGUF"",""my-model"",""Qwen2.5-3B-Instruct-Q4_K_M.gguf""
  Then import/select that path in http://localhost:5173 or edit registry\models_registry.json.

  If chat says the API is offline while weights load, wait longer or set env ACOULM_BACKEND_WAIT_SEC=900.

  Optional auto-pick among several registry models at launch: auto_select_best_model in models registry.

  Global command: run .\portable_setup.ps1 -NoLaunch once per machine (PATH + ACOULM_HOME).
"@ | Write-Host
            exit 0
        }
        "chat" {
            if ($tail.Count -gt 0) { & $cli @tail }
            else { & $cli -Command chat }
            exit $LASTEXITCODE
        }
    }
}

if ($Passthrough -and $Passthrough.Count -gt 0) {
    # npu_cli.ps1 only accepts -Command/-Arguments (not positional), so map common CLI verbs.
    $pt0 = [string]$Passthrough[0]
    if ($pt0 -eq "model") {
        $argTail = @()
        if ($Passthrough.Count -gt 1) {
            $argTail = $Passthrough[1..($Passthrough.Count - 1)]
        }
        & $cli -ApiBase $ApiBase -Command model -Arguments $argTail
    } else {
        & $cli -ApiBase $ApiBase @Passthrough
    }
    exit $LASTEXITCODE
} elseif (-not [string]::IsNullOrWhiteSpace($Command) -or -not [string]::IsNullOrWhiteSpace($Prompt) -or ($Arguments -and $Arguments.Count -gt 0) -or $ApiBase -ne "http://127.0.0.1:8000") {
    & $cli -ApiBase $ApiBase -Prompt $Prompt -Command $Command -Arguments $Arguments
} else {
    if (-not (Test-Path -LiteralPath $start)) { throw "Missing start_app.ps1 at $start" }

    # Keep default flow simple: hidden stack start (if needed) + terminal chat UX.
    $apiReady = Test-ApiReady -Base $ApiBase
    $appShellReady = Test-AppShellReady -Port 5173
    $browserOpenedByChild = $false
    if ((-not $apiReady) -and (-not $appShellReady)) {
        Write-Host "[AcouLM] Starting control panel + API in background..." -ForegroundColor Cyan
        Start-StackHidden -TimeoutSeconds $defaultStartupTimeoutSeconds -OpenBrowser -HideServiceWindows
        $browserOpenedByChild = $true
    } elseif ($apiReady -and (-not $appShellReady)) {
        Write-Host "[AcouLM] API already running; starting control panel on :5173..." -ForegroundColor Cyan
        Start-AppShellOnlyHidden -Port 5173 -OpenBrowser
        $browserOpenedByChild = $true
    } elseif ((-not $apiReady) -and $appShellReady) {
        Start-StackHidden -TimeoutSeconds $defaultStartupTimeoutSeconds -OpenBrowser -HideServiceWindows
        $browserOpenedByChild = $true
    }

    # Open here only when nothing above asked start_app / app shell to open a tab (e.g. API + control panel already up).
    if (-not $browserOpenedByChild) {
        $null = Open-ControlPanelUrl -Url "http://localhost:5173/"
    }
    & $cli -Command chat
}

