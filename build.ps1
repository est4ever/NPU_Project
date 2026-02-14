# NPU_Project Build Script
# Usage: .\build.ps1            (normal rebuild)
#        .\build.ps1 -Clean     (clean rebuild)

param([switch]$Clean)

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
}

# Clean build if requested
if ($Clean) {
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

Pop-Location

Write-Host ""
Write-Host "Build complete!"
Write-Host "Executable: dist/npu_wrapper.exe"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  cd C:\Users\$env:USERNAME\NPU_Project"
Write-Host "  .\dist\npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct"
