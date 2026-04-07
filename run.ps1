# NPU Wrapper - Automated Setup and Run Script (PowerShell)
# Usage: ./run.ps1 ./models/Qwen2.5-0.5B-Instruct --policy PERFORMANCE

# Get the directory where this script is located
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-OpenVINOSetupVars {
    if ($env:OPENVINO_GENAI_DIR) {
        $p = Join-Path $env:OPENVINO_GENAI_DIR "setupvars.bat"
        if (Test-Path $p) { return $p }
    }

    $candidates = @(
        "$HOME\Downloads\openvino_genai_windows_2026.0.0.0_x86_64\setupvars.bat",
        "$HOME\Downloads\openvino_genai_windows_2025.4.1.0_x86_64\setupvars.bat"
    )

    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }

    $dl = Join-Path $HOME "Downloads"
    if (Test-Path $dl) {
        $hit = Get-ChildItem $dl -Recurse -Filter setupvars.bat -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "openvino_genai_windows_" } |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    return $null
}

# Setup OpenVINO environment
Write-Host "[Setup] Loading OpenVINO environment..." -ForegroundColor Cyan
$ovPath = Find-OpenVINOSetupVars

if (-not (Test-Path $ovPath)) {
    Write-Host "[Error] OpenVINO setupvars.bat not found at: $ovPath" -ForegroundColor Red
    Write-Host "[Error] Set OPENVINO_GENAI_DIR or install OpenVINO GenAI archive under your Downloads folder." -ForegroundColor Red
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
& "$scriptDir\dist\npu_wrapper.exe" @args

exit $LASTEXITCODE
