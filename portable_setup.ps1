param(
    [switch]$SkipBuild,
    [switch]$NoLaunch,
    [int]$ApiPort = 8000,
    [int]$AppPort = 5173
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$DefaultYes = $true
    )

    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    $raw = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $DefaultYes
    }
    $v = $raw.Trim().ToLower()
    return ($v -eq "y" -or $v -eq "yes")
}

function Ensure-RegistryFile {
    param(
        [string]$Path,
        [hashtable]$Default
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
    if (-not (Test-Path $Path)) {
        ($Default | ConvertTo-Json -Depth 8) | Set-Content -Path $Path -Encoding UTF8
    }
}

function Load-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $raw = Get-Content -Path $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Save-JsonFile {
    param(
        [string]$Path,
        [object]$Data
    )
    ($Data | ConvertTo-Json -Depth 10) | Set-Content -Path $Path -Encoding UTF8
}

function Ensure-LoomisCommandInProfile {
    param([string]$ProjectRoot)

    try {
        if (-not $PROFILE) { return }
        $profileDir = Split-Path -Parent $PROFILE
        if ($profileDir -and -not (Test-Path -LiteralPath $profileDir)) {
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $PROFILE)) {
            New-Item -ItemType File -Path $PROFILE -Force | Out-Null
        }

        $escapedRoot = $ProjectRoot.Replace("'", "''")
        $startMarker = "# >>> Loomis command >>>"
        $endMarker = "# <<< Loomis command <<<"
        # Split here-strings: a nested @"..."@ inside the profile $block would close the outer @" prematurely.
        $blockPart1 = @"
$startMarker
function Loomis {
    param([Parameter(ValueFromRemainingArguments = `$true)][string[]]`$Args)
    `$loomisRoot = '$escapedRoot'
    `$cli = Join-Path `$loomisRoot 'npu_cli.ps1'
    if (-not (Test-Path -LiteralPath `$cli)) {
        Write-Error "Loomis CLI not found at `$cli"
        return
    }
    if (`$Args -and `$Args.Count -gt 0) {
        & `$cli @Args
    } else {
        & `$cli -Command chat
    }
}

function Ensure-LoomisGlobalCommand {
    param([string]$ProjectRoot)

    try {
        `$binDir = Join-Path `$HOME ".local\bin"
        if (-not (Test-Path -LiteralPath `$binDir)) {
            New-Item -ItemType Directory -Path `$binDir -Force | Out-Null
        }

        `$cmdPath = Join-Path `$binDir "loomis.cmd"
"@
        $blockPart2 = @'
        $cmdBody = @"
@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "$ProjectRoot\loomis.ps1" %*
"@
'@
        $blockPart3 = @"
        Set-Content -LiteralPath `$cmdPath -Value `$cmdBody -Encoding ASCII

        `$userPath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
        if (`$null -eq `$userPath) { `$userPath = "" }
        `$parts = @(`$userPath -split ";" | ForEach-Object { `$_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace(`$_) })
        if (-not (`$parts -contains `$binDir)) {
            `$newPath = if ([string]::IsNullOrWhiteSpace(`$userPath)) { `$binDir } else { "`$userPath;`$binDir" }
            [Environment]::SetEnvironmentVariable("Path", `$newPath, [EnvironmentVariableTarget]::User)
            if (`$env:Path -notlike "*`$binDir*") {
                `$env:Path = "`$env:Path;`$binDir"
            }
            Write-Host "[Setup] Added `$binDir to user PATH." -ForegroundColor Green
        }

        Write-Host "[Setup] Installed global 'loomis' command: `$cmdPath" -ForegroundColor Green
    } catch {
        Write-Host ('[Setup] Could not install global ''loomis'' command: ' + `$_.Exception.Message) -ForegroundColor Yellow
    }
}
Set-Alias -Name loomis -Value Loomis -Scope Global
$endMarker
"@
        $block = $blockPart1 + $blockPart2 + $blockPart3

        $content = Get-Content -LiteralPath $PROFILE -Raw -ErrorAction SilentlyContinue
        if ($null -eq $content) { $content = "" }

        $pattern = [regex]::Escape($startMarker) + ".*?" + [regex]::Escape($endMarker)
        if ($content -match $pattern) {
            $updated = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block }, [System.Text.RegularExpressions.RegexOptions]::Singleline)
            Set-Content -LiteralPath $PROFILE -Value $updated -Encoding UTF8
        } else {
            $prefix = if ([string]::IsNullOrWhiteSpace($content)) { "" } else { "`r`n" }
            Add-Content -LiteralPath $PROFILE -Value ($prefix + $block) -Encoding UTF8
        }

        Write-Host "[Setup] Added 'loomis' terminal command to PowerShell profile. Open a new terminal (or run: . `$PROFILE)." -ForegroundColor Green
    } catch {
        Write-Host "[Setup] Could not update PowerShell profile for 'loomis' command: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "        You can still run chat with: .\npu_cli.ps1 -Command chat" -ForegroundColor DarkGray
    }
}

