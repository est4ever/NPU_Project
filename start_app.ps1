param(
    [string]$ModelPath = "",
    [string]$Device = "",
    [int]$ApiPort = 8000,
    [int]$AppPort = 5173,
    [int]$TimeoutSeconds = 300,
    [switch]$HideServiceWindows,
    [string[]]$BackendArgs = @(),
    [switch]$AutoExportIr,
    [switch]$NoAutoExportIr,
    [switch]$AutoSelectBestModel,
    [switch]$PerformanceMode,
    [switch]$SkipAppShell,
    [switch]$OpenBrowser
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir
$deviceScript = Join-Path $scriptDir "scripts\AcouLM-Device.ps1"
if (Test-Path -LiteralPath $deviceScript) {
    . $deviceScript
    Initialize-AcouLMDeviceEnvironment
}
if ([string]::IsNullOrWhiteSpace($env:ACOULM_HOME)) {
    $env:ACOULM_HOME = $scriptDir
}
# acoulm.ps1 sets this so terminal-only launch cannot miss -SkipAppShell (profile/launcher edge cases).
if ($env:ACOULM_TERMINAL_ONLY -eq "1") {
    $SkipAppShell = $true
}
$autoExportIr = $true
if ($env:ACOULM_AUTO_EXPORT_IR -eq "0") { $autoExportIr = $false }
if ($env:ACOULM_AUTO_EXPORT_IR -eq "1") { $autoExportIr = $true }
if ($env:ACOULM_SNAPPY -eq "0") { $autoExportIr = $false }
if ($NoAutoExportIr) { $autoExportIr = $false }
if ($AutoExportIr) { $autoExportIr = $true }
$autoSelectBestModel = $false
$autoSelectModelEnv = [string]$env:ACOULM_AUTO_SELECT_MODEL
$perfModeEnabled = $false
if ($env:ACOULM_PERFORMANCE_MODE -eq "1") { $perfModeEnabled = $true }
if ($env:ACOULM_SNAPPY -eq "1") { $perfModeEnabled = $true }
if ($PerformanceMode) { $perfModeEnabled = $true }
$perfProfileFile = Join-Path $scriptDir "registry\performance_profile.json"
if ((-not $perfModeEnabled) -and (Test-Path -LiteralPath $perfProfileFile)) {
    try {
        $perfCfg = Get-Content -LiteralPath $perfProfileFile -Raw | ConvertFrom-Json
        if ([string]$perfCfg.policy -eq "PERFORMANCE") {
            $perfModeEnabled = $true
        }
    } catch {}
}

function Normalize-ModelPathString {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $t = $Path.Trim()
    while ($t.Length -ge 2 -and (
            ($t.StartsWith([char]34) -and $t.EndsWith([char]34)) -or
            ($t.StartsWith([char]39) -and $t.EndsWith([char]39))
        )) {
        $t = $t.Substring(1, $t.Length - 2).Trim()
    }
    return $t
}

function Get-RegistrySelectedModel {
    param([string]$FallbackPath = "./models")

    $result = [ordered]@{
        Path         = $FallbackPath
        Format       = "openvino"
        Id           = ""
        FromRegistry = $false
    }

    $modelsRegistry = Join-Path $scriptDir "registry\models_registry.json"
    if (-not (Test-Path $modelsRegistry)) {
        return $result
    }

    try {
        $reg = Get-Content -Path $modelsRegistry -Raw | ConvertFrom-Json
        $selectedId = [string]$reg.selected_model
        if ([string]::IsNullOrWhiteSpace($selectedId)) {
            return $result
        }
        foreach ($m in $reg.models) {
            if ($m.id -eq $selectedId -and -not [string]::IsNullOrWhiteSpace([string]$m.path)) {
                $result.Path = Normalize-ModelPathString ([string]$m.path)
                $result.Format = if ($m.format) { [string]$m.format } else { "openvino" }
                $result.Id = $selectedId
                $result.FromRegistry = $true
                return $result
            }
        }
    } catch {
        return $result
    }

    return $result
}

function Get-RegistryModels {
    param([string]$ProjectRoot)
    $result = @()
    $modelsRegistry = Join-Path $ProjectRoot "registry\models_registry.json"
    if (-not (Test-Path -LiteralPath $modelsRegistry)) { return $result }
    try {
        $reg = Get-Content -LiteralPath $modelsRegistry -Raw | ConvertFrom-Json
        foreach ($m in @($reg.models)) {
            if ($null -eq $m) { continue }
            $id = [string]$m.id
            $path = Normalize-ModelPathString ([string]$m.path)
            if ([string]::IsNullOrWhiteSpace($path)) { continue }
            $fmt = if ($m.format) { [string]$m.format } else { "" }
            $result += [pscustomobject]@{
                Id = $id
                Path = $path
                Format = $fmt
            }
        }
    } catch {}
    return $result
}

function Get-RegistryAutoSelectBestModel {
    param([string]$ProjectRoot)
    $modelsRegistry = Join-Path $ProjectRoot "registry\models_registry.json"
    if (-not (Test-Path -LiteralPath $modelsRegistry)) { return $null }
    try {
        $reg = Get-Content -LiteralPath $modelsRegistry -Raw | ConvertFrom-Json
        if ($reg.PSObject.Properties.Name -contains "auto_select_best_model") {
            return [bool]$reg.auto_select_best_model
        }
    } catch {}
    return $null
}

function Resolve-FullModelDirectory {
    param(
        [string]$ModelPath,
        [string]$ProjectRoot
    )
    $p = Normalize-ModelPathString $ModelPath
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    if ([System.IO.Path]::IsPathRooted($p)) {
        return [System.IO.Path]::GetFullPath($p)
    }
    $rel = $p -replace '^\.[\\/]', ''
    return [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $rel))
}

