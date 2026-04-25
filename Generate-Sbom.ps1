param(
    [string]$ProjectRoot = ""
)
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$outDir = Join-Path $ProjectRoot "sbom"
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$dist = Join-Path $ProjectRoot "dist"
$out = Join-Path $outDir ("dist-sbom-" + (Get-Date -Format "yyyyMMdd") + ".txt")
$lines = @(
    "# AcouLM dist/ file inventory (SBOM-style list of shipped binaries)",
    "# Generated: $(Get-Date -Format o)",
    ""
)
if (Test-Path -LiteralPath $dist) {
    Get-ChildItem -LiteralPath $dist -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        $lines += ("{0}`t{1}" -f $_.Name, $_.Length)
    }
} else {
    $lines += "(dist/ not present — run build or extract release zip)"
}
$lines | Set-Content -LiteralPath $out -Encoding UTF8
Write-Host "[SBOM] Wrote $out"
