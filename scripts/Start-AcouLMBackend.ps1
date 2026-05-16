# Detached AcouLM backend host: sets OpenVINO env and keeps npu_wrapper alive.
param(
    [Parameter(Mandatory = $true)][string]$Model,
    [int]$Port = 8000,
    [string]$Device = "",
    [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location -LiteralPath $scriptDir

if ([string]::IsNullOrWhiteSpace($env:ACOULM_HOME)) {
    $env:ACOULM_HOME = $scriptDir
}
if ($env:ACOULM_SNAPPY -ne "0") {
    $env:ACOULM_SNAPPY = "1"
    $env:ACOULM_PERFORMANCE_MODE = "1"
}
if (-not $env:ACOULM_FAST_LOAD) {
    $env:ACOULM_FAST_LOAD = "1"
}
$gpuCache = Join-Path $env:ACOULM_HOME "gpu_cache"
$null = New-Item -ItemType Directory -Force -Path $gpuCache -ErrorAction SilentlyContinue
$env:OV_CACHE_DIR = $gpuCache

$runScript = Join-Path $scriptDir "run.ps1"
if (-not (Test-Path -LiteralPath $runScript)) {
    throw "Missing run.ps1 at $runScript"
}

$argList = @($Model, "--server", "--port", "$Port")
if (-not [string]::IsNullOrWhiteSpace($Device)) {
    $argList += @("--device", $Device.Trim().ToUpperInvariant())
}
if ($ExtraArgs) {
    $argList += $ExtraArgs
}

Write-Host "[BackendHost] Starting npu_wrapper (port $Port). Leave this process running for instant acoulm restarts." -ForegroundColor Cyan
& $runScript @argList