function Get-PathSizeMB {
    param([string]$FullPath)
    if ([string]::IsNullOrWhiteSpace($FullPath) -or -not (Test-Path -LiteralPath $FullPath)) { return 0.0 }
    try {
        if (Test-Path -LiteralPath $FullPath -PathType Leaf) {
            return [math]::Round(((Get-Item -LiteralPath $FullPath).Length / 1MB), 2)
        }
        $sum = (Get-ChildItem -LiteralPath $FullPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return 0.0 }
        return [math]::Round(($sum / 1MB), 2)
    } catch {
        return 0.0
    }
}

function Test-DirHasOpenVINOIr {
    param([string]$FullPath)
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return $false }
    if (-not (Test-Path -LiteralPath $FullPath -PathType Container)) { return $false }
    $xml = Get-ChildItem -LiteralPath $FullPath -Filter "*.xml" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    return [bool]$xml
}

function Test-DirIsHfCheckpointWithoutIr {
    param([string]$FullPath)
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return $false }
    if (-not (Test-Path -LiteralPath $FullPath -PathType Container)) { return $false }
    if (Test-DirHasOpenVINOIr -FullPath $FullPath) { return $false }
    $st = @(Get-ChildItem -LiteralPath $FullPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.(?i)safetensors$' })
    return ($st.Count -gt 0)
}

# OpenVINO GenAI LLMPipeline accepts an IR model directory or a path to a single .gguf (2025.2+ preview for GGUF).
function Try-ResolveRunnableModelBackendFull {
    param(
        [string]$RelPath,
        [string]$ProjectRoot,
        [ref]$BackendFullOut,
        [ref]$AmbiguousGgufOut
    )
    $AmbiguousGgufOut.Value = $false
    $BackendFullOut.Value = $null
    $full = Resolve-FullModelDirectory -ModelPath $RelPath -ProjectRoot $ProjectRoot
    if (-not $full -or -not (Test-Path -LiteralPath $full)) { return $false }

    if (Test-Path -LiteralPath $full -PathType Leaf) {
        if ($full -match '\.(?i)gguf$') {
            $BackendFullOut.Value = $full
            return $true
        }
        return $false
    }

    if (Test-DirHasOpenVINOIr -FullPath $full) {
        $BackendFullOut.Value = $full
        return $true
    }

    $ggufs = @(Get-ChildItem -LiteralPath $full -Filter "*.gguf" -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($ggufs.Count -eq 1) {
        $BackendFullOut.Value = $ggufs[0].FullName
        return $true
    }
    if ($ggufs.Count -gt 1) {
        $AmbiguousGgufOut.Value = $true
    }
    return $false
}

function Get-UnrunnableModelFolderHint {
    param([string]$FullPath)
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return "" }
    if (-not (Test-Path -LiteralPath $FullPath -PathType Container)) { return "" }
    $files = @(Get-ChildItem -LiteralPath $FullPath -File -Force -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        return "`n`nThis folder has no weight files (empty or download matched nothing). Re-run portable_setup.ps1: leave Files/patterns blank for a full repo, or use valid Hub globs (e.g. model.safetensors*,config.json,...)."
    }
    $hasSafetensors = $false
    foreach ($f in $files) {
        if ($f.Name -match '\.(?i)safetensors$') {
            $hasSafetensors = $true
            break
        }
    }
    if ($hasSafetensors) {
        return @"

Detected Hugging Face weights (.safetensors) in this folder.
Built-in npu_wrapper does not load raw Hub checkpoints.
Next: export to an OpenVINO IR directory (see Intel / optimum-intel docs), then point registry at that folder; or use a supported .gguf file.
README: Model Notes.
"@
    }
    return ""
}

