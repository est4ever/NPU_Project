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
            & $start
            exit $LASTEXITCODE
        }
        "status" {
            $base = $ApiBase.TrimEnd("/")
            try {
                $r = Invoke-RestMethod -Uri "$base/v1/cli/status" -Method Get -TimeoutSec 15
                $r | ConvertTo-Json -Depth 6
            } catch {
                Write-Error "Could not reach API at $base. Start the stack with: loomis start"
                exit 1
            }
            exit 0
        }
        "help" {
            @"
Loomis
  loomis              Open terminal chat (npu_cli)
  loomis chat         Same as default
  loomis start        Run start_app.ps1 (API + app shell)
  loomis status       GET /v1/cli/status from default API
  loomis <npu args>   Forward to npu_cli.ps1
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
    $quotedScriptDir = $scriptDir.Replace("'", "''")
    $startCommand = "Set-Location -LiteralPath '$quotedScriptDir'; .\start_app.ps1"
    Start-Process powershell -ArgumentList @("-NoExit", "-ExecutionPolicy", "Bypass", "-Command", $startCommand) | Out-Null
    & $cli -Command chat
}
