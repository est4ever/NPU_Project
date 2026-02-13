# NPU_Project Build Script
# Usage: .\build.ps1            (normal rebuild)
#        .\build.ps1 -Clean     (clean rebuild)

param([switch]$Clean)

# Set OpenVINO environment (linsh's actual path)
$OV = "C:\Users\linsh\Downloads\openvino_genai_windows_2025.4.0.0_x86_64"
if (Test-Path "$OV\setupvars.bat") {
    Write-Host "Setting up OpenVINO environment..."
    cmd /c "`"$OV\setupvars.bat`" > nul 2>&1"
} else {
    Write-Host "⚠️  Warning: OpenVINO not found at $OV"
    Write-Host "Please verify the path in build.ps1"
}

# Clean build if requested
if ($Clean) {
    Write-Host "🧹 Cleaning build directory..."
    Remove-Item -Recurse -Force build -ErrorAction SilentlyContinue
    mkdir build | Out-Null
    Write-Host "✓ Build directory cleaned"
}

# Configure and build
Write-Host "🔨 Building project..."
Push-Location build
cmake -G "Visual Studio 17 2022" -A x64 .. | Out-Null
cmake --build . --config Release

Pop-Location

Write-Host ""
Write-Host "✓ Build complete!"
Write-Host "📦 Executable: dist/npu_wrapper.exe"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  cd C:\Users\$env:USERNAME\NPU_Project"
Write-Host "  .\dist\npu_wrapper.exe ./models/TinyLlama_ov"