function Add-OrUpdateModel {
    param(
        [string]$RegistryPath,
        [string]$Id,
        [string]$Path,
        [string]$Format,
        [string]$Backend
    )

    $reg = Load-JsonFile -Path $RegistryPath
    if ($null -eq $reg) {
        $reg = [ordered]@{ schema = 1; auto_select_best_model = $false; selected_model = $Id; models = @() }
    }
    if ($null -eq $reg.models) { $reg | Add-Member -NotePropertyName models -NotePropertyValue @() }

    $existing = $null
    foreach ($m in $reg.models) {
        if ($m.id -eq $Id) { $existing = $m; break }
    }

    if ($null -eq $existing) {
        $entry = [pscustomobject]@{
            id = $Id
            path = $Path
            format = $Format
            backend = $Backend
            status = "ready"
        }
        $reg.models += $entry
    } else {
        $existing.path = $Path
        $existing.format = $Format
        $existing.backend = $Backend
        $existing.status = "ready"
    }

    $reg.selected_model = $Id
    Save-JsonFile -Path $RegistryPath -Data $reg
}

function Add-OrUpdateBackend {
    param(
        [string]$RegistryPath,
        [string]$Id,
        [string]$Type,
        [string]$Entrypoint,
        [string[]]$Formats = @()
    )

    $reg = Load-JsonFile -Path $RegistryPath
    if ($null -eq $reg) {
        $reg = [ordered]@{ schema = 1; selected_backend = $Id; backends = @() }
    }
    if ($null -eq $reg.backends) { $reg | Add-Member -NotePropertyName backends -NotePropertyValue @() }

    $existing = $null
    foreach ($b in $reg.backends) {
        if ($b.id -eq $Id) { $existing = $b; break }
    }

    function Resolve-DefaultFormats {
        param([string]$T, [string[]]$Explicit)
        if ($Explicit -and $Explicit.Count -gt 0) { return ,@($Explicit) }
        if ($T -eq "external") {
            return ,@("hf", "safetensors", "gguf", "openvino")
        }
        return ,@("openvino", "gguf")
    }

    if ($null -eq $existing) {
        $fmt = Resolve-DefaultFormats -T $Type -Explicit $Formats
        $entry = [pscustomobject]@{
            id = $Id
            type = $Type
            entrypoint = $Entrypoint
            formats = $fmt
            status = "ready"
        }
        $reg.backends += $entry
    } else {
        $existing.type = $Type
        $existing.entrypoint = $Entrypoint
        if ($Formats -and $Formats.Count -gt 0) {
            $existing.formats = ,@($Formats)
        } elseif ($Type -eq "builtin") {
            $existing.formats = ,@("openvino", "gguf")
        }
        $existing.status = "ready"
    }

    $reg.selected_backend = $Id
    Save-JsonFile -Path $RegistryPath -Data $reg
}

