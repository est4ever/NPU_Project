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

# Daily use is only `acoulm` (no arguments). Chat: /exit and /status (leading slash required).

function Test-AutoTuneEnabled {
    return $env:ACOULM_AUTOTUNE -eq "1"
}

function Test-IsAcouLMRoot {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
    $npu = Join-Path $Dir "npu_cli.ps1"
    $app = Join-Path $Dir "start_app.ps1"
    return ((Test-Path -LiteralPath $npu) -and (Test-Path -LiteralPath $app))
}

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
  Fix: cd your AcouLM repo and run: acoulm setup
  Or set user env ACOULM_HOME to that folder, then open a new terminal.
"@
}

if ([string]::IsNullOrWhiteSpace($env:ACOULM_HOME)) {
    $env:ACOULM_HOME = $scriptDir
}
$deviceScript = Join-Path $scriptDir "scripts\AcouLM-Device.ps1"
if (Test-Path -LiteralPath $deviceScript) {
    . $deviceScript
    Initialize-AcouLMDeviceEnvironment
}
if (-not $env:ACOULM_FAST_LOAD) {
    $env:ACOULM_FAST_LOAD = "1"
}
if ($env:ACOULM_SNAPPY -ne "0") {
    $env:ACOULM_SNAPPY = "1"
    $env:ACOULM_PERFORMANCE_MODE = "1"
}

$cli = Join-Path $scriptDir "npu_cli.ps1"
$start = Join-Path $scriptDir "start_app.ps1"
$build = Join-Path $scriptDir "build.ps1"
$setup = Join-Path $scriptDir "portable_setup.ps1"
$bench = Join-Path $scriptDir "benchmark_acoulm_toggle.ps1"
$restartStack = Join-Path $scriptDir "restart_stack.ps1"
$defaultStartupTimeoutSeconds = 360
$autoTuneStatePath = Join-Path $scriptDir "registry\auto_tune_state.json"
$defaultAutoTuneCooldownSec = 900
$script:AcoulmBrowserOpened = $false
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

function Show-AcoulmNoArgsHint {
    Write-Host "[AcouLM] Run acoulm with no arguments." -ForegroundColor Yellow
    Write-Host "[AcouLM] In terminal chat use /status or /exit (leading slash required)." -ForegroundColor DarkGray
}

function Start-StackHidden {
    param(
        [int]$TimeoutSeconds = 600,
        [switch]$OpenBrowser,
        [switch]$SkipAppShell,
        [switch]$HideServiceWindows,
        [switch]$VisibleBackend,
        [switch]$PerformanceMode,
        [string]$DeviceOverride = "",
        [string[]]$StartAppExtraArgs = @()
    )
    if (-not (Test-Path -LiteralPath $start)) { throw "Missing start_app.ps1 at $start" }

    # Terminal-first launch: load API before waiting on the static UI server.
    if (-not $PSBoundParameters.ContainsKey("SkipAppShell") -and $env:ACOULM_TERMINAL_ONLY -eq "1") {
        $SkipAppShell = $true
    }

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $start,
        "-TimeoutSeconds", "$TimeoutSeconds"
    )
    if (-not [string]::IsNullOrWhiteSpace($DeviceOverride)) {
        $args += "-Device", $DeviceOverride.Trim().ToUpperInvariant()
    }
    if ($HideServiceWindows -and -not $VisibleBackend) {
        $args += "-HideServiceWindows"
    }
    if ($SkipAppShell) {
        $args += "-SkipAppShell"
    }
    if ($OpenBrowser) {
        $args += "-OpenBrowser"
    }
    if ($PerformanceMode) {
        $args += "-PerformanceMode"
    }
    if ($StartAppExtraArgs -and $StartAppExtraArgs.Count -gt 0) {
        $args += $StartAppExtraArgs
    }

    try {
        Start-Process -FilePath "powershell" -ArgumentList $args -WindowStyle Hidden -ErrorAction Stop | Out-Null
    } catch {
        $hb = $HideServiceWindows -and -not $VisibleBackend
        $sp = @{
            TimeoutSeconds     = $TimeoutSeconds
            OpenBrowser        = $OpenBrowser
            HideServiceWindows = $hb
            SkipAppShell       = $SkipAppShell
            PerformanceMode    = $PerformanceMode
        }
        if (-not [string]::IsNullOrWhiteSpace($DeviceOverride)) {
            $sp["Device"] = $DeviceOverride.Trim().ToUpperInvariant()
        }
        & $start @sp @StartAppExtraArgs
    }
}

