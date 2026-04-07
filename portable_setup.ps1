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
        $reg = [ordered]@{ schema = 1; selected_model = $Id; models = @() }
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
        [string]$Entrypoint
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

    if ($null -eq $existing) {
        $entry = [pscustomobject]@{
            id = $Id
            type = $Type
            entrypoint = $Entrypoint
            formats = @("openvino")
            status = "ready"
        }
        $reg.backends += $entry
    } else {
        $existing.type = $Type
        $existing.entrypoint = $Entrypoint
        $existing.formats = @("openvino")
        $existing.status = "ready"
    }

    $reg.selected_backend = $Id
    Save-JsonFile -Path $RegistryPath -Data $reg
}

function Download-Model {
    param(
        [string]$Repo,
        [string]$ModelId
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

    Write-Host "[Setup] Downloading model '$Repo' into '$target'..." -ForegroundColor Cyan

    $hfCli = Get-Command huggingface-cli -ErrorAction SilentlyContinue
    if ($hfCli) {
        & huggingface-cli download $Repo --local-dir $target --local-dir-use-symlinks False | Out-Host
        return $ModelId
    }

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCmd) {
        throw "Neither huggingface-cli nor git is available. Install one of them to download model files."
    }

    if (Test-Path (Join-Path $target ".git")) {
        Push-Location $target
        git pull | Out-Host
        Pop-Location
    } else {
        if (Test-Path $target) {
            Remove-Item -Recurse -Force $target
        }
        git clone "https://huggingface.co/$Repo" $target | Out-Host
    }

    return $ModelId
}

$modelsRegistryPath = Join-Path $scriptDir "registry\models_registry.json"
$backendsRegistryPath = Join-Path $scriptDir "registry\backends_registry.json"

Ensure-RegistryFile -Path $modelsRegistryPath -Default ([ordered]@{
    schema = 1
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
            formats = @("openvino")
            status = "ready"
        }
    )
})

$exePath = Join-Path $scriptDir "dist\npu_wrapper.exe"
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

$modelId = "openvino-local"
$modelPath = "./models/Qwen2.5-0.5B-Instruct"
$modelFormat = "openvino"

if (Read-YesNo -Prompt "Download a model from Hugging Face now?" -DefaultYes $false) {
    $repo = Read-Host "HF repo (e.g. Qwen/Qwen2.5-0.5B-Instruct)"
    $idInput = Read-Host "Local model id (blank = repo tail)"
    $downloadedId = Download-Model -Repo $repo -ModelId $idInput
    $modelId = $downloadedId
    $modelPath = "./models/$downloadedId"
} else {
    $pathInput = Read-Host "Model path (default: ./models/Qwen2.5-0.5B-Instruct)"
    $idInput = Read-Host "Model id (default: openvino-local)"
    if (-not [string]::IsNullOrWhiteSpace($pathInput)) { $modelPath = $pathInput.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($idInput)) { $modelId = $idInput.Trim() }
}

Add-OrUpdateModel -RegistryPath $modelsRegistryPath -Id $modelId -Path $modelPath -Format $modelFormat -Backend $backendId

Write-Host ""
Write-Host "[Setup] Registry configured:" -ForegroundColor Green
Write-Host "  Model   : $modelId ($modelPath)"
Write-Host "  Backend : $backendId ($backendEntrypoint)"

if (-not $NoLaunch) {
    $launch = Read-YesNo -Prompt "Launch control panel now?" -DefaultYes $true
    if ($launch) {
        & (Join-Path $scriptDir "start_app.ps1") -ModelPath $modelPath -ApiPort $ApiPort -AppPort $AppPort
        if ($LASTEXITCODE -ne 0) {
            throw "start_app.ps1 failed"
        }
        Write-Host ""
        Write-Host "[Setup] Chat from terminal:" -ForegroundColor Cyan
        Write-Host "  .\\npu_cli.ps1 -Command chat"
    }
}
