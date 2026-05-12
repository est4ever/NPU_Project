param(
    [string]$Host = "127.0.0.1",
    [int]$Port = 8800,
    [string]$DbPath = ".\telemetry\usage.sqlite",
    [string]$Salt = "",
    [switch]$OpenSummary
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$pythonExe = Join-Path $scriptDir "venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $pythonExe)) {
    $pythonExe = "python"
}

$resolvedDb = [System.IO.Path]::GetFullPath((Join-Path $scriptDir $DbPath))
$dbDir = Split-Path -Parent $resolvedDb
if (-not (Test-Path -LiteralPath $dbDir)) {
    New-Item -ItemType Directory -Path $dbDir | Out-Null
}

$args = @(
    "telemetry_server.py",
    "--host", $Host,
    "--port", "$Port",
    "--db", $resolvedDb
)

if (-not [string]::IsNullOrWhiteSpace($Salt)) {
    $args += @("--salt", $Salt)
}

Write-Host "[Telemetry] Starting receiver on http://$Host`:$Port" -ForegroundColor Cyan
Write-Host "[Telemetry] DB: $resolvedDb" -ForegroundColor DarkGray
& $pythonExe @args

