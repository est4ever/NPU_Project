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
    Write-Host '[Setup] Loading OpenVINO environment...' -ForegroundColor Cyan
    $ovPath = Find-OpenVINOSetupVars

    if (-not (Test-Path $ovPath)) {
        Write-Host ('[Error] OpenVINO setupvars.bat not found at: ' + $ovPath) -ForegroundColor Red
        Write-Host '[Error] Set OPENVINO_GENAI_DIR or install OpenVINO GenAI archive under your Downloads folder.' -ForegroundColor Red
        exit 1
    }

    $null = cmd /c "call `"$ovPath`" && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], [System.EnvironmentVariableTarget]::Process)
        }
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
