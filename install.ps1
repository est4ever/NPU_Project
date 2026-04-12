# Loomis — remote installer (OpenClaw-style one-liner target)
# Usage (from README):
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/est4ever/Loomis/main/install.ps1' -UseBasicParsing)))"
# With a specific prebuilt release:
#   ... install.ps1')))" -ReleaseTag v1.0.0
#
# Requires: git (https://git-scm.com/download/win). Prebuilt zip must exist on GitHub Releases (see README).

param(
    [string]$InstallDir = "",
    [string]$ReleaseTag = "latest",
    [string]$Branch = "main",
    [string]$GitRemote = "https://github.com/est4ever/Loomis.git",
    [string]$GitHubRepoPath = "est4ever/Loomis",
    [string]$DistAssetName = "loomis-dist-windows-x64.zip"
)

$ErrorActionPreference = "Stop"
if (-not $InstallDir) {
    $InstallDir = Join-Path $env:USERPROFILE "Loomis"
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

function Get-DistDownloadUrl {
    param([string]$Tag, [string]$RepoPath, [string]$Asset)
    $TagNorm = $Tag.Trim()
    if (-not $TagNorm -or $TagNorm -eq "latest") {
        return "https://github.com/$RepoPath/releases/latest/download/$Asset"
    }
    return "https://github.com/$RepoPath/releases/download/$TagNorm/$Asset"
}

Write-Host "Loomis install" -ForegroundColor Cyan
Write-Host "  Install dir   : $InstallDir"
Write-Host "  Source branch : $Branch"
Write-Host "  Prebuilt tag  : $(if ($ReleaseTag -eq 'latest' -or -not $ReleaseTag.Trim()) { 'latest release' } else { $ReleaseTag.Trim() })"
Write-Host ""

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    Write-Host "git is required. Install from https://git-scm.com/download/win and re-run this script." -ForegroundColor Red
    exit 1
}

if (Test-Path $InstallDir) {
    $gitDir = Join-Path $InstallDir ".git"
    if (Test-Path $gitDir) {
        Write-Host "Updating existing clone..."
        Push-Location $InstallDir
        try {
            git fetch --depth 1 origin $Branch
            git checkout $Branch
            git pull --ff-only origin $Branch
        } finally {
            Pop-Location
        }
    } else {
        Write-Host "Directory exists but is not a git repo: $InstallDir" -ForegroundColor Red
        Write-Host "Remove or rename it, or pass -InstallDir to an empty path."
        exit 1
    }
} else {
    Write-Host "Cloning $GitRemote (branch $Branch)..."
    $parent = Split-Path -Parent $InstallDir
    $leaf = Split-Path -Leaf $InstallDir
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    git clone --depth 1 --branch $Branch $GitRemote $InstallDir
    if ($LASTEXITCODE -ne 0) {
        throw "git clone failed with exit code $LASTEXITCODE"
    }
}

$distDir = Join-Path $InstallDir "dist"
$url = Get-DistDownloadUrl -Tag $ReleaseTag -RepoPath $GitHubRepoPath -Asset $DistAssetName
$tmpZip = Join-Path ([System.IO.Path]::GetTempPath()) ("loomis-dist-" + [Guid]::NewGuid().ToString("N") + ".zip")

Write-Host "Downloading prebuilt runtime: $url"
try {
    Invoke-WebRequest -Uri $url -OutFile $tmpZip -UseBasicParsing
} catch {
    Write-Host ""
    Write-Host "Download failed. Common causes:" -ForegroundColor Yellow
    Write-Host "  - No GitHub Release yet, or the asset is not named exactly '$DistAssetName'"
    Write-Host "  - Wrong -ReleaseTag (use 'latest' or an existing tag like v1.0.0)"
    Write-Host "See README: 'What goes on GitHub vs Releases'."
    throw
}

if (Test-Path $distDir) {
    Remove-Item -Recurse -Force $distDir
}
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
Expand-Archive -Path $tmpZip -DestinationPath $distDir -Force
Remove-Item -Force $tmpZip -ErrorAction SilentlyContinue

$exe = Join-Path $distDir "npu_wrapper.exe"
if (-not (Test-Path $exe)) {
    Write-Host ""
    Write-Host "Zip extracted, but npu_wrapper.exe not found under dist\." -ForegroundColor Yellow
    Write-Host "Release zips must be built with the contents of dist\ at the root of the zip (not a nested dist\ folder)."
}

Write-Host ""
Write-Host "Done. Next steps:" -ForegroundColor Green
Write-Host "  1. Install OpenVINO GenAI runtime (see README)."
Write-Host "  2. Put an OpenVINO IR model under .\models\..."
Write-Host "  3.  cd `"$InstallDir`""
Write-Host "      .\portable_setup.ps1"
Write-Host "   or .\start_app.ps1"
Write-Host ""
