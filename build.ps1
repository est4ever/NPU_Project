# NPU_Project Build Script
# Usage: .\build.ps1            (normal rebuild)
#        .\build.ps1 -Clean     (clean rebuild)
# Optional:
#   $env:OPENVINO_GENAI_DIR="C:\path\to\openvino_genai_windows_2026.0.0.0_x86_64"
#   .\build.ps1

param([switch]$Clean)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $scriptDir

function Find-OpenVINOSetupVars {
    # 1) User-provided env var (best)
    if ($env:OPENVINO_GENAI_DIR) {
        $p = Join-Path $env:OPENVINO_GENAI_DIR "setupvars.bat"
        if (Test-Path $p) { return $p }
    }

    # 2) Common default locations
    $candidates = @(
        "$HOME\Downloads\openvino_genai_windows_2026.0.0.0_x86_64\setupvars.bat",
        "$HOME\Downloads\openvino_genai_windows_2025.4.1.0_x86_64\setupvars.bat"
    )

    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }

    # 3) Last resort: search in Downloads (a bit slower)
    $dl = Join-Path $HOME "Downloads"
    if (Test-Path $dl) {
        $hit = Get-ChildItem $dl -Recurse -Filter setupvars.bat -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -match "openvino_genai_windows_" } |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    return $null
}

# --- OpenVINO setup ---
$setupvars = Find-OpenVINOSetupVars
if ($setupvars) {
    Write-Host "Setting up OpenVINO environment:"
    Write-Host "  $setupvars"
    cmd /c "`"$setupvars`" > nul 2>&1"
} else {
    Write-Host "⚠️  OpenVINO setupvars.bat not found."
    Write-Host "    Set OPENVINO_GENAI_DIR to your extracted folder, e.g.:"
    Write-Host "    `$env:OPENVINO_GENAI_DIR = `"C:\Users\$env:USERNAME\Downloads\openvino_genai_windows_2026.0.0.0_x86_64`""
    Write-Host "    Then rerun: .\build.ps1"
    throw "OpenVINO not configured."
}

# --- Clean build if requested ---
if ($Clean) {
    Write-Host "🧹 Cleaning build directory..."
    if (Test-Path "build") { Remove-Item -Recurse -Force "build" }
}

if (-not (Test-Path "build")) {
    New-Item -ItemType Directory -Path "build" | Out-Null
}

# --- Configure and build ---
Write-Host "🔧 Configuring..."
cmake -S . -B build -G "Visual Studio 17 2022" -A x64

Write-Host "🔨 Building (Release)..."
cmake --build build --config Release

Write-Host ""
Write-Host "✓ Build complete!"
Write-Host "📦 If you use dist/, copy the exe (only if your CMake doesn't already do it):"
Write-Host "    copy build\Release\npu_wrapper.exe dist\npu_wrapper.exe"
Write-Host ""
Write-Host "Run:"
Write-Host "  cd $PWD\dist"
Write-Host "  .\npu_wrapper.exe"

Pop-Location
