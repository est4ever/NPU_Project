# Restarts AcouLM backend (npu_wrapper) and the app shell (python http.server), then launches start_app.ps1.
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Stop-AppShellServer {
    param([int]$Port = 5173)
    Get-CimInstance Win32_Process -Filter "name = 'python.exe' OR name = 'pythonw.exe'" |
        Where-Object {
            $_.CommandLine -like "*http.server $Port*" -and
            $_.CommandLine -like "*--directory app_shell*"
        } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

Get-Process -Name "npu_wrapper" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Stop-AppShellServer -Port 5173
Start-Sleep -Seconds 1

Set-Location -LiteralPath $scriptDir
$start = Join-Path $scriptDir "start_app.ps1"
if (-not (Test-Path -LiteralPath $start)) {
    Write-Error "Missing start_app.ps1 at $start"
    exit 1
}

Start-Process powershell -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $start -WindowStyle Normal
