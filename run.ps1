# NPU Wrapper - Automated Setup and Run Script (PowerShell)
# Usage: ./run.ps1 ./models/Qwen2.5-0.5B-Instruct --policy PERFORMANCE
# Picks executable from registry/backends_registry.json (selected_backend entrypoint).
# Builtin OpenVINO backends load setupvars.bat first; external backends run the entrypoint as-is.

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

function Resolve-BackendExecutable {
    param([string]$ProjectRoot)

    $defaultExe = Join-Path $ProjectRoot "dist\npu_wrapper.exe"
    $regPath = Join-Path $ProjectRoot "registry\backends_registry.json"
    if (-not (Test-Path -LiteralPath $regPath)) {
        return @{ Exe = $defaultExe; UseOpenVinoSetup = $true }
    }

    try {
        $reg = Get-Content -LiteralPath $regPath -Raw | ConvertFrom-Json
    } catch {
        return @{ Exe = $defaultExe; UseOpenVinoSetup = $true }
    }

    $selId = [string]$reg.selected_backend
    $backendList = @($reg.backends)
    $be = $null
    foreach ($b in $backendList) {
        if ([string]$b.id -eq $selId) {
            $be = $b
            break
        }
    }
    if (-not $be -and $backendList.Count -gt 0) {
        $be = $backendList[0]
    }
    if (-not $be) {
        return @{ Exe = $defaultExe; UseOpenVinoSetup = $true }
    }

    $entrypoint = [string]$be.entrypoint
    if ([string]::IsNullOrWhiteSpace($entrypoint)) {
        return @{ Exe = $defaultExe; UseOpenVinoSetup = $true }
    }

    if (-not [System.IO.Path]::IsPathRooted($entrypoint)) {
        $entrypoint = Join-Path $ProjectRoot $entrypoint
    }

    $type = [string]$be.type
    if ([string]::IsNullOrWhiteSpace($type)) {
        $type = "external"
    }

    $useOv = ($type -eq "builtin")
    return @{ Exe = $entrypoint; UseOpenVinoSetup = $useOv }
}

$resolved = Resolve-BackendExecutable -ProjectRoot $scriptDir
$targetExe = $resolved.Exe
$useOpenVinoEnv = [bool]$resolved.UseOpenVinoSetup

if ($useOpenVinoEnv) {
    Write-Host '[Setup] Resolving OpenVINO environment...' -ForegroundColor Cyan
    $distDir = Join-Path $scriptDir "dist"
    $bundledOpenVino = Test-Path -LiteralPath (Join-Path $distDir "openvino.dll")
    $ovPath = Find-OpenVINOSetupVars

    if ($ovPath -and (Test-Path -LiteralPath $ovPath)) {
        Write-Host '[Setup] Loading OpenVINO setupvars.bat (dev / full install).' -ForegroundColor Cyan
        $null = cmd /c "call `"$ovPath`" && set" | ForEach-Object {
            if ($_ -match '^([^=]+)=(.*)') {
                [Environment]::SetEnvironmentVariable($matches[1], $matches[2], [System.EnvironmentVariableTarget]::Process)
            }
        }
    } elseif ($bundledOpenVino) {
        # Release zip: build.ps1 copies runtime DLLs into dist\ — no separate OpenVINO SDK install needed.
        Write-Host '[Setup] Using bundled OpenVINO runtime in dist\.' -ForegroundColor Green
        $env:PATH = $distDir + [IO.Path]::PathSeparator + $env:PATH
    } else {
        Write-Host '[Error] No OpenVINO runtime available.' -ForegroundColor Red
        Write-Host '  Option A — End user: install from a GitHub Release (or run install.ps1) so dist\ contains npu_wrapper.exe and OpenVINO DLLs.' -ForegroundColor Yellow
        Write-Host '  Option B — Developer: extract OpenVINO GenAI for Windows, set OPENVINO_GENAI_DIR to that folder, or put it under Downloads as in README.' -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host ('[Setup] External backend - skipping OpenVINO setupvars (entry: ' + $targetExe + ')') -ForegroundColor Cyan
}

if (-not (Test-Path -LiteralPath $targetExe)) {
    Write-Host ('[Error] Backend executable not found: ' + $targetExe) -ForegroundColor Red
    exit 1
}

Write-Host ('[Setup] Running: ' + $targetExe) -ForegroundColor Cyan
Write-Host ""

& $targetExe @args
exit $LASTEXITCODE
