param(
    [string]$ApiBase = "http://127.0.0.1:8000",
    [string]$Model = "openvino",
    [int]$WarmupRuns = 1,
    [int]$TimedRuns = 4,
    [int]$MaxTokens = 128
)

$ErrorActionPreference = "Stop"

function Invoke-ApiJson {
    param(
        [string]$Path,
        [string]$Method = "GET",
        [object]$Body = $null,
        [int]$TimeoutSec = 180
    )
    $params = @{
        Uri         = "$ApiBase$Path"
        Method      = $Method
        TimeoutSec  = $TimeoutSec
        ErrorAction = "Stop"
        Headers     = @{ "x-npu-cli" = "true" }
    }
    if ($null -ne $Body) {
        $params.ContentType = "application/json"
        $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }
    return Invoke-RestMethod @params
}

function Get-GpuMemoryUsedMb {
    $cmd = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try {
        $lines = & $cmd.Source --query-gpu=memory.used --format=csv,noheader,nounits 2>$null
        if (-not $lines) { return $null }
        $vals = @()
        foreach ($line in $lines) {
            $trimmed = [string]$line
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
            $num = 0
            if ([int]::TryParse($trimmed.Trim(), [ref]$num)) {
                $vals += $num
            }
        }
        if ($vals.Count -eq 0) { return $null }
        return ($vals | Measure-Object -Maximum).Maximum
    } catch {
        return $null
    }
}

function Set-Feature {
    param(
        [string]$Name,
        [bool]$Enabled
    )
    $resp = Invoke-ApiJson -Path "/v1/cli/feature/$Name" -Method "POST" -Body @{ enabled = $Enabled } -TimeoutSec 30
    return $resp
}

function Try-SetFeature {
    param(
        [string]$Name,
        [bool]$Enabled
    )
    try {
        $resp = Set-Feature -Name $Name -Enabled $Enabled
        return [pscustomobject]@{
            ok = $true
            feature = $Name
            enabled = $Enabled
            response = $resp
            note = ""
        }
    } catch {
        $msg = $_.Exception.Message
        Write-Host "Feature toggle failed for '$Name' -> $($Enabled): $msg" -ForegroundColor Yellow
        return [pscustomobject]@{
            ok = $false
            feature = $Name
            enabled = $Enabled
            response = $null
            note = $msg
        }
    }
}

function Run-OneInference {
    param(
        [string]$Prompt,
        [int]$MaxNewTokens
    )

    $gpuBefore = Get-GpuMemoryUsedMb
    $start = Get-Date
    $response = Invoke-ApiJson -Path "/v1/chat/completions" -Method "POST" -Body @{
        model       = $Model
        stream      = $false
        temperature = 0.1
        max_tokens  = $MaxNewTokens
        messages    = @(
            @{ role = "user"; content = $Prompt }
        )
    } -TimeoutSec 240
    $elapsedMs = ((Get-Date) - $start).TotalMilliseconds
    $gpuAfter = Get-GpuMemoryUsedMb

    $status = Invoke-ApiJson -Path "/v1/cli/status" -Method "GET" -TimeoutSec 30
    $metricsLast = Invoke-ApiJson -Path "/v1/cli/metrics?mode=last" -Method "GET" -TimeoutSec 30

    $completionTokens = $null
    $promptTokens = $null
    if ($response.usage) {
        if ($response.usage.PSObject.Properties.Name -contains "completion_tokens") {
            $completionTokens = [int]$response.usage.completion_tokens
        }
        if ($response.usage.PSObject.Properties.Name -contains "prompt_tokens") {
            $promptTokens = [int]$response.usage.prompt_tokens
        }
    }

    $tokensPerSec = $null
    if ($completionTokens -and $elapsedMs -gt 0) {
        $tokensPerSec = [math]::Round(($completionTokens / ($elapsedMs / 1000.0)), 3)
    }

    $peakGpuMb = $null
    if ($null -ne $gpuAfter -and $null -ne $gpuBefore) {
        $peakGpuMb = [Math]::Max([int]$gpuBefore, [int]$gpuAfter)
    } elseif ($null -ne $gpuAfter) {
        $peakGpuMb = [int]$gpuAfter
    } elseif ($null -ne $gpuBefore) {
        $peakGpuMb = [int]$gpuBefore
    }

    return [pscustomobject]@{
        wall_ms            = [math]::Round($elapsedMs, 2)
        ttft_ms            = if ($status.ttft_ms) { [double]$status.ttft_ms } else { $null }
        tpot_ms            = if ($status.tpot_ms) { [double]$status.tpot_ms } else { $null }
        status_tps         = if ($status.throughput) { [double]$status.throughput } else { $null }
        status_split_prefill = if ($status.split_prefill) { [string]$status.split_prefill } else { $null }
        status_context_routing = if ($status.context_routing) { [string]$status.context_routing } else { $null }
        status_optimize_memory = if ($status.optimize_memory) { [string]$status.optimize_memory } else { $null }
        total_ms_metrics   = if ($metricsLast.total_ms) { [double]$metricsLast.total_ms } else { $null }
        completion_tokens  = $completionTokens
        prompt_tokens      = $promptTokens
        calc_tokens_per_s  = $tokensPerSec
        gpu_mem_peak_mb    = $peakGpuMb
    }
}

