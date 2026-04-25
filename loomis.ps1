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
$newLauncher = Join-Path $scriptDir "acoulm.ps1"

if (-not (Test-Path -LiteralPath $newLauncher)) {
    throw "AcouLM launcher not found at $newLauncher"
}

& $newLauncher -ApiBase $ApiBase -Prompt $Prompt -Command $Command -Arguments $Arguments @Passthrough
exit $LASTEXITCODE
