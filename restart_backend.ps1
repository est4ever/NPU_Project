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

function Repair-LaunchArgv {
    param([string[]]$Argv)
    $out = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Argv.Count; $i++) {
        $a = [string]$Argv[$i]
        if ($a -eq "--device" -and ($i + 1) -lt $Argv.Count) {
            $val = [string]$Argv[$i + 1]
            $i++
            if ($val -match '^(PERFORMANCE|BATTERY_SAVER|BALANCED)$') {
                $out.Add("--policy")
                $out.Add($val)
                continue
            }
            if ($val -match '^(CPU|GPU|NPU)$') {
                $out.Add("--device")
                $out.Add($val)
            }
            continue
        }
        if ($a -eq "--policy" -and ($i + 1) -ge $Argv.Count) {
            continue
        }
        $out.Add($a)
    }
    return @($out)
}

$argList = @()
if ($null -ne $state.argv) {
    $raw = @()
    foreach ($a in $state.argv) {
        $raw += [string]$a
    }
    $argList = @(Repair-LaunchArgv -Argv $raw)
}

Write-Host "[restart_backend] Starting: $runScript $($argList -join ' ')" -ForegroundColor Cyan
& $runScript @argList
exit $LASTEXITCODE
