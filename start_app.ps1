param(
    [string]$ModelPath = "",
    [string]$Device = "",
    [int]$ApiPort = 8000,
    [int]$AppPort = 5173,
    [int]$TimeoutSeconds = 120,
    [switch]$HideServiceWindows,
    [string[]]$BackendArgs = @()
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

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
    param([string]$FallbackPath = "./models/Qwen2.5-0.5B-Instruct")

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

function Test-DirHasOpenVINOIr {
    param([string]$FullPath)
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return $false }
    if (-not (Test-Path -LiteralPath $FullPath -PathType Container)) { return $false }
    $xml = Get-ChildItem -LiteralPath $FullPath -Filter "*.xml" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    return [bool]$xml
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

    & $add "./models/Qwen2.5-0.5B-Instruct"
    return ,$list.ToArray()
}

$registryPick = Get-RegistrySelectedModel

if ([string]::IsNullOrWhiteSpace($ModelPath)) {
    $ModelPath = $registryPick.Path
}

$ModelPath = Normalize-ModelPathString $ModelPath

$modelDirFull = Resolve-FullModelDirectory -ModelPath $ModelPath -ProjectRoot $scriptDir
$dirExists = $modelDirFull -and (Test-Path -LiteralPath $modelDirFull -PathType Container)
$hasIr = $dirExists -and (Test-DirHasOpenVINOIr -FullPath $modelDirFull)

if (-not $hasIr) {
    $fallback = $null
    foreach ($rel in (Get-OpenVinoRunnableCandidates -ProjectRoot $scriptDir -PreferPath $ModelPath)) {
        $full = Resolve-FullModelDirectory -ModelPath $rel -ProjectRoot $scriptDir
        if (Test-DirHasOpenVINOIr -FullPath $full) {
            $fallback = @{ Relative = $rel; Full = $full }
            break
        }
    }

    if ($fallback) {
        if ($dirExists -and -not (Test-DirHasOpenVINOIr -FullPath $modelDirFull)) {
            Write-Host "[App] Registry path has no OpenVINO IR (.xml): $ModelPath" -ForegroundColor Yellow
            if ($registryPick.Format -match "^(?i)gguf$") {
                Write-Host "      (GGUF folders are not valid for npu_wrapper; GenAI needs exported IR.)" -ForegroundColor DarkYellow
            }
        } elseif (-not $dirExists) {
            Write-Host "[App] Model directory missing: $modelDirFull" -ForegroundColor Yellow
        }
        Write-Host "[App] Starting with runnable OpenVINO model instead: $($fallback.Relative)" -ForegroundColor Cyan
        Write-Host "      Update selected_model in registry\models_registry.json when you have an IR build." -ForegroundColor DarkGray
        $ModelPath = $fallback.Relative
        $modelDirFull = $fallback.Full
    } else {
        if (-not $dirExists) {
            throw "[App] Model directory not found:`n  $modelDirFull`n  (ModelPath was '$ModelPath')`n`nNo other registry path contained OpenVINO IR either. Add a model folder with a .xml (IR) under ./models/ or fix registry paths."
        }
        $ggufNote = ""
        if ($registryPick.Format -match "^(?i)gguf$") {
            $ggufNote = "`n`nThe selected registry entry is GGUF-only. npu_wrapper needs OpenVINO IR (openvino_model.xml + weights), not .gguf files."
        }
        throw "[App] No OpenVINO IR (.xml) found anywhere we tried (selected path + other registry entries + ./models/Qwen2.5-0.5B-Instruct).`n  Checked folder: $modelDirFull$ggufNote`n`nDownload or convert an OpenVINO IR model into ./models/... and register it. See README: 'Could not find a model in the directory'."
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

    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = "cmd.exe"
        $startInfo.Arguments = "/c start `"Browser`" `"$Url`""
        $startInfo.CreateNoWindow = $true
        $startInfo.UseShellExecute = $false
        [System.Diagnostics.Process]::Start($startInfo) | Out-Null
        return $true
    } catch {
        try {
            Start-Process $Url -ErrorAction Stop
            return $true
        } catch {
            return $false
        }
    }
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

    $runScript = Join-Path $scriptDir "run.ps1"
    if (-not (Test-Path $runScript)) {
        throw "[App] Missing run script: $runScript"
    }

    $escapedBackendArgs = @()
    foreach ($arg in $Args) {
        if ($null -eq $arg -or $arg -eq "") { continue }
        $escaped = $arg.Replace('"', '`"')
        if ($escaped -match '\s') {
            $escapedBackendArgs += '"' + $escaped + '"'
        } else {
            $escapedBackendArgs += $escaped
        }
    }

    $backendCmd = "Set-Location '$scriptDir'; & '$runScript' '$Model' --server --port $Port"
    if ($DeviceOverride -and $DeviceOverride -ne "") {
        $backendCmd += " --device $DeviceOverride"
    }
    if ($escapedBackendArgs.Count -gt 0) {
        $backendCmd += " " + ($escapedBackendArgs -join " ")
    }

    $windowStyle = if ($HideWindow) { "Hidden" } else { "Normal" }
    Start-Process powershell -ArgumentList "-NoExit", "-Command", $backendCmd -WindowStyle $windowStyle | Out-Null
}

