# NPU_Project Build Script
# Usage: .\build.ps1            (normal rebuild)
#        .\build.ps1 -Clean     (clean rebuild)
# Optional:
#   $env:OPENVINO_GENAI_DIR="C:\path\to\openvino_genai_windows_2025.4.0.0_x86_64"
#   .\build.ps1

param([switch]$Clean)

<<<<<<< Updated upstream
# Set OpenVINO environment
$OV = "C:\Users\$env:USERNAME\Downloads\openvino_genai_windows_2025.4.0.0_x86_64"
if (Test-Path "$OV\setupvars.bat") {
    Write-Host "Setting up OpenVINO environment..."
    # Load env vars from setupvars.bat into the current PowerShell session
    $envOutput = cmd /c "call `"$OV\setupvars.bat`" > nul && set"
    foreach ($line in $envOutput) {
        $idx = $line.IndexOf('=')
        if ($idx -gt 0) {
            $name = $line.Substring(0, $idx)
            $value = $line.Substring($idx + 1)
            Set-Item -Path "Env:$name" -Value $value
        }
    }
} else {
    Write-Host "Warning: OpenVINO not found at $OV"
    Write-Host "Please verify the path in build.ps1"
=======
$ErrorActionPreference = "Stop"

function Find-OpenVINOSetupVars {
    # 1) User-provided env var (best)
    if ($env:OPENVINO_GENAI_DIR) {
        $p = Join-Path $env:OPENVINO_GENAI_DIR "setupvars.bat"
        if (Test-Path $p) { return $p }
    }

    # 2) Common default locations
    $candidates = @(
        "$HOME\Downloads\openvino_genai_windows_2025.4.0.0_x86_64\setupvars.bat",
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
>>>>>>> Stashed changes
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
    Write-Host "    `$env:OPENVINO_GENAI_DIR = `"C:\Users\$env:USERNAME\Downloads\openvino_genai_windows_2025.4.0.0_x86_64`""
    Write-Host "    Then rerun: .\build.ps1"
    throw "OpenVINO not configured."
}

# --- Clean build if requested ---
if ($Clean) {
<<<<<<< Updated upstream
    Write-Host "Cleaning build directory..."
    Remove-Item -Recurse -Force build -ErrorAction SilentlyContinue
    mkdir build | Out-Null
    Write-Host "Build directory cleaned"
}

# Configure and build
Write-Host "Building project..."
$env:CMAKE_PREFIX_PATH = "C:\Users\$env:USERNAME\Downloads\openvino_genai_windows_2025.4.0.0_x86_64\runtime\cmake"
Push-Location build
cmake -G "Visual Studio 17 2022" -A x64 -DCMAKE_PREFIX_PATH="$env:CMAKE_PREFIX_PATH" .. | Out-Null
cmake --build . --config Release
=======
    Write-Host "🧹 Cleaning build directory..."
    if (Test-Path "build") { Remove-Item -Recurse -Force "build" }
}

# --- Configure and build ---
Write-Host "🔧 Configuring..."
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
>>>>>>> Stashed changes

Write-Host "🔨 Building (Release)..."
cmake --build build --config Release

Write-Host ""
<<<<<<< Updated upstream
Write-Host "Build complete!"
Write-Host "Executable: dist/npu_wrapper.exe"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  cd C:\Users\$env:USERNAME\NPU_Project"
Write-Host "  .\dist\npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct"
=======
Write-Host "✓ Build complete!"
Write-Host "📦 If you use dist/, copy the exe (only if your CMake doesn't already do it):"
Write-Host "    copy build\Release\npu_wrapper.exe dist\npu_wrapper.exe"
Write-Host ""
Write-Host "Run:"
Write-Host "  cd $PWD\dist"
Write-Host "  .\npu_wrapper.exe"
>>>>>>> Stashed changes
