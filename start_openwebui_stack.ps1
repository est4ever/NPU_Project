param(
    [string]$ModelPath = "./models/Qwen2.5-0.5B-Instruct",
    [int]$ApiPort = 8000,
    [int]$WebUiPort = 8080,
    [int]$AppPort = 5173,
    [int]$TimeoutSeconds = 90,
    [switch]$HideServiceWindows,
    [string[]]$BackendArgs = @()
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

Write-Host "[Compat] start_openwebui_stack.ps1 is deprecated." -ForegroundColor Yellow
Write-Host "[Compat] OpenWebUI startup has been removed from this project." -ForegroundColor Yellow
Write-Host "[Compat] Forwarding to start_app.ps1 (App Shell only)." -ForegroundColor Yellow
if ($PSBoundParameters.ContainsKey("WebUiPort")) {
    Write-Host "[Compat] Ignoring -WebUiPort=$WebUiPort" -ForegroundColor DarkYellow
}

$forwardArgs = @{
    ModelPath      = $ModelPath
    ApiPort        = $ApiPort
    AppPort        = $AppPort
    TimeoutSeconds = $TimeoutSeconds
}
if ($HideServiceWindows) {
    $forwardArgs.HideServiceWindows = $true
}
if ($BackendArgs.Count -gt 0) {
    $forwardArgs.BackendArgs = $BackendArgs
}

& "$scriptDir\start_app.ps1" @forwardArgs