function Wait-ForApiReady {
    param(
        [int]$Port,
        [int]$TimeoutSec
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort -Hostname "127.0.0.1" -Port $Port -TimeoutMs 500) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

Write-Host "[App] Project root: $scriptDir" -ForegroundColor Cyan
Write-Host "[App] Starting backend API + App Shell (OpenWebUI disabled)..." -ForegroundColor Cyan

Write-Host "[App] Stopping stale backend/app shell processes..." -ForegroundColor Yellow
Stop-BackendServer
Stop-AppShellServer -Port $AppPort

Start-BackendServer -Model $ModelPath -DeviceOverride $Device -Port $ApiPort -HideWindow:$HideServiceWindows -Args $BackendArgs

if (Wait-ForApiReady -Port $ApiPort -TimeoutSec $TimeoutSeconds) {
    Write-Host "[App] Backend API is ready at http://localhost:$ApiPort/v1" -ForegroundColor Green
} else {
    throw "[App] Backend API did not become ready on port $ApiPort within $TimeoutSeconds seconds."
}

Write-Host "[App] Preparing app shell on port $AppPort..." -ForegroundColor Cyan

$pythonExe = Join-Path $scriptDir "venv\Scripts\python.exe"
$pythonCmd = if (Test-Path $pythonExe) { "& '$pythonExe'" } else { "python" }
$appShellCmd = "Set-Location '$scriptDir'; $pythonCmd -m http.server $AppPort --directory app_shell"
$windowStyle = if ($HideServiceWindows) { "Hidden" } else { "Normal" }
Start-Process powershell -ArgumentList "-NoExit", "-Command", $appShellCmd -WindowStyle $windowStyle | Out-Null

$deadline = (Get-Date).AddSeconds(30)
$appReady = $false
while ((Get-Date) -lt $deadline) {
    if (Test-TcpPort -Hostname "127.0.0.1" -Port $AppPort -TimeoutMs 500) {
        $appReady = $true
        break
    }
    Start-Sleep -Milliseconds 500
}

$appUrl = "http://localhost:$AppPort"
$apiBase = "http://localhost:$ApiPort/v1"

if ($appReady) {
    Write-Host "[App] App shell is ready at $appUrl" -ForegroundColor Green
} else {
    Write-Host "[App] App shell did not report ready within timeout, but process was started." -ForegroundColor Yellow
}

if (Open-Url -Url $appUrl) {
    Write-Host "[App] Opened app shell in browser." -ForegroundColor Green
} else {
    Write-Host "[App] Could not auto-open browser. Open manually: $appUrl" -ForegroundColor Yellow
}

Write-Host "`n[App] Ready." -ForegroundColor Green
Write-Host "Primary UI (App Shell): $appUrl"
Write-Host "API base: $apiBase"