function Convert-FullPathToRepoRelativeModelArg {
    param(
        [string]$ProjectRoot,
        [string]$FullPath
    )
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return $FullPath }
    $proj = [System.IO.Path]::GetFullPath($ProjectRoot)
    $target = [System.IO.Path]::GetFullPath($FullPath)
    if (-not $target.StartsWith($proj, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $FullPath
    }
    $rest = $target.Substring($proj.Length).TrimStart([char[]]@('\', '/'))
    return "./" + ($rest -replace '\\', '/')
}

function Update-ModelsRegistrySelectedPath {
    param(
        [string]$ProjectRoot,
        [string]$NewRelativePath,
        [string]$Format = "openvino"
    )
    $rp = Join-Path $ProjectRoot "registry\models_registry.json"
    if (-not (Test-Path -LiteralPath $rp)) { return }
    $reg = Get-Content -LiteralPath $rp -Raw | ConvertFrom-Json
    $sel = [string]$reg.selected_model
    foreach ($m in @($reg.models)) {
        if ([string]$m.id -eq $sel) {
            $m.path = $NewRelativePath
            $m.format = $Format
        }
    }
    ($reg | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $rp -Encoding UTF8
}

function Get-OpenVinoRunnableCandidates {
    param(
        [string]$ProjectRoot,
        [string]$PreferPath
    )
    $list = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    $add = {
        param([string]$p)
        $n = Normalize-ModelPathString $p
        if ([string]::IsNullOrWhiteSpace($n)) { return }
        if ($seen.ContainsKey($n)) { return }
        $seen[$n] = $true
        [void]$list.Add($n)
    }

    if (-not [string]::IsNullOrWhiteSpace($PreferPath)) {
        & $add $PreferPath
    }

    try {
        $regPath = Join-Path $ProjectRoot "registry\models_registry.json"
        if (Test-Path -LiteralPath $regPath) {
            $reg = Get-Content -LiteralPath $regPath -Raw | ConvertFrom-Json
            foreach ($m in $reg.models) {
                if ($m.path) { & $add ([string]$m.path) }
            }
        }
    } catch {}

    & $add "./models"
    return ,$list.ToArray()
}

function Get-RegistrySelectedBackend {
    param([string]$ProjectRoot)
    $default = [pscustomobject]@{ Type = "builtin"; Formats = @("openvino", "gguf") }
    $rp = Join-Path $ProjectRoot "registry\backends_registry.json"
    if (-not (Test-Path -LiteralPath $rp)) { return $default }
    try {
        $reg = Get-Content -LiteralPath $rp -Raw | ConvertFrom-Json
        $sel = [string]$reg.selected_backend
        foreach ($b in @($reg.backends)) {
            if ([string]$b.id -eq $sel) {
                $t = if ($b.type) { [string]$b.type } else { "builtin" }
                $formats = @("openvino", "gguf")
                if ($b.PSObject.Properties.Name -contains "formats" -and $b.formats) {
                    $formats = @($b.formats | ForEach-Object { [string]$_ })
                } elseif ($t -eq "external") {
                    $formats = @("hf", "safetensors", "gguf", "openvino")
                }
                return [pscustomobject]@{ Type = $t.Trim().ToLower(); Formats = $formats }
            }
        }
    } catch {}
    return $default
}

function Select-BestModelCandidate {
    param(
        [string]$ProjectRoot,
        [pscustomobject]$RegistryBackend,
        [string]$CurrentModelPath
    )

    $models = Get-RegistryModels -ProjectRoot $ProjectRoot
    if (-not $models -or $models.Count -eq 0) { return $null }

    $candidates = @()
    foreach ($m in $models) {
        $full = Resolve-FullModelDirectory -ModelPath $m.Path -ProjectRoot $ProjectRoot
        if (-not $full -or -not (Test-Path -LiteralPath $full)) { continue }

        if ($RegistryBackend.Type -eq "builtin") {
            $bf = $null
            $amb = $false
            if (-not (Try-ResolveRunnableModelBackendFull -RelPath $m.Path -ProjectRoot $ProjectRoot -BackendFullOut ([ref]$bf) -AmbiguousGgufOut ([ref]$amb))) {
                continue
            }
        }

        $format = ([string]$m.Format).Trim().ToLower()
        $sizeMb = Get-PathSizeMB -FullPath $full
        # Snappy policy: OpenVINO IR loads fast at any size; GGUF pays JIT compile cost (scales with size).
        $formatPriority = 5
        if (Test-DirHasOpenVINOIr -FullPath $full) {
            $formatPriority = 0
        } elseif ($format -eq "openvino") {
            $formatPriority = 0
        } elseif ($format -eq "gguf") {
            $formatPriority = 1
        } elseif ($format -eq "onnx") {
            $formatPriority = 2
        } elseif ($format -eq "safetensors" -or $format -eq "hf") {
            $formatPriority = 3
        }

        $score = ($formatPriority * 100000.0) + $sizeMb
        $candidates += [pscustomobject]@{
            Id = $m.Id
            Path = $m.Path
            Format = $format
            SizeMb = $sizeMb
            Score = $score
        }
    }

    if (-not $candidates -or $candidates.Count -eq 0) { return $null }

    $best = $candidates | Sort-Object Score, Id | Select-Object -First 1
    if (-not $best) { return $null }
    return $best
}

$registryPick = Get-RegistrySelectedModel
$registryBackend = Get-RegistrySelectedBackend -ProjectRoot $scriptDir
$registryAutoSelectBestModel = Get-RegistryAutoSelectBestModel -ProjectRoot $scriptDir

if ($null -ne $registryAutoSelectBestModel) {
    $autoSelectBestModel = [bool]$registryAutoSelectBestModel
}
if ($autoSelectModelEnv -eq "1") { $autoSelectBestModel = $true }
if ($autoSelectModelEnv -eq "0") { $autoSelectBestModel = $false }
if ($AutoSelectBestModel) { $autoSelectBestModel = $true }
if ($env:ACOULM_SNAPPY -eq "1" -and $autoSelectModelEnv -ne "0") { $autoSelectBestModel = $true }

if ([string]::IsNullOrWhiteSpace($ModelPath)) {
    $ModelPath = $registryPick.Path
}

$ModelPath = Normalize-ModelPathString $ModelPath

if ($autoSelectBestModel) {
    $best = Select-BestModelCandidate -ProjectRoot $scriptDir -RegistryBackend $registryBackend -CurrentModelPath $ModelPath
    if ($best -and -not [string]::IsNullOrWhiteSpace($best.Path)) {
        if ($best.Path -ne $ModelPath) {
            Write-Host "[App] Auto-selected best model for this run: $($best.Id) ($($best.Path), format=$($best.Format), size=$($best.SizeMb) MB)." -ForegroundColor Cyan
            Write-Host "      Heuristic: OpenVINO IR first, then smallest GGUF (IR avoids per-launch compile)." -ForegroundColor DarkGray
        } else {
            Write-Host "[App] Auto-select checked registry models; keeping current model: $($best.Id)." -ForegroundColor DarkGray
        }
        $ModelPath = $best.Path
    } else {
        Write-Host "[App] Auto-select enabled, but no runnable model candidates were found. Using selected model path." -ForegroundColor Yellow
    }
}

$modelResolvedFull = Resolve-FullModelDirectory -ModelPath $ModelPath -ProjectRoot $scriptDir
$modelDirFull = $modelResolvedFull
$dirExists = $modelDirFull -and (Test-Path -LiteralPath $modelDirFull -PathType Container)
$targetExists = $modelResolvedFull -and (Test-Path -LiteralPath $modelResolvedFull)

$backendFull = $null

if ($registryBackend.Type -eq "external") {
    if (-not $targetExists) {
        throw "[App] Model path not found (external backend: path is passed to your entrypoint as-is).`n  $modelResolvedFull`n  (ModelPath was '$ModelPath')"
    }
    $backendFull = $modelResolvedFull
    Write-Host "[App] External backend selected; skipping OpenVINO IR/GGUF layout checks." -ForegroundColor DarkGray
} else {
$ambiguousGguf = $false
$hasRunnable = Try-ResolveRunnableModelBackendFull -RelPath $ModelPath -ProjectRoot $scriptDir `
    -BackendFullOut ([ref]$backendFull) -AmbiguousGgufOut ([ref]$ambiguousGguf)

if ($ambiguousGguf) {
    throw @"
[App] Model folder has multiple .gguf files and no OpenVINO IR (.xml).
  Folder: $modelDirFull
  Register path to one .gguf file, or keep only one .gguf in the folder, or add exported IR (.xml + weights).
"@
}

if (-not $hasRunnable) {
    $fallback = $null
    foreach ($rel in (Get-OpenVinoRunnableCandidates -ProjectRoot $scriptDir -PreferPath $ModelPath)) {
        $bf = $null
        $amb = $false
        if (Try-ResolveRunnableModelBackendFull -RelPath $rel -ProjectRoot $scriptDir -BackendFullOut ([ref]$bf) -AmbiguousGgufOut ([ref]$amb)) {
            $fallback = @{ Relative = $rel; BackendFull = $bf }
            break
        }
    }

    $firstRunHint = @"

Why this happens on a fresh machine:
  Built-in OpenVINO (npu_wrapper) only accepts an IR folder (*.xml + bins), a supported .gguf, or a folder with exactly one .gguf. Raw Hugging Face .safetensors trees are not loaded as-is. External backends skip this check.

What to do next:
  1) Get or export a runnable layout (IR or supported GGUF), run .\portable_setup.ps1 or edit registry\models_registry.json, or switch registry\backends_registry.json to type external if your stack loads HF weights directly.
  2) Or copy registry\models_registry.example.json -> registry\models_registry.json, put your model under .\models\..., and edit path + selected_model.
  3) Diagnostics: .\preflight_check.ps1 -ModelPath '<your path>'

Docs: README sections 'What AcouLM Does Not Bundle' and 'Model Notes'.
"@

    if ($fallback) {
        if ($dirExists -and -not (Test-DirHasOpenVINOIr -FullPath $modelDirFull)) {
            Write-Host "[App] Registry path is not a runnable OpenVINO model (no IR / single GGUF): $ModelPath" -ForegroundColor Yellow
        } elseif (-not $dirExists) {
            Write-Host "[App] Model path missing: $modelDirFull" -ForegroundColor Yellow
        }
        Write-Host "[App] Starting with another runnable model from registry instead: $($fallback.Relative)" -ForegroundColor Cyan
        Write-Host "      Update selected_model in registry\models_registry.json to match the model you want." -ForegroundColor DarkGray
        $backendFull = $fallback.BackendFull
    } else {
        if (-not $dirExists) {
            throw "[App] Model path not found:`n  $modelDirFull`n  (ModelPath was '$ModelPath')`n`nNo other registry path contained a runnable model (IR or single GGUF) either.$firstRunHint"
        }
        $exportedOk = $false
        if ($autoExportIr -and $registryBackend.Type -eq "builtin" -and (Test-DirIsHfCheckpointWithoutIr -FullPath $modelDirFull)) {
            try {
                $modelDirName = [System.IO.Path]::GetFileName($modelDirFull.TrimEnd('\', '/'))
                $modelDirParent = [System.IO.Path]::GetDirectoryName($modelDirFull)
                if ([string]::IsNullOrWhiteSpace($modelDirName) -or [string]::IsNullOrWhiteSpace($modelDirParent)) {
                    throw "Could not derive parent/name for model folder: $modelDirFull"
                }
                $irLeaf = "$modelDirName-ov-ir"
                $irFull = Join-Path -Path $modelDirParent -ChildPath $irLeaf
                $exportScript = Join-Path $scriptDir "Export-HfFolderToOpenVinoIR.ps1"
                Write-Host "[App] Auto IR export: exporting Hugging Face checkpoint to IR (optimum-cli)..." -ForegroundColor Cyan
                & $exportScript -ProjectRoot $scriptDir -HfModelDir $modelDirFull -IrOutputDir $irFull -TrustRemoteCode
                if (Test-DirHasOpenVINOIr -FullPath $irFull) {
                    $newRel = Convert-FullPathToRepoRelativeModelArg -ProjectRoot $scriptDir -FullPath $irFull
                    Update-ModelsRegistrySelectedPath -ProjectRoot $scriptDir -NewRelativePath $newRel -Format "openvino"
                    $backendFull = $irFull
                    $exportedOk = $true
                    Write-Host "[App] IR export done; registry updated to $newRel" -ForegroundColor Green
                }
            } catch {
                Write-Host "[App] Auto IR export failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        if (-not $exportedOk) {
            $ggufNote = ""
            if ($registryPick.Format -match "^(?i)gguf$") {
                $ggufNote = "`n`nThis folder has no .gguf files (or several .gguf with no IR). Use one .gguf path, one-GGUF folder, or OpenVINO IR."
            }
            $folderHint = Get-UnrunnableModelFolderHint -FullPath $modelDirFull
            $genericTail = if ([string]::IsNullOrWhiteSpace(($folderHint + "").Trim())) {
                "`n`nAdd an IR folder (*.xml) or a supported .gguf path (recent GenAI for GGUF)."
            } else {
                ""
            }
            $autoHint = if (-not $autoExportIr) {
                "`n`nTip: automatic HF -> IR export is disabled right now. Re-run with .\start_app.ps1 -AutoExportIr (or set env ACOULM_AUTO_EXPORT_IR=1)."
            } else {
                ""
            }
            throw "[App] No runnable OpenVINO model found (selected path + other registry entries + ./models/Qwen2.5-0.5B-Instruct).`n  Checked: $modelDirFull$ggufNote$folderHint$genericTail$autoHint$firstRunHint"
        }
    }
}
}