function Invoke-AutoTuneIfEnabled {
    param([string]$Base = "http://127.0.0.1:8000")
    if (-not (Test-AutoTuneEnabled)) { return }
    Invoke-AutoTuneFastPreset -Base $Base
}

function Start-AppShellOnlyHidden {
    param([int]$Port = 5173)
    $pythonExe = Join-Path $scriptDir "venv\Scripts\python.exe"
    $pythonCmd = if (Test-Path -LiteralPath $pythonExe) { "& '$pythonExe'" } else { "python" }
    $appCmd = "Set-Location '$scriptDir'; $pythonCmd -m http.server $Port --directory app_shell"
    try {
        Start-Process -FilePath "powershell" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $appCmd) -WindowStyle Hidden -ErrorAction Stop | Out-Null
    } catch {}
}

function Open-ControlPanelUrl {
    param([string]$Url = "http://127.0.0.1:5173/")
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    if ($script:AcoulmBrowserOpened) { return $true }
    $opened = $false
    try {
        Start-Process -FilePath $Url -ErrorAction Stop | Out-Null
        $opened = $true
    } catch {}
    if (-not $opened) {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $Url
            $psi.UseShellExecute = $true
            [System.Diagnostics.Process]::Start($psi) | Out-Null
            $opened = $true
        } catch {}
    }
    if (-not $opened) {
        try {
            Invoke-Item -LiteralPath $Url -ErrorAction Stop
            $opened = $true
        } catch {}
    }
    if (-not $opened) {
        try {
            $safe = $Url.Replace('"', '""')
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = "cmd.exe"
            $startInfo.Arguments = '/c start "" "' + $safe + '"'
            $startInfo.CreateNoWindow = $true
            $startInfo.UseShellExecute = $false
            [System.Diagnostics.Process]::Start($startInfo) | Out-Null
            $opened = $true
        } catch {}
    }
    if ($opened) {
        $script:AcoulmBrowserOpened = $true
        return $true
    }
    return $false
}

function Invoke-OpenBrowserOnce {
    param(
        [int]$Port = 5173,
        [string]$ApiBase = "http://127.0.0.1:8000",
        [switch]$WaitForChatReady
    )
    if ($script:AcoulmBrowserOpened) { return $true }
    $url = "http://127.0.0.1:$Port/"

    if ($WaitForChatReady) {
        $waitSec = 360
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
        $t0 = Get-Date
        $nextLine = $t0
        while ((Get-Date) -lt $deadline) {
            if ((Test-ApiChatReady -Base $ApiBase) -and (Test-AppShellReady -Port $Port)) {
                if (Open-ControlPanelUrl -Url $url) {
                    Write-Host "[AcouLM] Opened control panel (model ready): $url" -ForegroundColor Green
                    return $true
                }
            }
            $now = Get-Date
            if (($now - $nextLine).TotalSeconds -ge 12) {
                $elapsed = [int]($now - $t0).TotalSeconds
                if (Test-ApiHttpUp -Base $ApiBase) {
                    Write-Host "[AcouLM] API online - loading model (first compile may take several minutes, ${elapsed}s so far)..." -ForegroundColor DarkYellow
                } else {
                    Write-Host "[AcouLM] Starting backend (${elapsed}s)..." -ForegroundColor DarkYellow
                }
                $nextLine = $now
            }
            Start-Sleep -Milliseconds 400
        }
        Write-Host "[AcouLM] Model still loading - panel may show offline until [ready] in terminal: $url" -ForegroundColor DarkGray
        return $false
    }

    if (Test-AppShellReady -Port $Port) {
        if (Open-ControlPanelUrl -Url $url) {
            Write-Host "[AcouLM] Opened control panel: $url" -ForegroundColor Green
            return $true
        }
    }
    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        if (Test-AppShellReady -Port $Port) {
            if (Open-ControlPanelUrl -Url $url) {
                Write-Host "[AcouLM] Opened control panel: $url" -ForegroundColor Green
                return $true
            }
            break
        }
        Start-Sleep -Milliseconds 300
    }
    Write-Host "[AcouLM] Control panel still starting - open manually if needed: $url" -ForegroundColor DarkGray
    return $false
}

