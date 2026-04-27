# Export a local Hugging Face snapshot (config.json + *.safetensors) to OpenVINO IR using Optimum Intel.
# Used by portable_setup.ps1 and start_app.ps1. Requires PyTorch + transformers (pulled in by optimum-intel).
# Multimodal / exotic architectures may fail; use a text causal LM for the most reliable path.

param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [string]$HfModelDir,
    [Parameter(Mandatory = $true)]
    [string]$IrOutputDir,
    [ValidateSet("fp32", "fp16", "int8", "int4")]
    [string]$WeightFormat = "int8",
    [switch]$TrustRemoteCode
)

$ErrorActionPreference = "Stop"

function Get-ProjectPythonExe {
    param([string]$Root)
    $py = Join-Path $Root "venv\Scripts\python.exe"
    if (Test-Path -LiteralPath $py) { return $py }
    return "python"
}

function Get-OptimumCliExe {
    param([string]$PythonExe)
    $dir = Split-Path -Parent $PythonExe
    $cli = Join-Path $dir "optimum-cli.exe"
    if (Test-Path -LiteralPath $cli) { return $cli }
    return $null
}

function Install-OptimumOpenVinoExport {
    param([string]$PythonExe)
    Write-Host "[IR] Installing optimum-intel[openvino] (first run can take several minutes)..." -ForegroundColor Yellow
    $oldEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $PythonExe -m pip install -U "optimum" "optimum-intel[openvino]" "openvino" 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "[IR] pip install optimum-intel[openvino] failed with exit code $LASTEXITCODE"
        }
    } finally {
        $ErrorActionPreference = $oldEap
    }
}

function Install-OrUpgradeTransformers {
    param([string]$PythonExe)
    Write-Host "[IR] Updating transformers within optimum-intel compatible range..." -ForegroundColor Yellow
    $oldEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $PythonExe -m pip install -U "transformers>=4.57.0,<4.58" "huggingface_hub<1.0" 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "[IR] pip install compatible transformers failed with exit code $LASTEXITCODE"
        }
    } finally {
        $ErrorActionPreference = $oldEap
    }
}

function Invoke-NativeCommandCapture {
    param(
        [string]$ExePath,
        [string[]]$CommandArgs
    )
    $oldEap = $ErrorActionPreference
    try {
        # Native tools often print useful diagnostics to stderr; keep PowerShell from
        # converting that stream into terminating errors so we can inspect exit codes.
        $ErrorActionPreference = "Continue"
        $out = & $ExePath @CommandArgs 2>&1
        $code = $LASTEXITCODE
        return [pscustomobject]@{
            Output = @($out)
            ExitCode = $code
        }
    } finally {
        $ErrorActionPreference = $oldEap
    }
}

$HfModelDir = [System.IO.Path]::GetFullPath($HfModelDir)
$IrOutputDir = [System.IO.Path]::GetFullPath($IrOutputDir)
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

if (-not (Test-Path -LiteralPath $HfModelDir -PathType Container)) {
    throw "[IR] Model folder not found: $HfModelDir"
}
if (-not (Test-Path -LiteralPath (Join-Path $HfModelDir "config.json"))) {
    throw "[IR] Missing config.json under: $HfModelDir"
}

function Remove-PathWithRetry {
    param(
        [string]$Path,
        [int]$Retries = 8,
        [int]$DelayMs = 600
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            Start-Sleep -Milliseconds $DelayMs
        }
    }
    return $false
}

function Move-PathWithRetry {
    param(
        [string]$From,
        [string]$To,
        [int]$Retries = 8,
        [int]$DelayMs = 600
    )
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            Move-Item -LiteralPath $From -Destination $To -Force -ErrorAction Stop
            return $true
        } catch {
            Start-Sleep -Milliseconds $DelayMs
        }
    }
    return $false
}

if (Test-Path -LiteralPath $IrOutputDir) {
    $existingXml = Get-ChildItem -LiteralPath $IrOutputDir -Filter "*.xml" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existingXml) {
        Write-Host "[IR] Already present: $($existingXml.FullName)" -ForegroundColor Green
        exit 0
    }
}

# Export into a fresh temp folder first. This avoids Optimum's internal merge/unlink step
# failing on Windows when a stale file is locked (WinError 32).
$tmpOut = $IrOutputDir + ".tmp-" + ([Guid]::NewGuid().ToString("N"))
if (Test-Path -LiteralPath $tmpOut) {
    $null = Remove-PathWithRetry -Path $tmpOut
}
New-Item -ItemType Directory -Path $tmpOut -Force | Out-Null