$ModelPath = Convert-FullPathToRepoRelativeModelArg -ProjectRoot $scriptDir -FullPath $backendFull

$ensureFast = Join-Path $scriptDir "scripts\Ensure-FastModel.ps1"
if (Test-Path -LiteralPath $ensureFast) {
    try {
        $fastRel = & $ensureFast -ProjectRoot $scriptDir
        if (-not [string]::IsNullOrWhiteSpace($fastRel)) {
            $pick = Get-RegistrySelectedModel
            if ($pick.Path) {
                $ModelPath = Normalize-ModelPathString $pick.Path
                $bf2 = $null
                $amb = $false
                if (Try-ResolveRunnableModelBackendFull -RelPath $ModelPath -ProjectRoot $scriptDir -BackendFullOut ([ref]$bf2) -AmbiguousGgufOut ([ref]$amb)) {
                    $backendFull = $bf2
                }
            }
        }
    } catch {
        Write-Host "[App] Fast-model setup: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Test-TcpPort {
    param(
        [string]$Hostname,
        [int]$Port,
        [int]$TimeoutMs = 500
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Hostname, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Open-Url {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $false
    }
    # Prefer shell registration (most reliable on Windows for http/https).
    try {
        Start-Process -FilePath $Url -ErrorAction Stop | Out-Null
        return $true
    } catch {}
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Url
        $psi.UseShellExecute = $true
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        return $true
    } catch {}
    try {
        Invoke-Item -LiteralPath $Url -ErrorAction Stop
        return $true
    } catch {}
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = "cmd.exe"
        $safe = $Url.Replace('"', '""')
        $startInfo.Arguments = '/c start "" "' + $safe + '"'
        $startInfo.CreateNoWindow = $true
        $startInfo.UseShellExecute = $false
        [System.Diagnostics.Process]::Start($startInfo) | Out-Null
        return $true
    } catch {}
    return $false
}

