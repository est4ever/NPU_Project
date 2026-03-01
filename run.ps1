# NPU Wrapper - Automated Setup and Run Script (PowerShell)
# Usage: ./run.ps1 ./models/Qwen2.5-0.5B-Instruct --policy PERFORMANCE

param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Args
)

# Get the directory where this script is located
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Setup OpenVINO environment
Write-Host "[Setup] Loading OpenVINO environment..." -ForegroundColor Cyan
$ovPath = "$env:USERPROFILE\Downloads\openvino_genai_windows_2026.0.0.0_x86_64\setupvars.bat"

if (-not (Test-Path $ovPath)) {
    Write-Host "[Error] OpenVINO setupvars.bat not found at: $ovPath" -ForegroundColor Red
    Write-Host "[Error] Make sure OpenVINO is installed at: $env:USERPROFILE\Downloads\openvino_genai_windows_2026.0.0.0_x86_64\" -ForegroundColor Red
    exit 1
}

# Load OpenVINO environment using cmd
$output = cmd /c "call `"$ovPath`" && set" | ForEach-Object { 
    if ($_ -match '^([^=]+)=(.*)') {
        [Environment]::SetEnvironmentVariable($matches[1], $matches[2], [System.EnvironmentVariableTarget]::Process)
    }
}

Write-Host "[Setup] Running npu_wrapper.exe..." -ForegroundColor Cyan
Write-Host ""

# Run the executable with all passed arguments
& "$scriptDir\dist\npu_wrapper.exe" @Args

exit $LASTEXITCODE
