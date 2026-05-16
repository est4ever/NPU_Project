# Pick OpenVINO IR when available; one-time HF->IR export for fast loads (snappy path).
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [switch]$BackgroundExportOnly
)

$ErrorActionPreference = "Stop"
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

function Test-DirHasOpenVINOIr {
    param([string]$FullPath)
    if ([string]::IsNullOrWhiteSpace($FullPath) -or -not (Test-Path -LiteralPath $FullPath -PathType Container)) {
        return $false
    }
    return $null -ne @(Get-ChildItem -LiteralPath $FullPath -Filter "*.xml" -File -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Test-DirIsHfCheckpointWithoutIr {
    param([string]$FullPath)
    if ([string]::IsNullOrWhiteSpace($FullPath) -or -not (Test-Path -LiteralPath $FullPath -PathType Container)) {
        return $false
    }
    if (Test-DirHasOpenVINOIr -FullPath $FullPath) { return $false }
    $st = @(Get-ChildItem -LiteralPath $FullPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.(?i)safetensors$' })
    return ($st.Count -gt 0)
}

function Update-RegistryToModel {
    param(
        [string]$Id,
        [string]$RelativePath,
        [string]$Format
    )
    $rp = Join-Path $ProjectRoot "registry\models_registry.json"
    if (-not (Test-Path -LiteralPath $rp)) { return }
    $reg = Get-Content -LiteralPath $rp -Raw | ConvertFrom-Json
    $found = $false
    foreach ($m in @($reg.models)) {
        if ([string]$m.id -eq $Id) {
            $m.path = $RelativePath
            $m.format = $Format
            $m.status = "ready"
            $found = $true
        }
    }
    if (-not $found) {
        $reg.models += [pscustomobject]@{
            id      = $Id
            path    = $RelativePath
            format  = $Format
            backend = "openvino"
            status  = "ready"
        }
    }
    $reg.selected_model = $Id
    $reg.auto_select_best_model = $true
    ($reg | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $rp -Encoding UTF8
}

function Get-RelativeModelPath {
    param([string]$FullPath)
    $proj = $ProjectRoot
    $target = [System.IO.Path]::GetFullPath($FullPath)
    if (-not $target.StartsWith($proj, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $FullPath
    }
    $rest = $target.Substring($proj.Length).TrimStart([char[]]@('\', '/'))
    return "./" + ($rest -replace '\\', '/')
}

# 1) Any *-ov-ir folder under models/ (fastest load)
$modelsRoot = Join-Path $ProjectRoot "models"
if (Test-Path -LiteralPath $modelsRoot) {
    foreach ($dir in @(Get-ChildItem -LiteralPath $modelsRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -like "*-ov-ir" -and (Test-DirHasOpenVINOIr -FullPath $dir.FullName)) {
            $rel = Get-RelativeModelPath -FullPath $dir.FullName
            $id = ($dir.Name -replace '-ov-ir$', '') -replace '[^a-zA-Z0-9]+', '-'
            Update-RegistryToModel -Id "fast-ir-$id" -RelativePath $rel -Format "openvino"
            Write-Host "[Fast] Using OpenVINO IR (fast load): $rel" -ForegroundColor Green
            return $rel
        }
    }
}

# 2) Known HF checkpoint beside GGUF -> export once to IR
$hfDirs = @(
    (Join-Path $modelsRoot "Qwen2.5-3B-Instruct"),
    (Join-Path $modelsRoot "Qwen2.5-0.5B-Instruct")
)
$exportScript = Join-Path $ProjectRoot "Export-HfFolderToOpenVinoIR.ps1"
$markerDir = Join-Path $ProjectRoot "registry"
$null = New-Item -ItemType Directory -Force -Path $markerDir -ErrorAction SilentlyContinue

foreach ($hfDir in $hfDirs) {
    if (-not (Test-DirIsHfCheckpointWithoutIr -FullPath $hfDir)) { continue }
    $name = [System.IO.Path]::GetFileName($hfDir.TrimEnd('\', '/'))
    $irFull = Join-Path ([System.IO.Path]::GetDirectoryName($hfDir)) "$name-ov-ir"
    $marker = Join-Path $markerDir "ir_export_$name.done"
    $failMarker = Join-Path $markerDir "ir_export_$name.failed"

    if (Test-DirHasOpenVINOIr -FullPath $irFull) {
        $rel = Get-RelativeModelPath -FullPath $irFull
        Update-RegistryToModel -Id "fast-ir-$name" -RelativePath $rel -Format "openvino"
        Write-Host "[Fast] Using existing IR: $rel" -ForegroundColor Green
        return $rel
    }

    if (Test-Path -LiteralPath $failMarker) {
        Write-Host "[Fast] IR export previously failed for $name; keeping GGUF path." -ForegroundColor DarkYellow
        continue
    }

    if ($env:ACOULM_AUTO_EXPORT_IR -eq "0") {
        Write-Host "[Fast] HF folder $name found; set ACOULM_AUTO_EXPORT_IR=1 to export IR once (much faster daily loads)." -ForegroundColor DarkYellow
        continue
    }

  if (-not (Test-Path -LiteralPath $exportScript)) { continue }

    $exportBlock = {
        param($ProjectRoot, $hfDir, $irFull, $name, $exportScript, $marker, $failMarker)
        try {
            & $exportScript -ProjectRoot $ProjectRoot -HfModelDir $hfDir -IrOutputDir $irFull -TrustRemoteCode -WeightFormat int8
            if (Test-DirHasOpenVINOIr -FullPath $irFull) {
                $rel = "./models/" + (Split-Path $irFull -Leaf)
                $regPath = Join-Path $ProjectRoot "registry\models_registry.json"
                if (Test-Path $regPath) {
                    $reg = Get-Content $regPath -Raw | ConvertFrom-Json
                    $id = "fast-ir-$name"
                    $reg.models += [pscustomobject]@{ id = $id; path = $rel; format = "openvino"; backend = "openvino"; status = "ready" }
                    $reg.selected_model = $id
                    $reg.auto_select_best_model = $true
                    ($reg | ConvertTo-Json -Depth 10) | Set-Content $regPath -Encoding UTF8
                }
                Set-Content -LiteralPath $marker -Value ([DateTime]::UtcNow.ToString("o")) -Encoding UTF8
            }
        } catch {
            Set-Content -LiteralPath $failMarker -Value $_.Exception.Message -Encoding UTF8
        }
    }

    if ($BackgroundExportOnly) {
        Write-Host "[Fast] Background IR export started for $name (use GGUF until done; then acoulm loads IR in seconds)." -ForegroundColor Cyan
        Start-Job -Name "AcouLM-IR-$name" -ScriptBlock $exportBlock -ArgumentList $ProjectRoot, $hfDir, $irFull, $name, $exportScript, $marker, $failMarker | Out-Null
        return $null
    }

    Write-Host "[Fast] One-time export to OpenVINO IR for $name (10-40 min; then loads in seconds)..." -ForegroundColor Cyan
    try {
        & $exportScript -ProjectRoot $ProjectRoot -HfModelDir $hfDir -IrOutputDir $irFull -TrustRemoteCode -WeightFormat int8
        if (Test-DirHasOpenVINOIr -FullPath $irFull) {
            $rel = Get-RelativeModelPath -FullPath $irFull
            Update-RegistryToModel -Id "fast-ir-$name" -RelativePath $rel -Format "openvino"
            Set-Content -LiteralPath $marker -Value ([DateTime]::UtcNow.ToString("o")) -Encoding UTF8
            Write-Host "[Fast] IR ready: $rel - restart acoulm for fast load." -ForegroundColor Green
            return $rel
        }
    } catch {
        Set-Content -LiteralPath $failMarker -Value $_.Exception.Message -Encoding UTF8
        Write-Host "[Fast] IR export failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

return $null