function Stop-AppShellServer {
    param([int]$Port)

    Get-CimInstance Win32_Process -Filter "name = 'python.exe' OR name = 'pythonw.exe'" |
        Where-Object {
            $_.CommandLine -like "*http.server $Port*" -and
            $_.CommandLine -like "*--directory app_shell*"
        } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Start-AppShellHttpProcess {
    $pythonExe = Join-Path $scriptDir "venv\Scripts\python.exe"
    $pythonCmd = if (Test-Path $pythonExe) { "& '$pythonExe'" } else { "python" }
    $appShellCmd = "Set-Location '$scriptDir'; $pythonCmd -m http.server $AppPort --directory app_shell"
    $windowStyle = if ($HideServiceWindows) { "Hidden" } else { "Normal" }
    $appShellArgs = if ($HideServiceWindows) {
        @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $appShellCmd)
    } else {
        @("-NoExit", "-Command", $appShellCmd)
    }
    Start-Process powershell -ArgumentList $appShellArgs -WindowStyle $windowStyle | Out-Null
}

function Wait-AppShellTcpReady {
    param([int]$TimeoutSec = 30)

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort -Hostname "127.0.0.1" -Port $AppPort -TimeoutMs 500) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Get-ModelScaleProfile {
    param([string]$BackendFullPath)
    if ([string]::IsNullOrWhiteSpace($BackendFullPath) -or -not (Test-Path -LiteralPath $BackendFullPath)) {
        return $null
    }
    $weightBytes = 0L
    if (Test-Path -LiteralPath $BackendFullPath -PathType Leaf) {
        $weightBytes = (Get-Item -LiteralPath $BackendFullPath).Length
    } else {
        foreach ($f in @(Get-ChildItem -LiteralPath $BackendFullPath -Recurse -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -match '\.(?i)(gguf|bin)$' -or $f.Extension -eq ".xml") {
                $weightBytes += $f.Length
            }
        }
    }
    $weightGb = [math]::Round($weightBytes / 1GB, 2)
    $isGguf = ($BackendFullPath -match '\.(?i)gguf$')
    $isIr = (Test-Path -LiteralPath $BackendFullPath -PathType Container) -and (Test-DirHasOpenVINOIr -FullPath $BackendFullPath)
    $tier = "small"
    if ($weightGb -ge 8) { $tier = "xlarge" }
    elseif ($weightGb -ge 4) { $tier = "large" }
    elseif ($weightGb -ge 2) { $tier = "medium" }
    $estRamGb = [math]::Round($weightGb * 1.35 + 2.5, 1)
    $coldNote = if ($isIr) {
        "IR: load is usually seconds (size scales mainly with RAM)."
    } elseif ($isGguf) {
        "GGUF: first compile scales with size and GPU strength (~1-5 min at 2GB on weak iGPU; IR is much faster after one export)."
    } else {
        "Cold load time depends on format and device."
    }
    return [pscustomobject]@{
        WeightGb   = $weightGb
        Tier       = $tier
        EstRamGb   = $estRamGb
        IsGguf     = $isGguf
        IsIr       = $isIr
        ColdNote   = $coldNote
    }
}