function Download-Model {
    param(
        [string]$Repo,
        [string]$ModelId,
        [string]$FilesFilter = ""
    )

    if ([string]::IsNullOrWhiteSpace($Repo)) {
        throw "Model repo is required for download"
    }
    if ([string]::IsNullOrWhiteSpace($ModelId)) {
        $ModelId = ($Repo -split "/")[-1]
    }

    $target = Join-Path $scriptDir (Join-Path "models" $ModelId)
    if (-not (Test-Path $target)) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
    }

    $includePatterns = @()
    if (-not [string]::IsNullOrWhiteSpace($FilesFilter)) {
        $includePatterns = @(
            ($FilesFilter -split ",") |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }
    $partial = $includePatterns.Count -gt 0

    if ($partial) {
        Write-Host "[Setup] Downloading only matching file(s) from '$Repo' into '$target'..." -ForegroundColor Cyan
        Write-Host "       Patterns: $($includePatterns -join ', ')" -ForegroundColor DarkGray
    } else {
        Write-Host "[Setup] Downloading full repo '$Repo' into '$target'..." -ForegroundColor Cyan
    }

    $env:PYTHONIOENCODING = "utf-8"

    function Invoke-HfDownload {
        param(
            [string]$ExePath,
            [string[]]$BaseArgs
        )
        & $ExePath @BaseArgs | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "HF download failed with exit code $LASTEXITCODE"
        }
    }

    $hfCmd = Get-Command hf -ErrorAction SilentlyContinue
    if ($hfCmd) {
        $args = @("download", $Repo)
        if ($partial) {
            foreach ($p in $includePatterns) {
                $args += "--include"
                $args += $p
            }
        }
        $args += "--local-dir"
        $args += "$target"
        Invoke-HfDownload -ExePath $hfCmd.Source -BaseArgs $args
        return $ModelId
    }

    $hfCli = Get-Command huggingface-cli -ErrorAction SilentlyContinue
    if ($hfCli) {
        $args = @("download", $Repo)
        if ($partial) {
            foreach ($p in $includePatterns) {
                $args += "--include"
                $args += $p
            }
        }
        $args += "--local-dir"
        $args += $target
        $args += "--local-dir-use-symlinks"
        $args += "False"
        Invoke-HfDownload -ExePath $hfCli.Source -BaseArgs $args
        return $ModelId
    }

    if ($partial) {
        throw "Downloading specific files (not the whole repo) requires the Hugging Face CLI.`nInstall: pip install -U ""huggingface_hub[cli]""`nThen re-run setup. (git clone always pulls the entire repository.)"
    }

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCmd) {
        throw "Neither hf/huggingface-cli nor git is available. Install one of them to download model files."
    }

    if (Test-Path (Join-Path $target ".git")) {
        Push-Location $target
        try {
            git pull | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "git pull failed with exit code $LASTEXITCODE"
            }
        } finally {
            Pop-Location
        }
    } else {
        if (Test-Path $target) {
            Remove-Item -Recurse -Force $target
        }
        git clone "https://huggingface.co/$Repo" $target | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "git clone failed with exit code $LASTEXITCODE"
        }
    }

    return $ModelId
}

$modelsRegistryPath = Join-Path $scriptDir "registry\models_registry.json"
$backendsRegistryPath = Join-Path $scriptDir "registry\backends_registry.json"

Ensure-RegistryFile -Path $modelsRegistryPath -Default ([ordered]@{
    schema = 1
    auto_select_best_model = $false
    selected_model = "openvino-local"
    models = @(
        [ordered]@{
            id = "openvino-local"
            path = "./models/Qwen2.5-0.5B-Instruct"
            format = "openvino"
            backend = "openvino"
            status = "ready"
        }
    )
})