$python = Get-ProjectPythonExe -Root $ProjectRoot
$cli = Get-OptimumCliExe -PythonExe $python
if (-not $cli) {
    Install-OptimumOpenVinoExport -PythonExe $python
    $cli = Get-OptimumCliExe -PythonExe $python
}
if (-not $cli) {
    throw "[IR] optimum-cli.exe not found next to $python after install."
}

$exportArgs = @(
    "export", "openvino",
    "--model", $HfModelDir,
    "--task", "text-generation-with-past",
    "--weight-format", $WeightFormat
)
if ($TrustRemoteCode) {
    $exportArgs += "--trust-remote-code"
}
$exportArgs += $tmpOut

Write-Host "[IR] optimum-cli $($exportArgs -join ' ')" -ForegroundColor Cyan
$firstRun = Invoke-NativeCommandCapture -ExePath $cli -CommandArgs $exportArgs
$exportOutput = @($firstRun.Output)
$firstExit = [int]$firstRun.ExitCode
$exportOutput | Out-Host
if ($firstExit -ne 0) {
    $outputText = ($exportOutput | ForEach-Object { "$_" }) -join "`n"
    $needsOpenVinoSupportInstall = ($outputText -match "(?i)usage:\s*optimum-cli") -and (-not ($outputText -match "(?i)usage:\s*optimum-cli\s+export\s+openvino"))
    if ($needsOpenVinoSupportInstall) {
        Write-Host "[IR] optimum-cli export openvino appears unavailable; installing/upgrading optimum-intel..." -ForegroundColor Yellow
        Install-OptimumOpenVinoExport -PythonExe $python
        $cli = Get-OptimumCliExe -PythonExe $python
        if (-not $cli) {
            throw "[IR] optimum-cli.exe missing after reinstall."
        }
        Write-Host "[IR] Retrying optimum export after optimum-intel install..." -ForegroundColor Yellow
        $retryAfterInstall = Invoke-NativeCommandCapture -ExePath $cli -CommandArgs $exportArgs
        $exportOutput = @($retryAfterInstall.Output)
        $firstExit = [int]$retryAfterInstall.ExitCode
        $exportOutput | Out-Host
        $outputText = ($exportOutput | ForEach-Object { "$_" }) -join "`n"
    }
    $needsTransformersUpdate = ($firstExit -ne 0) -and ($outputText -match "does not recognize this architecture" -or $outputText -match "transformers is out of date" -or $outputText -match "KeyError: '")
    if ($needsTransformersUpdate) {
        Install-OrUpgradeTransformers -PythonExe $python
        Write-Host "[IR] Retrying optimum export after transformers update..." -ForegroundColor Yellow
        $retryRun = Invoke-NativeCommandCapture -ExePath $cli -CommandArgs $exportArgs
        $retryOutput = @($retryRun.Output)
        $retryExit = [int]$retryRun.ExitCode
        $retryOutput | Out-Host
        if ($retryExit -ne 0) {
            $retryText = ($retryOutput | ForEach-Object { "$_" }) -join "`n"
            if ($retryText -match "does not recognize this architecture" -or $retryText -match "KeyError: '") {
                throw "[IR] This HF model architecture is not supported by the current optimum-intel/OpenVINO export stack in this environment.`nUse a model family that current exporters support, provide a pre-exported OpenVINO IR/GGUF model, or switch to an external backend that can load this checkpoint directly.`n$retryText"
            }
            throw "[IR] optimum-cli export failed after transformers update (exit code $retryExit).`n$retryText"
        }
    } else {
        throw "[IR] optimum-cli export failed with exit code $firstExit (multimodal or unsupported architectures often need a different export path).`n$outputText"
    }
}

$xml = Get-ChildItem -LiteralPath $tmpOut -Filter "*.xml" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $xml) {
    throw "[IR] Export reported success but no .xml was found under: $tmpOut"
}

# Swap temp output into final location.
if (Test-Path -LiteralPath $IrOutputDir) {
    $backup = $IrOutputDir + ".bak-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    Write-Host "[IR] Existing IR output detected. Backing up to: $backup" -ForegroundColor Yellow
    if (-not (Move-PathWithRetry -From $IrOutputDir -To $backup)) {
        throw "[IR] Could not move existing IR folder out of the way (it may be locked by another process). Close any running backend (npu_wrapper) and retry.`n  From: $IrOutputDir`n  To:   $backup"
    }
}

if (-not (Move-PathWithRetry -From $tmpOut -To $IrOutputDir)) {
    throw "[IR] Export finished but could not finalize output folder (likely locked). Close any running backend (npu_wrapper) and retry.`n  From: $tmpOut`n  To:   $IrOutputDir"
}

$finalXml = Get-ChildItem -LiteralPath $IrOutputDir -Filter "*.xml" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Host "[IR] Export complete: $($finalXml.FullName)" -ForegroundColor Green