function Show-ModelScaleWarning {
    param([string]$BackendFullPath)
    $p = Get-ModelScaleProfile -BackendFullPath $BackendFullPath
    if (-not $p) { return }
    Write-Host "[App] Model weights ~$($p.WeightGb) GB (tier $($p.Tier)); est. peak RAM ~$($p.EstRamGb) GB." -ForegroundColor Cyan
    Write-Host "[App] $($p.ColdNote)" -ForegroundColor DarkGray
    if ($p.IsGguf -and $p.WeightGb -ge 2) {
        Write-Host "[App] For daily speed at this size or larger, export OpenVINO IR once (see Export-HfFolderToOpenVinoIR.ps1) or use a smaller GGUF." -ForegroundColor DarkYellow
    }
    if ($p.Tier -eq "large" -or $p.Tier -eq "xlarge") {
        Write-Host "[App] Large model: single-device only; do not enable split-prefill or multi-device load." -ForegroundColor Yellow
    }
}

function Get-SystemRamGb {
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        return [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    } catch {
        return 32.0
    }
}

function Test-IsHardwareDevice {
    param([string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value.Trim().ToUpperInvariant() -match '^(CPU|GPU|NPU)$'
}

function Resolve-BackendDeviceOverride {
    param(
        [string]$UserDevice,
        [string]$ModelFullPath
    )
    if (Test-IsHardwareDevice -Value $UserDevice) {
        return $UserDevice.Trim().ToUpperInvariant()
    }
    $fromEnv = [string]$env:ACOULM_DEVICE
    if (Test-IsHardwareDevice -Value $fromEnv) {
        return $fromEnv.Trim().ToUpperInvariant()
    }
    return ""
}

function Test-BackendProcessRunning {
    return $null -ne (Get-Process -Name "npu_wrapper" -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Stop-BackendServer {
    Get-Process npu_wrapper -ErrorAction SilentlyContinue |
        ForEach-Object {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
}

function Start-BackendServer {
    param(
        [string]$Model,
        [string]$DeviceOverride,
        [int]$Port,
        [switch]$HideWindow,
        [string[]]$Args
    )

    $hostScript = Join-Path $scriptDir "scripts\Start-AcouLMBackend.ps1"
    if (-not (Test-Path -LiteralPath $hostScript)) {
        throw "[App] Missing backend host script: $hostScript"
    }

    $effectiveArgs = @()
    if ($perfModeEnabled) {
        $hasPolicyArg = $false
        foreach ($existing in $Args) {
            if ([string]$existing -match '^(--policy|--policy=)') { $hasPolicyArg = $true; break }
        }
        if (-not $hasPolicyArg) {
            $effectiveArgs += @("--policy", "PERFORMANCE")
        }
    }
    if ($Args) {
        $effectiveArgs += @($Args)
    }

    $psArgs = @(
        "-NoExit",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $hostScript,
        "-Model", $Model,
        "-Port", $Port
    )
    if (Test-IsHardwareDevice -Value $DeviceOverride) {
        $psArgs += @("-Device", $DeviceOverride.Trim().ToUpperInvariant())
    } elseif (-not [string]::IsNullOrWhiteSpace($DeviceOverride)) {
        Write-Host "[App] Ignoring invalid -Device '$DeviceOverride' (use CPU, GPU, or NPU)." -ForegroundColor Yellow
    }
    if ($effectiveArgs.Count -gt 0) {
        $psArgs += @("-ExtraArgs")
        $psArgs += $effectiveArgs
    }

    $windowStyle = if ($HideWindow) { "Hidden" } else { "Normal" }
    Start-Process -FilePath "powershell" -ArgumentList $psArgs -WindowStyle $windowStyle | Out-Null
}

function Test-ApiHttpHealthy {
    param([int]$Port)
    try {
        $null = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/health" -Method Get -TimeoutSec 2 -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Test-ApiChatReady {
    param([int]$Port)
    try {
        $h = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/health" -Method Get -TimeoutSec 3 -ErrorAction Stop
        if ($null -ne $h.chat_ready -and $h.chat_ready -eq $false) {
            return $false
        }
        return $true
    } catch {
        return $false
    }
}

function Wait-ForApiReady {
    param(
        [int]$Port,
        [int]$TimeoutSec
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastProgress = Get-Date
    while ((Get-Date) -lt $deadline) {
        # TCP-listening is not enough; the backend can bind the port while still loading weights.
        # Require an actual HTTP response from /v1/health.
        if (Test-ApiChatReady -Port $Port) {
            return $true
        }
        if (Test-TcpPort -Hostname "127.0.0.1" -Port $Port -TimeoutMs 250) {
            try {
                $h = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/health" -Method Get -TimeoutSec 2 -ErrorAction Stop
                if ($null -ne $h.chat_ready -and $h.chat_ready -eq $false) {
                    $elapsed = ((Get-Date) - $lastProgress).TotalSeconds
                    if ($elapsed -ge 12) {
                        Write-Host "[App] API online - loading model (first compile may take several minutes)..." -ForegroundColor DarkYellow
                        $lastProgress = Get-Date
                    }
                }
            } catch {
                # keep waiting
            }
        }
        $elapsed = ((Get-Date) - $lastProgress).TotalSeconds
        if ($elapsed -ge 15) {
            Write-Host "[App] Still waiting for model to finish loading..." -ForegroundColor DarkYellow
            $lastProgress = Get-Date
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

Write-Host "[App] Project root: $scriptDir" -ForegroundColor Cyan
Write-Host "[App] Starting AcouLM (control panel + API; OpenWebUI disabled)..." -ForegroundColor Cyan
Write-Host "[App] Selected backend type: $($registryBackend.Type)" -ForegroundColor DarkGray
if ($perfModeEnabled) {
    Write-Host "[App] Performance mode enabled (PERFORMANCE policy; single device, low-latency hints)." -ForegroundColor Green
}

$appUrl = "http://localhost:$AppPort"
$apiBase = "http://localhost:$ApiPort/v1"
$appReady = $false
$didOpenBrowser = $false

if (Test-ApiChatReady -Port $ApiPort) {
    Write-Host "[App] API already healthy on port $ApiPort - skipping backend restart." -ForegroundColor Green
    if ($SkipAppShell) {
        Write-Host "[App] Ready (API only)." -ForegroundColor Green
        exit 0
    }
    if (-not (Test-TcpPort -Hostname "127.0.0.1" -Port $AppPort -TimeoutMs 400)) {
        Start-AppShellHttpProcess
        $null = Wait-AppShellTcpReady -TimeoutSec 10
    }
    if ($OpenBrowser) {
        if (Open-Url -Url $appUrl) {
            Write-Host "[App] Opened browser (control panel)." -ForegroundColor Green
        }
    }
    Write-Host "`n[App] Ready." -ForegroundColor Green
    Write-Host "Primary UI (App Shell): $appUrl"
    exit 0
}

$portBusy = Test-TcpPort -Hostname "127.0.0.1" -Port $ApiPort -TimeoutMs 400
$backendRunning = Test-BackendProcessRunning
if ($backendRunning -or $portBusy) {
    if (-not (Test-ApiChatReady -Port $ApiPort)) {
        Write-Host "[App] Backend already running on port $ApiPort (waiting for model, not restarting)." -ForegroundColor Yellow
    }
} else {
    Write-Host "[App] No backend process - starting fresh." -ForegroundColor Yellow
    Stop-BackendServer
}
if (-not $SkipAppShell) {
    Write-Host "[App] Stopping stale control panel processes..." -ForegroundColor Yellow
    Stop-AppShellServer -Port $AppPort
}

# Start static UI first so the browser can open while the model loads (API may show offline briefly).
if (-not $SkipAppShell) {
    Write-Host "[App] Starting control panel on port $AppPort (before API - you can open the browser now)..." -ForegroundColor Cyan
    Write-Host "[App] The page may show API offline until the backend finishes loading weights." -ForegroundColor DarkGray
    Start-AppShellHttpProcess
    $appReady = Wait-AppShellTcpReady -TimeoutSec 10
    if ($appReady) {
        Write-Host "[App] Control panel is listening at $appUrl" -ForegroundColor Green
    } else {
        Write-Host "[App] Control panel did not become ready in time; will retry after the API is up." -ForegroundColor Yellow
    }
    if ($OpenBrowser) {
        if (Open-Url -Url $appUrl) {
            $didOpenBrowser = $true
            Write-Host "[App] Opened browser (control panel)." -ForegroundColor Green
        } else {
            Write-Host "[App] Could not auto-open browser. Open manually: $appUrl" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[App] Control panel URL: $appUrl" -ForegroundColor DarkGray
    }
}

if (-not $backendRunning -and -not $portBusy) {
    if ($backendFull) {
        Show-ModelScaleWarning -BackendFullPath $backendFull
    }
    Write-Host "[App] Launching backend." -ForegroundColor DarkCyan
    if ($HideServiceWindows) {
        Write-Host "[App] Service windows are hidden - use Task Manager for npu_wrapper.exe if you need a process view." -ForegroundColor DarkYellow
    } else {
        Write-Host "[App] A visible PowerShell window will show backend (run.ps1) output." -ForegroundColor DarkGray
    }
    $loadDevice = Resolve-BackendDeviceOverride -UserDevice $Device -ModelFullPath $backendFull
    Start-BackendServer -Model $ModelPath -DeviceOverride $loadDevice -Port $ApiPort -HideWindow:$HideServiceWindows -Args $BackendArgs
}

if (Wait-ForApiReady -Port $ApiPort -TimeoutSec $TimeoutSeconds) {
    Write-Host "[App] Backend API is ready at http://localhost:$ApiPort/v1" -ForegroundColor Green
} else {
    throw "[App] Backend API did not become ready on port $ApiPort within $TimeoutSeconds seconds.`n  Try: .\start_app.ps1 -TimeoutSeconds 600 -ModelPath '$ModelPath'`n  Or open a visible backend window: .\start_app.ps1 -ModelPath '$ModelPath' (omit -HideServiceWindows from wrappers that pass it)."
}

if ($SkipAppShell) {
    Write-Host "[App] Skipping browser app shell (terminal-only). API: $apiBase" -ForegroundColor DarkCyan
    Write-Host "[App] Optional browser UI later: .\start_app.ps1 -OpenBrowser (starts app shell + opens tab)." -ForegroundColor DarkGray
} else {
    if (-not $appReady) {
        Write-Host "[App] Retrying control panel after API start..." -ForegroundColor Yellow
        Start-AppShellHttpProcess
        $appReady = Wait-AppShellTcpReady -TimeoutSec 10
        if ($appReady) {
            Write-Host "[App] Control panel is up: $appUrl" -ForegroundColor Green
        } else {
            Write-Host "[App] Control panel still not responding — check Python and port $AppPort." -ForegroundColor Yellow
        }
        if ($OpenBrowser -and -not $didOpenBrowser) {
            if (Open-Url -Url $appUrl) {
                $didOpenBrowser = $true
                Write-Host "[App] Opened browser (control panel)." -ForegroundColor Green
            } else {
                Write-Host "[App] Could not auto-open browser. Open manually: $appUrl" -ForegroundColor Yellow
            }
        }
    }
}

Write-Host "`n[App] Ready." -ForegroundColor Green
if (-not $SkipAppShell) {
    Write-Host "Primary UI (App Shell): $appUrl"
}
Write-Host "API base: $apiBase"