function Test-ApiHttpUp {
    param(
        [string]$Base = "http://localhost:8000",
        [int]$TimeoutSec = 8
    )
    $b = $Base.TrimEnd("/")
    try {
        $null = Invoke-RestMethod -Uri "$b/v1/health" -Method Get -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Test-ApiChatReady {
    param(
        [string]$Base = "http://localhost:8000",
        [int]$TimeoutSec = 8
    )
    $b = $Base.TrimEnd("/")
    try {
        $h = Invoke-RestMethod -Uri "$b/v1/health" -Method Get -TimeoutSec $TimeoutSec -ErrorAction Stop
        if ($null -ne $h.chat_ready -and $h.chat_ready -eq $false) {
            return $false
        }
        return $true
    } catch {
        return $false
    }
}

function Wait-ForBackendProcess {
    param([int]$TimeoutSec = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-BackendProcessRunning) {
            return $true
        }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Test-ApiReady {
    param([string]$Base = "http://localhost:8000")
    return (Test-ApiChatReady -Base $Base)
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

function Invoke-ApiJson {
    param(
        [string]$Base = "http://127.0.0.1:8000",
        [string]$Path,
        [string]$Method = "GET",
        [object]$Body = $null,
        [int]$TimeoutSec = 10,
        [switch]$TerminalChat
    )
    $b = $Base.TrimEnd("/")
    $params = @{
        Uri         = "$b$Path"
        Method      = $Method
        TimeoutSec  = $TimeoutSec
        ErrorAction = "Stop"
    }
    $hdr = @{}
    if ($TerminalChat) { $hdr["x-npu-cli"] = "true" }
    if ($null -ne $Body) {
        $hdr["Content-Type"] = "application/json"
        $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 8 -Compress }
    }
    if ($hdr.Count -gt 0) { $params.Headers = $hdr }
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
            result       = $Result
            note         = $Note
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
    $gpuIntegrated = $false
    $hasNpu = $false
    foreach ($d in @($s.available_devices)) {
        $id = ($d.id -as [string])
        if ($id -eq "GPU") {
            $hasGpu = $true
            if (($d.tier -as [string]) -eq "integrated") { $gpuIntegrated = $true }
        }
        if ($id -eq "NPU") { $hasNpu = $true }
    }
    if ($env:ACOULM_GPU_TIER -eq "weak" -or $env:ACOULM_GPU_TIER -eq "integrated") {
        $gpuIntegrated = $true
    }
    if (-not $hasGpu) {
        Write-Host "[AcouLM] Auto-tune: no GPU detected; keeping current runtime settings." -ForegroundColor DarkGray
        Write-AutoTuneState -Path $autoTuneStatePath -Result "skipped" -Note "no-gpu" -Status $s
        return
    }
    if ($gpuIntegrated) {
        Write-Host "[AcouLM] Auto-tune: integrated GPU — not forcing GPU switch (often no faster than CPU)." -ForegroundColor DarkGray
        Write-AutoTuneState -Path $autoTuneStatePath -Result "skipped" -Note "integrated-gpu" -Status $s
        return
    }

    $loaded = @($s.devices)
    $alreadyFast = (($s.policy -as [string]) -eq "PERFORMANCE") -and
        (($s.active_device -as [string]) -eq "GPU") -and
        ($loaded -contains "GPU") -and
        ($loaded.Count -le 1)

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

  # Never hot-load a second device or enable split-prefill here — that duplicates full model RAM.
    try {
        if (($s.active_device -as [string]) -ne "GPU" -and ($loaded -contains "GPU")) {
            $null = Invoke-ApiJson -Base $Base -Path "/v1/cli/device/switch" -Method "POST" -Body @{ device = "GPU" } -TimeoutSec 12
            $changed = $true
        }
    } catch {}

    $s2 = $s
    if ($changed) {
        try { $s2 = Invoke-ApiJson -Base $Base -Path "/v1/cli/status" -TimeoutSec 8 } catch {}
        Write-Host "[AcouLM] Auto-tune applied: PERFORMANCE policy, single GPU device (memory-safe)." -ForegroundColor Green
        Write-AutoTuneState -Path $autoTuneStatePath -Result "ok" -Note "applied" -Status $s2
    } else {
        Write-Host "[AcouLM] Auto-tune: fast preset already active." -ForegroundColor DarkGray
        Write-AutoTuneState -Path $autoTuneStatePath -Result "ok" -Note "no-change" -Status $s
    }
}

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
    Write-Host "[AcouLM] Backend is starting in the background. The control panel may show loading until the model is ready." -ForegroundColor Cyan
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
    Write-Host "[AcouLM] API did not become ready at $b within ${TimeoutSec}s." -ForegroundColor Red
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

function Wait-ApiHttpUpWithProgress {
    param(
        [string]$Base = "http://127.0.0.1:8000",
        [int]$TimeoutSec = 90
    )
    if (Test-ApiHttpUp -Base $Base) {
        return $true
    }
    Write-Host "[AcouLM] Waiting for API to start..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $t0 = Get-Date
    while ((Get-Date) -lt $deadline) {
        if (Test-ApiHttpUp -Base $Base) {
            $elapsed = [int]((Get-Date) - $t0).TotalSeconds
            Write-Host "[AcouLM] API online (${elapsed}s)." -ForegroundColor Green
            return $true
        }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Wait-ApiChatReadyWithProgress {
    param(
        [string]$Base = "http://127.0.0.1:8000",
        [int]$TimeoutSec = 0
    )
    if (Test-ApiChatReady -Base $Base) {
        return $true
    }
    if ($TimeoutSec -le 0) {
        $TimeoutSec = $defaultStartupTimeoutSeconds
        try {
            $envWait = [string]$env:ACOULM_BACKEND_WAIT_SEC
            if (-not [string]::IsNullOrWhiteSpace($envWait)) {
                $parsed = 0
                if ([int]::TryParse($envWait.Trim(), [ref]$parsed) -and $parsed -gt 0) {
                    $TimeoutSec = $parsed
                }
            }
        } catch {}
    }
    Write-Host "[AcouLM] Waiting for model (first compile is often 1-5 min; later runs reuse cache if backend stays up)..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $t0 = Get-Date
    $nextLine = $t0
    while ((Get-Date) -lt $deadline) {
        if (Test-ApiChatReady -Base $Base) {
            $elapsed = [int]((Get-Date) - $t0).TotalSeconds
            Write-Host "[AcouLM] Model ready (${elapsed}s)." -ForegroundColor Green
            return $true
        }
        $now = Get-Date
        if (($now - $nextLine).TotalSeconds -ge 12) {
            $elapsed = [int]($now - $t0).TotalSeconds
            if (-not (Test-BackendProcessRunning)) {
                Write-Host "[AcouLM] Backend not running (${elapsed}s) - see runlog.txt" -ForegroundColor Yellow
            } elseif (Test-ApiHttpUp -Base $Base -TimeoutSec 15) {
                Write-Host "[AcouLM] API online - compiling weights (${elapsed}s)..." -ForegroundColor DarkYellow
            } else {
                Write-Host "[AcouLM] Still compiling (${elapsed}s, health slow while busy)..." -ForegroundColor DarkYellow
            }
            $nextLine = $now
        }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Test-BackendProcessRunning {
    return $null -ne (Get-Process -Name "npu_wrapper" -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Ensure-AcouLMStackStarted {
    param(
        [switch]$PerformanceMode,
        [string]$DeviceOverride = "",
        [string[]]$StartAppExtraArgs = @()
    )
    $apiChatReady = Test-ApiChatReady -Base $ApiBase
    $apiHttpUp = Test-ApiHttpUp -Base $ApiBase
    $backendRunning = Test-BackendProcessRunning
    $appShellReady = Test-AppShellReady -Port 5173
    $started = $false

    if ($apiChatReady) {
        if (-not $appShellReady) {
            Write-Host "[AcouLM] API ready; starting control panel on :5173..." -ForegroundColor Cyan
            Start-AppShellOnlyHidden -Port 5173
        }
        return $false
    }

    if ($backendRunning -or $apiHttpUp) {
        Write-Host "[AcouLM] Backend already running - not starting a second copy." -ForegroundColor DarkGray
        if (-not $appShellReady) {
            Start-AppShellOnlyHidden -Port 5173
        }
        if (-not $apiHttpUp) {
            $null = Wait-ApiHttpUpWithProgress -Base $ApiBase -TimeoutSec 120
        }
        return $false
    }

    if (-not $appShellReady) {
        Write-Host "[AcouLM] Starting API in background (control panel loads in parallel)..." -ForegroundColor Cyan
        $env:ACOULM_TERMINAL_ONLY = "1"
        Start-StackHidden -TimeoutSeconds $defaultStartupTimeoutSeconds -SkipAppShell `
            -HideServiceWindows -PerformanceMode:$PerformanceMode -DeviceOverride $DeviceOverride `
            -StartAppExtraArgs $StartAppExtraArgs
        Start-AppShellOnlyHidden -Port 5173
        $started = $true
    } else {
        Write-Host "[AcouLM] Starting API (control panel already on :5173)..." -ForegroundColor Cyan
        $env:ACOULM_TERMINAL_ONLY = "1"
        Start-StackHidden -TimeoutSeconds $defaultStartupTimeoutSeconds -SkipAppShell `
            -HideServiceWindows -PerformanceMode:$PerformanceMode -DeviceOverride $DeviceOverride `
            -StartAppExtraArgs $StartAppExtraArgs
        $started = $true
    }
    return $started
}

function Start-AcouLMBrowserWhenReady {
    param(
        [string]$ApiBase = "http://127.0.0.1:8000",
        [int]$Port = 5173
    )
    if ($script:AcoulmBrowserOpened) { return }
    $url = "http://127.0.0.1:$Port/"
    $base = $ApiBase.TrimEnd("/")
    $null = Start-Job -Name "AcouLM-Browser" -ScriptBlock {
        param($PanelUrl, $HealthUrl)
        $deadline = (Get-Date).AddMinutes(8)
        while ((Get-Date) -lt $deadline) {
            try {
                $h = Invoke-RestMethod -Uri $HealthUrl -Method Get -TimeoutSec 3 -ErrorAction Stop
                if ($null -eq $h.chat_ready -or $h.chat_ready -eq $true) {
                    Start-Process -FilePath $PanelUrl -ErrorAction SilentlyContinue | Out-Null
                    break
                }
            } catch {}
            Start-Sleep -Seconds 2
        }
    } -ArgumentList $url, "$base/v1/health"
}

function Stop-AcouLMStack {
    $script:AcoulmBrowserOpened = $false
    Get-Process -Name "npu_wrapper" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "name = 'python.exe' OR name = 'pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -like "*http.server 5173*" -and $_.CommandLine -like "*--directory app_shell*"
        } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    Write-Host "[AcouLM] Stopped backend and control panel processes." -ForegroundColor Green
}

function Invoke-AcouLMNpuCli {
    param(
        [string[]]$CliArgs = @(),
        [string]$SubCommand = "",
        [string[]]$SubTail = @()
    )
    if ($SubCommand -eq "model") {
        & $cli -ApiBase $ApiBase -Command model -Arguments $SubTail
    } elseif ($SubCommand -eq "chat" -and $SubTail.Count -gt 0) {
        & $cli -ApiBase $ApiBase -Command chat -Arguments ($SubTail -join " ")
    } else {
        & $cli -ApiBase $ApiBase @CliArgs
    }
    exit $LASTEXITCODE
}

function Test-StartAppSwitch {
    param([string[]]$Args, [string]$Name)
    foreach ($a in $Args) {
        if ($a -eq $Name -or $a -eq "--$Name" -or $a -like "-$Name") { return $true }
    }
    return $false
}

if (-not (Test-Path -LiteralPath $cli)) {
    throw "Missing CLI script: $cli"
}

# --- Dispatch: only bare `acoulm` (any extra args or flags → hint, no launch) ---
$hasExtraInvocation = ($Passthrough -and $Passthrough.Count -ge 1) `
    -or (-not [string]::IsNullOrWhiteSpace($Command)) `
    -or (-not [string]::IsNullOrWhiteSpace($Prompt)) `
    -or ($Arguments -and $Arguments.Count -gt 0) `
    -or ($ApiBase -ne "http://127.0.0.1:8000")
if ($hasExtraInvocation) {
    Show-AcoulmNoArgsHint
    exit 1
}

# Default: acoulm
if (-not (Test-Path -LiteralPath $start)) { throw "Missing start_app.ps1 at $start" }

$ensureFast = Join-Path $scriptDir "scripts\Ensure-FastModel.ps1"
if (Test-Path -LiteralPath $ensureFast) {
    try {
        $null = & $ensureFast -ProjectRoot $scriptDir
        $irJob = Get-Job -Name "AcouLM-IR-*" -ErrorAction SilentlyContinue
        if (-not $irJob -and -not (Test-ApiChatReady -Base $ApiBase)) {
            $hfDir = Join-Path $scriptDir "models\Qwen2.5-3B-Instruct"
            $irDir = Join-Path $scriptDir "models\Qwen2.5-3B-Instruct-ov-ir"
            if ((Test-Path -LiteralPath $hfDir) -and -not (Test-Path -LiteralPath $irDir)) {
                $null = & $ensureFast -ProjectRoot $scriptDir -BackgroundExportOnly
            }
        }
    } catch {
        Write-Host "[AcouLM] Fast IR setup: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

$launchSw = [System.Diagnostics.Stopwatch]::StartNew()
$snappyHot = Test-ApiChatReady -Base $ApiBase
if ($snappyHot) {
    $ms = [int]$launchSw.ElapsedMilliseconds
    Write-Host "[AcouLM] Hot start (${ms}ms) - model already loaded." -ForegroundColor Green
} else {
    $null = Ensure-AcouLMStackStarted -PerformanceMode
    if (-not (Test-BackendProcessRunning)) {
        Write-Host "[AcouLM] Waiting for backend process..." -ForegroundColor Cyan
        $null = Wait-ForBackendProcess -TimeoutSec 90
    }
    if (Test-BackendProcessRunning) {
        Write-Host "[AcouLM] Backend running - loading model (first compile can take several minutes on a weak GPU)..." -ForegroundColor Cyan
    } else {
        Write-Host "[AcouLM] Backend did not start - check hidden PowerShell or run .\start_app.ps1 -VisibleBackend" -ForegroundColor Yellow
    }
}

if ($snappyHot) {
    if (-not (Test-AppShellReady -Port 5173)) {
        Start-AppShellOnlyHidden -Port 5173
    }
    $null = Invoke-OpenBrowserOnce -ApiBase $ApiBase
} else {
    Start-AcouLMBrowserWhenReady -ApiBase $ApiBase
}
if (-not $snappyHot) {
    Invoke-AutoTuneIfEnabled -Base $ApiBase
}

& $cli -ApiBase $ApiBase -Command chat
if (Test-BackendProcessRunning) {
    Write-Host "[AcouLM] Backend still running - next acoulm should show 'Hot start' if the model stays loaded." -ForegroundColor DarkGray
} else {
    Write-Host "[AcouLM] Backend exited - next launch will compile again. Check hidden PowerShell / Task Manager." -ForegroundColor Yellow
}