function Run-Scenario {
    param(
        [string]$Name,
        [bool]$SplitPrefill,
        [bool]$ContextRouting,
        [string]$Prompt
    )

    Write-Host ""
    Write-Host "=== Scenario: $Name ===" -ForegroundColor Cyan
    Write-Host "Setting split-prefill=$SplitPrefill context-routing=$ContextRouting"
    $splitResult = Try-SetFeature -Name "split-prefill" -Enabled $SplitPrefill
    $ctxResult = Try-SetFeature -Name "context-routing" -Enabled $ContextRouting
    $memResult = Try-SetFeature -Name "optimize-memory" -Enabled $ContextRouting
    if (-not $splitResult.ok -and $SplitPrefill) {
        Write-Host "Falling back to split-prefill=false for this scenario." -ForegroundColor Yellow
        Try-SetFeature -Name "split-prefill" -Enabled $false | Out-Null
    }
    Invoke-ApiJson -Path "/v1/cli/metrics?mode=clear" -Method "GET" -TimeoutSec 30 | Out-Null

    for ($i = 1; $i -le $WarmupRuns; $i++) {
        Write-Host "Warmup run $i/$WarmupRuns..."
        $null = Run-OneInference -Prompt $Prompt -MaxNewTokens $MaxTokens
    }

    $rows = @()
    for ($i = 1; $i -le $TimedRuns; $i++) {
        Write-Host "Timed run $i/$TimedRuns..."
        $r = Run-OneInference -Prompt $Prompt -MaxNewTokens $MaxTokens
        $r | Add-Member -NotePropertyName scenario -NotePropertyValue $Name
        $r | Add-Member -NotePropertyName run_index -NotePropertyValue $i
        $r | Add-Member -NotePropertyName split_prefill_requested -NotePropertyValue $SplitPrefill
        $r | Add-Member -NotePropertyName split_prefill_applied -NotePropertyValue $splitResult.ok
        $r | Add-Member -NotePropertyName context_routing_requested -NotePropertyValue $ContextRouting
        $r | Add-Member -NotePropertyName context_routing_applied -NotePropertyValue $ctxResult.ok
        $r | Add-Member -NotePropertyName optimize_memory_applied -NotePropertyValue $memResult.ok
        $rows += $r
    }
    return $rows
}

Write-Host "Checking API health at $ApiBase..."
$health = Invoke-ApiJson -Path "/v1/health" -Method "GET" -TimeoutSec 20
Write-Host ("Health: " + ($health | ConvertTo-Json -Compress))

$prompt = "Write five concise bullet points about why local LLM inference can improve privacy."

$enabledRows = Run-Scenario -Name "acoulm_enabled" -SplitPrefill $true -ContextRouting $true -Prompt $prompt
$baselineRows = Run-Scenario -Name "baseline_single_path" -SplitPrefill $false -ContextRouting $false -Prompt $prompt

$allRows = @($enabledRows + $baselineRows)

if ($allRows.Count -eq 0) {
    throw "No benchmark rows were produced."
}

function Get-Avg($rows, $name) {
    $vals = @($rows | ForEach-Object { $_.$name } | Where-Object { $null -ne $_ })
    if ($vals.Count -eq 0) { return $null }
    return [math]::Round((($vals | Measure-Object -Average).Average), 3)
}

function Summarize($rows, $name) {
    return [pscustomobject]@{
        scenario           = $name
        runs               = $rows.Count
        avg_wall_ms        = Get-Avg $rows "wall_ms"
        avg_ttft_ms        = Get-Avg $rows "ttft_ms"
        avg_tpot_ms        = Get-Avg $rows "tpot_ms"
        avg_status_tps     = Get-Avg $rows "status_tps"
        avg_calc_tokens_s  = Get-Avg $rows "calc_tokens_per_s"
        avg_gpu_peak_mb    = Get-Avg $rows "gpu_mem_peak_mb"
        avg_total_ms_metric = Get-Avg $rows "total_ms_metrics"
    }
}

$enabledSummary = Summarize -rows $enabledRows -name "acoulm_enabled"
$baselineSummary = Summarize -rows $baselineRows -name "baseline_single_path"

$outDir = Join-Path $PSScriptRoot "benchmark_outputs"
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -Path $outDir -ItemType Directory | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$rowsPath = Join-Path $outDir "bench_rows_$timestamp.json"
$summaryPath = Join-Path $outDir "bench_summary_$timestamp.json"
$allRows | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $rowsPath -Encoding UTF8
@($enabledSummary, $baselineSummary) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host ""
Write-Host "=== Benchmark Summary ===" -ForegroundColor Green
@($enabledSummary, $baselineSummary) | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "Rows JSON: $rowsPath"
Write-Host "Summary JSON: $summaryPath"
