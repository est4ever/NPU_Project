# tauri_build.ps1
# Build a release installer for NPU Companion (Tauri).
#
# Prerequisites: same as tauri_dev.ps1 PLUS icon files.
#
# ICONS (required before running this script):
#   1. Put a 512x512 PNG at  src-tauri\app-icon.png
#   2. Run once:  cargo tauri icon src-tauri\app-icon.png
#      This generates all required sizes in src-tauri\icons\
#
# Output (after successful build):
#   src-tauri\target\release\bundle\
#     msi\   – Windows installer
#     nsis\  – NSIS installer
#
# The release bundle expects npu_wrapper.exe to be next to the .exe.
# The build copies it automatically (see the Copy-Backend step below).

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $scriptDir

# --- Prereq checks ---
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Error "Rust/cargo not found. Install from https://rustup.rs"
    exit 1
}

if (-not (Get-Command "cargo-tauri" -ErrorAction SilentlyContinue)) {
    Write-Host "Installing tauri-cli..."
    cargo install tauri-cli --version "^2"
}

$backendSrc = Join-Path $scriptDir "build\Release\npu_wrapper.exe"
if (-not (Test-Path $backendSrc)) {
    Write-Error "npu_wrapper.exe not found. Run .\build.ps1 first."
    exit 1
}

$iconDir = Join-Path $scriptDir "src-tauri\icons"
if (-not (Test-Path $iconDir)) {
    Write-Error "Icon files missing. Follow the ICONS instructions at the top of this script."
    exit 1
}

# --- Copy backend binary next to where Tauri will place the exe ---
$releaseDir = Join-Path $scriptDir "src-tauri\target\release"
if (-not (Test-Path $releaseDir)) { New-Item -ItemType Directory -Path $releaseDir | Out-Null }
Copy-Item $backendSrc $releaseDir -Force
Write-Host "Copied npu_wrapper.exe -> $releaseDir"

# --- Build ---
Write-Host ""
Write-Host "Building NPU Companion release bundle..."
cargo tauri build
Write-Host ""
Write-Host "Done. Installer is in: src-tauri\target\release\bundle\"
