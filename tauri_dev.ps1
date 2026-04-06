# tauri_dev.ps1
# Start the NPU Companion in Tauri dev mode (hot-reload).
#
# Prerequisites (one-time setup):
#   1. Install Rust:  https://rustup.rs
#      Then restart this terminal.
#   2. Install Tauri CLI:
#      cargo install tauri-cli --version "^2"
#   3. Build the C++ backend first (if not already done):
#      .\build.ps1
#
# Usage:
#   .\tauri_dev.ps1

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $scriptDir

# --- Check prerequisites ---
$cargoExe = Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe"
if (-not (Test-Path $cargoExe)) {
    $cargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
    if ($cargoCmd) {
        $cargoExe = $cargoCmd.Source
    } else {
        Write-Error "Rust/cargo not found. Install from https://rustup.rs then restart the terminal."
        exit 1
    }
}

$cargoTauriExe = Join-Path $env:USERPROFILE ".cargo\bin\cargo-tauri.exe"
if (-not (Test-Path $cargoTauriExe)) {
    Write-Host "tauri-cli not found - installing (one-time, ~60 s)..."
    & $cargoExe install tauri-cli --version "^2"
}

$backend = Join-Path $scriptDir "build\Release\npu_wrapper.exe"
if (-not (Test-Path $backend)) {
    Write-Error "npu_wrapper.exe not found at '$backend'. Run .\build.ps1 first."
    exit 1
}

# --- Start the frontend dev server if not already running ---
$frontendPort = 5173
$frontendReady = $false
try {
    $resp = Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$frontendPort/index.html" -TimeoutSec 2
    if ($resp.StatusCode -eq 200 -and $resp.Content -match "NPU App Shell") {
        $frontendReady = $true
        Write-Host "Frontend server already running on port $frontendPort"
    }
} catch {}

if (-not $frontendReady) {
    Write-Host "Starting frontend server on http://127.0.0.1:$frontendPort ..."
    $pyExe = Join-Path $scriptDir "venv\Scripts\python.exe"
    if (-not (Test-Path $pyExe)) { $pyExe = "python" }
    Start-Process -FilePath $pyExe -ArgumentList "-m", "http.server", "$frontendPort", "--bind", "127.0.0.1", "--directory", (Join-Path $scriptDir "app_shell") -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

Write-Host ""
Write-Host "Starting NPU Companion (Tauri dev mode)..."
Write-Host "  Frontend : http://127.0.0.1:$frontendPort (app_shell/)"
Write-Host "  Backend  : build\Release\npu_wrapper.exe (auto-spawned by Tauri)"
Write-Host ""

# Run tauri dev and capture output so we can detect Application Control errors.
$proc = Start-Process -FilePath $cargoExe -ArgumentList "tauri", "dev" `
    -PassThru -NoNewWindow `
    -RedirectStandardError "$env:TEMP\tauri_dev_stderr.txt" `
    -RedirectStandardOutput "$env:TEMP\tauri_dev_stdout.txt"

# Stream stdout in real time while the process runs
$job = Start-Job -ScriptBlock {
    param($f)
    while ($true) {
        if (Test-Path $f) { Get-Content $f -Wait -ErrorAction SilentlyContinue | Write-Output }
        Start-Sleep -Milliseconds 200
    }
} -ArgumentList "$env:TEMP\tauri_dev_stdout.txt"

$proc.WaitForExit()
Stop-Job $job -ErrorAction SilentlyContinue
Remove-Job $job -Force -ErrorAction SilentlyContinue

# Check for Application Control block (os error 4551)
$stderr = if (Test-Path "$env:TEMP\tauri_dev_stderr.txt") { Get-Content "$env:TEMP\tauri_dev_stderr.txt" -Raw } else { "" }
$stdout = if (Test-Path "$env:TEMP\tauri_dev_stdout.txt") { Get-Content "$env:TEMP\tauri_dev_stdout.txt" -Raw } else { "" }
Write-Host $stdout
Write-Host $stderr -ForegroundColor DarkGray

if (($stderr + $stdout) -match "4551|Application Control|never executed") {
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Red
    Write-Host "BLOCKED: Windows Application Control prevented the Tauri"   -ForegroundColor Red
    Write-Host "debug binary from running. This is NOT a code error."        -ForegroundColor Red
    Write-Host ""
    Write-Host "FIX (one-time, takes ~10 seconds):"                          -ForegroundColor Yellow
    Write-Host "  Settings -> System -> For Developers -> Developer Mode ON" -ForegroundColor Yellow
    Write-Host "  Then re-run: .\tauri_dev.ps1"                              -ForegroundColor Yellow
    Write-Host ""
    Write-Host "ALTERNATIVE (works right now, no fix needed):"               -ForegroundColor Cyan
    Write-Host "  .\start_app.ps1   (browser-based, full functionality)"     -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor Red
    exit 1
}

exit $proc.ExitCode
