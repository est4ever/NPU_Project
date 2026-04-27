param(
    [string]$ProjectRoot = ""
)
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$exportDir = Join-Path $ProjectRoot "export"
if (-not (Test-Path -LiteralPath $exportDir)) {
    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
}
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$work = Join-Path $env:TEMP ("acoulm-diag-" + $stamp)
New-Item -ItemType Directory -Path $work -Force | Out-Null

function Redact-Path {
    param([string]$Line)
    return [regex]::Replace($Line, '([A-Za-z]:\\Users\\)([^\\]+)', { param($m) $m.Groups[1].Value + "<user>\\" })
}

# Registry examples + redacted copies of local registries if present
$regDir = Join-Path $ProjectRoot "registry"
foreach ($name in @("models_registry.json", "backends_registry.json")) {
    $p = Join-Path $regDir $name
    if (Test-Path -LiteralPath $p) {
        $raw = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
        if ($raw) {
            Redact-Path $raw | Set-Content -Path (Join-Path $work ("redacted_" + $name)) -Encoding UTF8
        }
    }
}
Get-ChildItem -Path $regDir -Filter "*.example.json" -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $work $_.Name) -Force
}

# Metrics tail
$metrics = Join-Path $ProjectRoot "metrics.ndjson"
if (Test-Path -LiteralPath $metrics) {
    Get-Content -LiteralPath $metrics -Tail 80 -ErrorAction SilentlyContinue | Set-Content (Join-Path $work "metrics-tail.txt") -Encoding UTF8
}

# dist file list (names only)
$dist = Join-Path $ProjectRoot "dist"
if (Test-Path -LiteralPath $dist) {
    Get-ChildItem -LiteralPath $dist -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name |
        Set-Content (Join-Path $work "dist-files.txt") -Encoding UTF8
}

$zipName = "acoulm-diagnostics-$stamp.zip"
$zipPath = Join-Path $exportDir $zipName
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $work "*") -DestinationPath $zipPath -Force
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue

$marker = Join-Path $exportDir "last-export.txt"
$zipPath | Set-Content -LiteralPath $marker -Encoding ASCII
Write-Host "[Export-Diagnostics] $zipPath"
