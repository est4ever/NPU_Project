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
    # Import variables from setupvars.bat into this PowerShell process.
    cmd /c "call `"$setupvars`" > nul 2>&1 && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], [EnvironmentVariableTarget]::Process)
        }
    }
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
if ($LASTEXITCODE -ne 0) {
    Pop-Location
    throw "CMake configure failed with exit code $LASTEXITCODE"
}

Write-Host "🔨 Building (Release)..."
cmake --build build --config Release
if ($LASTEXITCODE -ne 0) {
    Pop-Location
    throw "CMake build failed with exit code $LASTEXITCODE"
}

# --- Stage dist/ (portable runtime bundle) ---
$exeSrc    = Join-Path $scriptDir "build\Release\npu_wrapper.exe"
$distDir   = Join-Path $scriptDir "dist"
$openvinoRoot = Split-Path -Parent $setupvars
$ovinoBin  = Join-Path $openvinoRoot "runtime\bin\intel64\Release"
$ovinoLib  = Join-Path $openvinoRoot "runtime\lib\intel64\Release"

Write-Host "Staging dist/ ..."
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

# Stop any running npu_wrapper so we can overwrite the exe
Get-Process -Name "npu_wrapper" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

Copy-Item -Force $exeSrc (Join-Path $distDir "npu_wrapper.exe")
if (Test-Path $ovinoBin) {
    Copy-Item -Recurse -Force (Join-Path $ovinoBin "*") $distDir
} else {
    Write-Warning "OpenVINO bin dir not found at $ovinoBin - skipping DLL copy"
}
# Inference plugins (NPU/GPU/CPU) — needed for portable dist\ without setupvars.bat
if (Test-Path $ovinoLib) {
    Copy-Item -Force (Join-Path $ovinoLib "*.dll") $distDir -ErrorAction SilentlyContinue
}
foreach ($dll in @("msvcp140.dll", "vcruntime140.dll")) {
    $src = "C:\Windows\System32\$dll"
    if (Test-Path $src) { Copy-Item -Force $src (Join-Path $distDir $dll) }
}

Write-Host ""
Write-Host "Build complete!"
Write-Host "  npu_wrapper.exe -> dist\npu_wrapper.exe"
Write-Host "Run:"
Write-Host "  .\dist\npu_wrapper.exe"

Pop-Location