Ensure-RegistryFile -Path $backendsRegistryPath -Default ([ordered]@{
    schema = 1
    selected_backend = "openvino"
    backends = @(
        [ordered]@{
            id = "openvino"
            type = "builtin"
            entrypoint = "dist/npu_wrapper.exe"
            formats = @("openvino", "gguf")
            status = "ready"
        }
    )
})

$backendId = "openvino"
$backendType = "builtin"
$backendEntrypoint = "dist/npu_wrapper.exe"

if (-not (Read-YesNo -Prompt "Use default OpenVINO backend?" -DefaultYes $true)) {
    $backendIdInput = Read-Host "Backend id"
    $backendTypeInput = Read-Host "Backend type (builtin/external)"
    $backendEntrypointInput = Read-Host "Backend entrypoint path"

    if (-not [string]::IsNullOrWhiteSpace($backendIdInput)) { $backendId = $backendIdInput.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($backendTypeInput)) { $backendType = $backendTypeInput.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($backendEntrypointInput)) { $backendEntrypoint = $backendEntrypointInput.Trim() }
}

Add-OrUpdateBackend -RegistryPath $backendsRegistryPath -Id $backendId -Type $backendType -Entrypoint $backendEntrypoint

$exePath = Join-Path $scriptDir "dist\npu_wrapper.exe"
if ($backendType -eq "builtin") {
    if (-not (Test-Path $exePath)) {
        Write-Host "[Setup] No pre-built executable found at dist\npu_wrapper.exe." -ForegroundColor Yellow
        if (-not $SkipBuild) {
            $shouldBuild = Read-YesNo -Prompt "Build from source now?" -DefaultYes $true
            if ($shouldBuild) {
                & (Join-Path $scriptDir "build.ps1")
                if ($LASTEXITCODE -ne 0) {
                    throw "build.ps1 failed"
                }
            } else {
                Write-Host "[Setup] Skipping build. Copy a pre-built dist\ folder here before launching." -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "[Setup] Pre-built executable found: dist\npu_wrapper.exe" -ForegroundColor Green
    }
} else {
    Write-Host "[Setup] External backend selected; skipping built-in dist\npu_wrapper.exe checks." -ForegroundColor Cyan
}

$modelId = "openvino-local"
$modelPath = "./models/Qwen2.5-0.5B-Instruct"
$modelFormat = "openvino"

if (Read-YesNo -Prompt "Download a model from Hugging Face now?" -DefaultYes $false) {
    Write-Host ""
    Write-Host "Two-step Hub download:" -ForegroundColor Cyan
    Write-Host "  1) Repo id = the model's page on huggingface.co (format: Organization/Name). Not a local filename." -ForegroundColor DarkGray
    Write-Host "  2) Folder name under .\models\ and optional file filter (comma-separated Hub paths / globs)." -ForegroundColor DarkGray
    Write-Host ""
    $repo = Read-Host "Hugging Face repo id (org/model, e.g. Qwen/Qwen2.5-0.5B-Instruct or google/gemma-2-2b-it)"
    $idInput = Read-Host "Local folder name under .\models\ (blank = last segment of repo id)"
    Write-Host "File filter - press Enter alone to download the entire repo (all shards + tokenizers; large but no pattern guessing)." -ForegroundColor DarkGray
    Write-Host "Or list comma-separated patterns for hf download --include (each can be a glob). Do NOT paste your local folder name here." -ForegroundColor DarkGray
    Write-Host "Examples:" -ForegroundColor DarkGray
    Write-Host "  One GGUF:  Qwen3-4B-Q4_K_M.gguf" -ForegroundColor DarkGray
    Write-Host "  Sharded safetensors + configs (e.g. Qwen/Qwen3.5-4B):  model.safetensors*,config.json,tokenizer.json,tokenizer_config.json,chat_template.jinja,merges.txt,vocab.json,preprocessor_config.json,video_preprocessor_config.json" -ForegroundColor DarkGray
    Write-Host "GenAI GGUF preview: prefer Q4_K_M / Q8_0 / FP16-style files; IQ2/IQ3 and similar often fail to load (not a Loomis bug)." -ForegroundColor DarkGray
    $filesFilter = Read-Host "Files/patterns (comma-separated, or Enter = full repo)"
    $filterTrim = if ($null -eq $filesFilter) { "" } else { $filesFilter.Trim() }
    $idTrim = if ($null -eq $idInput) { "" } else { $idInput.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($filterTrim) -and ($filterTrim -eq $idTrim)) {
        Write-Host "[Setup] Filter matches your local folder name, not a file on the Hub. That downloads 0 files. Clearing filter -> full repo download." -ForegroundColor Yellow
        $filesFilter = ""
    }
    $downloadedId = Download-Model -Repo $repo -ModelId $idInput -FilesFilter $filesFilter
    $dlDir = Join-Path $scriptDir (Join-Path "models" $downloadedId)
    if (-not [string]::IsNullOrWhiteSpace(($filesFilter + "").Trim())) {
        $got = @(Get-ChildItem -LiteralPath $dlDir -File -Force -ErrorAction SilentlyContinue)
        if ($got.Count -eq 0) {
            throw @"
[Setup] Hub download matched no files (empty folder: $dlDir).
  Your filter was: '$($filesFilter.Trim())'
  Filters must be filenames or globs that exist in the repo (e.g. model.safetensors*, *.json), not the model id alone.
  Re-run setup: leave Files/patterns blank for a full snapshot, or paste the long sharded example from the text above.
"@
        }
    }
    $modelId = $downloadedId
    $modelPath = "./models/$downloadedId"
    if (-not [string]::IsNullOrWhiteSpace($filterTrim) -and ($filterTrim -match "\.gguf")) {
        $modelFormat = "gguf"
        Write-Host "[Setup] Detected .gguf in filter; registry format set to gguf. OpenVINO GenAI (2025.2+) can load many GGUF files directly (preview; arch/quant limits apply). start_app.ps1 passes the path to npu_wrapper; IR folders remain supported." -ForegroundColor Yellow
        if ($filterTrim -match "IQ[0-9]") {
            Write-Host "[Setup] Your filter looks like an IQ* / ultra-low-bit GGUF. If npu_wrapper fails with gguf_tensor_to_f16, pick a Q4_K_M or Q8_0 variant from the same repo, or use exported OpenVINO IR." -ForegroundColor Yellow
        }
    }
    $dlForFormat = Join-Path $scriptDir (Join-Path "models" $downloadedId)
    if (Test-Path -LiteralPath $dlForFormat) {
        $stFiles = @(Get-ChildItem -LiteralPath $dlForFormat -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.(?i)safetensors$' })
        $xmlFiles = @(Get-ChildItem -LiteralPath $dlForFormat -Filter "*.xml" -File -ErrorAction SilentlyContinue)
        if ($stFiles.Count -gt 0 -and $xmlFiles.Count -eq 0 -and ($modelFormat -ne "gguf")) {
            $modelFormat = "safetensors"
            if ($backendType -eq "builtin") {
            Write-Host "[Setup] Downloaded Hugging Face .safetensors weights (not runnable until converted to OpenVINO IR)." -ForegroundColor Yellow
            if (Read-YesNo -Prompt "Run automatic OpenVINO IR export now (installs optimum-intel + PyTorch if needed; long run; VLMs may fail)?" -DefaultYes $true) {
                $irOut = Join-Path $scriptDir (Join-Path "models" "${downloadedId}-ov-ir")
                $exportScript = Join-Path $scriptDir "Export-HfFolderToOpenVinoIR.ps1"
                & $exportScript -ProjectRoot $scriptDir -HfModelDir $dlForFormat -IrOutputDir $irOut -TrustRemoteCode
                $xmlDone = Get-ChildItem -LiteralPath $irOut -Filter "*.xml" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($xmlDone) {
                    $modelPath = "./models/${downloadedId}-ov-ir"
                    $modelFormat = "openvino"
                    Write-Host "[Setup] IR export succeeded. Registry will use $modelPath" -ForegroundColor Green
                } else {
                    Write-Host "[Setup] Export finished without .xml in output. You can re-run: .\Export-HfFolderToOpenVinoIR.ps1 ... or .\start_app.ps1 -AutoExportIr" -ForegroundColor Yellow
                }
            } else {
                Write-Host "        Skip: run later: .\Export-HfFolderToOpenVinoIR.ps1 -ProjectRoot '$scriptDir' -HfModelDir '$dlForFormat' -IrOutputDir '.\models\${downloadedId}-ov-ir' -TrustRemoteCode" -ForegroundColor DarkGray
                Write-Host "        Or: .\start_app.ps1 -AutoExportIr (uses registry selected HF folder)." -ForegroundColor DarkGray
            }
            } else {
                Write-Host "[Setup] Hugging Face .safetensors snapshot saved. External backend: start_app passes this path to your entrypoint as-is (no OpenVINO export in setup)." -ForegroundColor Cyan
            }
        }
    }
} else {
    $pathInput = Read-Host "Model path (default: ./models/Qwen2.5-0.5B-Instruct)"
    $idInput = Read-Host "Model id (default: openvino-local)"
    if (-not [string]::IsNullOrWhiteSpace($pathInput)) { $modelPath = $pathInput.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($idInput)) { $modelId = $idInput.Trim() }
}

Add-OrUpdateModel -RegistryPath $modelsRegistryPath -Id $modelId -Path $modelPath -Format $modelFormat -Backend $backendId

$enablePerformanceMode = $false
if ($backendType -eq "builtin") {
    $enablePerformanceMode = Read-YesNo -Prompt "Enable performance mode defaults (PERFORMANCE policy + split/context routing)?" -DefaultYes $true
}

$perfProfilePath = Join-Path $scriptDir "registry\performance_profile.json"
$perfPolicy = if ($enablePerformanceMode) { "PERFORMANCE" } else { "BALANCED" }
$perfProfile = if ($enablePerformanceMode) { "balanced-performance" } else { "default" }
$perfReason = if ($enablePerformanceMode) { "portable-setup-default" } else { "portable-setup-default-balanced" }
([ordered]@{
    policy = $perfPolicy
    performance_profile = $perfProfile
    performance_reason = $perfReason
} | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $perfProfilePath -Encoding UTF8

Write-Host ""
Write-Host "[Setup] Registry configured:" -ForegroundColor Green
Write-Host "  Model   : $modelId ($modelPath)"
Write-Host "  Backend : $backendId ($backendEntrypoint)"
Write-Host "  Perf    : $perfProfile ($perfPolicy)"

Ensure-LoomisCommandInProfile -ProjectRoot $scriptDir
Ensure-LoomisGlobalCommand -ProjectRoot $scriptDir

if (-not $NoLaunch) {
    $launch = Read-YesNo -Prompt "Launch control panel now?" -DefaultYes $true
    if ($launch) {
        if ($enablePerformanceMode) {
            & (Join-Path $scriptDir "start_app.ps1") -ModelPath $modelPath -ApiPort $ApiPort -AppPort $AppPort -PerformanceMode
        } else {
            & (Join-Path $scriptDir "start_app.ps1") -ModelPath $modelPath -ApiPort $ApiPort -AppPort $AppPort
        }
        if ($LASTEXITCODE -ne 0) {
            throw "start_app.ps1 failed"
        }
        Write-Host ""
        Write-Host "[Setup] Chat from terminal:" -ForegroundColor Cyan
        Write-Host "  .\\npu_cli.ps1 -Command chat"
    }
}
