param(
    [string]$ApiBase = "http://localhost:8000",
    [string]$Prompt = "",
    [string]$Command = "",
    [string[]]$Arguments = @(),
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Passthrough
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cli = Join-Path $scriptDir "npu_cli.ps1"
$start = Join-Path $scriptDir "start_app.ps1"
$appUrl = "http://localhost:5173"

function Test-ApiReady {
    param([string]$Base = "http://localhost:8000")
    $b = $Base.TrimEnd("/")
    try {
        $null = Invoke-RestMethod -Uri "$b/v1/health" -Method Get -TimeoutSec 2 -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Open-AppShellBestEffort {
    param([string]$Url = "http://localhost:5173")
    try {
        Start-Process $Url -ErrorAction Stop | Out-Null
    } catch {}
}

if (-not (Test-Path -LiteralPath $cli)) {
    throw "Missing CLI script: $cli"
}

$sub = $null
$tail = [string[]]@()
if ($Passthrough -and $Passthrough.Count -gt 0) {
    $first = [string]$Passthrough[0]
    if ($first -notlike "-*" -and $first -in @("start", "chat", "status", "help")) {
        $sub = $first.ToLowerInvariant()
        if ($Passthrough.Count -gt 1) {
            $tail = $Passthrough[1..($Passthrough.Count - 1)]
        }
    }
}

if ($sub) {
    switch ($sub) {
        "start" {
            if (-not (Test-Path -LiteralPath $start)) { throw "Missing start_app.ps1 at $start" }
            & $start -HideServiceWindows
            exit $LASTEXITCODE
        }
        "status" {
            $base = $ApiBase.TrimEnd("/")
            try {
                $r = Invoke-RestMethod -Uri "$base/v1/cli/status" -Method Get -TimeoutSec 15
                $r | ConvertTo-Json -Depth 6
            } catch {
                Write-Error "Could not reach API at $base. Start the stack with: acoulm start"
                exit 1
            }
            exit 0
        }
        "help" {
            @"
AcouLM
  acoulm              Start stack quietly (hidden service windows) + terminal chat; browser opens when ready
  acoulm chat         Same as default
  acoulm start        Run start_app.ps1 (API + app shell, service windows hidden)
  acoulm status       GET /v1/cli/status from default API
  acoulm <npu args>   Forward to npu_cli.ps1

  Tip: To show backend/app-shell PowerShell windows (debug), run .\start_app.ps1 without -HideServiceWindows.
"@ | Write-Host
            exit 0
        }
        "chat" {
            if ($tail.Count -gt 0) { & $cli @tail }
            else { & $cli -Command chat }
            exit $LASTEXITCODE
        }
    }
}

if ($Passthrough -and $Passthrough.Count -gt 0) {
    & $cli @Passthrough
} elseif (-not [string]::IsNullOrWhiteSpace($Command) -or -not [string]::IsNullOrWhiteSpace($Prompt) -or ($Arguments -and $Arguments.Count -gt 0) -or $ApiBase -ne "http://localhost:8000") {
    & $cli -ApiBase $ApiBase -Prompt $Prompt -Command $Command -Arguments $Arguments
} else {
    if (-not (Test-Path -LiteralPath $start)) { throw "Missing start_app.ps1 at $start" }

    # Speed path: if stack is already up, skip full restart and jump to chat.
    if (Test-ApiReady -Base $ApiBase) {
        Open-AppShellBestEffort -Url $appUrl
    } else {
        $quotedScriptDir = $scriptDir.Replace("'", "''")
        # Hidden launcher: backend + http.server run in hidden consoles; browser opens from start_app.ps1.
        $startCommand = "Set-Location -LiteralPath '$quotedScriptDir'; .\start_app.ps1 -HideServiceWindows"
        Start-Process powershell -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-WindowStyle", "Hidden",
            "-Command", $startCommand
        ) | Out-Null
        Write-Host "AcouLM: starting stack in background..." -ForegroundColor DarkCyan
    }
    & $cli -Command chat
}

