@echo off
setlocal enabledelayedexpansion

REM NPU Wrapper - Automated Setup and Run Script
REM Usage: run.bat ./models/Qwen2.5-0.5B-Instruct --policy PERFORMANCE

REM Get the directory where this script is located
set SCRIPT_DIR=%~dp0

REM Setup OpenVINO environment
echo [Setup] Loading OpenVINO environment...
call "%USERPROFILE%\Downloads\openvino_genai_windows_2026.0.0.0_x86_64\setupvars.bat"

if errorlevel 1 (
    echo [Error] Failed to load OpenVINO setupvars.bat
    echo [Error] Make sure OpenVINO is installed at: %USERPROFILE%\Downloads\openvino_genai_windows_2026.0.0.0_x86_64\
    exit /b 1
)

REM Run the executable with all passed arguments
echo [Setup] Running npu_wrapper.exe...
"%SCRIPT_DIR%dist\npu_wrapper.exe" %*

endlocal
