param(
    [string]$ModelPath = "./models/Qwen2.5-0.5B-Instruct",
    [int]$ApiPort = 8000,
    [int]$WebUiPort = 8080,
    [int]$TimeoutSeconds = 90,
    [switch]$SkipBuild,
    [string[]]$BackendArgs = @()
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

Write-Host "[Refresh] Project root: $scriptDir" -ForegroundColor Cyan

Write-Host "[Refresh] Stopping stale processes..." -ForegroundColor Yellow
Get-Process npu_wrapper -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "name = 'python.exe' OR name = 'pythonw.exe'" |
    Where-Object { $_.CommandLine -like '*open-webui*' -or $_.CommandLine -like '*open_webui*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

if (-not $SkipBuild) {
    Write-Host "[Refresh] Building project..." -ForegroundColor Yellow
    .\build.ps1
}

$srcExe = Join-Path $scriptDir "build\Release\npu_wrapper.exe"
$dstExe = Join-Path $scriptDir "dist\npu_wrapper.exe"
if (-not (Test-Path $srcExe)) {
    throw "[Refresh] Build output not found: $srcExe"
}

Write-Host "[Refresh] Deploying latest executable to dist/..." -ForegroundColor Yellow
$copied = $false
for ($i = 0; $i -lt 12 -and -not $copied; $i++) {
    try {
        Copy-Item -Force $srcExe $dstExe
        $copied = $true
    } catch {
        Start-Sleep -Milliseconds 500
    }
}
if (-not $copied) {
    throw "[Refresh] Could not copy npu_wrapper.exe to dist/. Ensure no process is locking the file."
}

Write-Host "[Refresh] Starting stack..." -ForegroundColor Yellow
$startArgs = @(
    "-ModelPath", $ModelPath,
    "-ApiPort", $ApiPort,
    "-WebUiPort", $WebUiPort,
    "-TimeoutSeconds", $TimeoutSeconds
)
if ($BackendArgs.Count -gt 0) {
    $startArgs += "-BackendArgs"
    $startArgs += $BackendArgs
}

& .\start_openwebui_stack.ps1 @startArgs

Write-Host "[Refresh] Done. Stack restarted with latest build." -ForegroundColor Green
