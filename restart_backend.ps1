# Relaunches the API backend after registry/backend or entrypoint changes.
# Invoked by npu_wrapper via POST /v1/cli/backend/restart (do not run manually unless debugging).

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$statePath = Join-Path $scriptDir "registry\npu_launch_state.json"

Start-Sleep -Seconds 2

if (-not (Test-Path -LiteralPath $statePath)) {
    Write-Host "[restart_backend] Missing $statePath" -ForegroundColor Red
    exit 1
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$pidToStop = [int]$state.backend_pid
$root = [string]$state.project_root
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = $scriptDir
}

if ($pidToStop -gt 0) {
    Stop-Process -Id $pidToStop -Force -ErrorAction SilentlyContinue
}

Start-Sleep -Seconds 1

Set-Location -LiteralPath $root
$runScript = Join-Path $root "run.ps1"
if (-not (Test-Path -LiteralPath $runScript)) {
    Write-Host "[restart_backend] Missing run.ps1 at $runScript" -ForegroundColor Red
    exit 1
}

$argList = @()
if ($null -ne $state.argv) {
    foreach ($a in $state.argv) {
        $argList += [string]$a
    }
}

Write-Host "[restart_backend] Starting: $runScript $($argList -join ' ')" -ForegroundColor Cyan
& $runScript @argList
exit $LASTEXITCODE
