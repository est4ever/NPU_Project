param(
    [string]$ApiBase = "http://127.0.0.1:8000",
    [string]$Model = "openvino",
    [int]$WarmupRuns = 1,
    [int]$TimedRuns = 4,
    [int]$MaxTokens = 128,
    # Interleave enabled/baseline each round (same run index = same thermal epoch) for paired deltas.
    [switch]$PairedInterleaved,
    # Resample each group independently to estimate CI for mean(enabled_wall) - mean(baseline_wall).
    [int]$BootstrapSamples = 800,
    # Poll GET /v1/health every 2s until success (use when starting .\start_app.ps1 in another window).
    [int]$WaitForApiSec = 0
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

function Apply-ScenarioFeatures {
    param(
        [bool]$SplitPrefill,
        [bool]$ContextRouting
    )
    $splitResult = Try-SetFeature -Name "split-prefill" -Enabled $SplitPrefill
    $ctxResult = Try-SetFeature -Name "context-routing" -Enabled $ContextRouting
    $memResult = Try-SetFeature -Name "optimize-memory" -Enabled $ContextRouting
    if (-not $splitResult.ok -and $SplitPrefill) {
        Write-Host "Falling back to split-prefill=false for this scenario." -ForegroundColor Yellow
        Try-SetFeature -Name "split-prefill" -Enabled $false | Out-Null
        $splitResult = [pscustomobject]@{ ok = $false }
    }
    return [pscustomobject]@{
        splitResult = $splitResult
        ctxResult   = $ctxResult
        memResult   = $memResult
    }
}

function Add-ScenarioMetadata {
    param(
        $row,
        [string]$Name,
        [int]$RunIndex,
        [bool]$SplitPrefill,
        [bool]$ContextRouting,
        $meta
    )
    $row | Add-Member -NotePropertyName scenario -NotePropertyValue $Name -Force
    $row | Add-Member -NotePropertyName run_index -NotePropertyValue $RunIndex -Force
    $row | Add-Member -NotePropertyName split_prefill_requested -NotePropertyValue $SplitPrefill -Force
    $row | Add-Member -NotePropertyName split_prefill_applied -NotePropertyValue $meta.splitResult.ok -Force
    $row | Add-Member -NotePropertyName context_routing_requested -NotePropertyValue $ContextRouting -Force
    $row | Add-Member -NotePropertyName context_routing_applied -NotePropertyValue $meta.ctxResult.ok -Force
    $row | Add-Member -NotePropertyName optimize_memory_applied -NotePropertyValue $meta.memResult.ok -Force
    return $row
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
    $meta = Apply-ScenarioFeatures -SplitPrefill $SplitPrefill -ContextRouting $ContextRouting
    Invoke-ApiJson -Path "/v1/cli/metrics?mode=clear" -Method "GET" -TimeoutSec 30 | Out-Null

    for ($i = 1; $i -le $WarmupRuns; $i++) {
        Write-Host "Warmup run $i/$WarmupRuns..."
        $null = Run-OneInference -Prompt $Prompt -MaxNewTokens $MaxTokens
    }

    $rows = @()
    for ($i = 1; $i -le $TimedRuns; $i++) {
        Write-Host "Timed run $i/$TimedRuns..."
        $r = Run-OneInference -Prompt $Prompt -MaxNewTokens $MaxTokens
        Add-ScenarioMetadata -row $r -Name $Name -RunIndex $i -SplitPrefill $SplitPrefill -ContextRouting $ContextRouting -meta $meta
        $rows += $r
    }
    return $rows
}

function Run-PairedInterleaved {
    param([string]$Prompt)

    Write-Host ""
    Write-Host "=== Paired interleaved mode (reduces thermal/order drift) ===" -ForegroundColor Cyan

    Write-Host "Warmup: acoulm_enabled..."
    $null = Apply-ScenarioFeatures -SplitPrefill $true -ContextRouting $true
    Invoke-ApiJson -Path "/v1/cli/metrics?mode=clear" -Method "GET" -TimeoutSec 30 | Out-Null
    for ($i = 1; $i -le $WarmupRuns; $i++) {
        $null = Run-OneInference -Prompt $Prompt -MaxNewTokens $MaxTokens
    }

    Write-Host "Warmup: baseline_single_path..."
    $null = Apply-ScenarioFeatures -SplitPrefill $false -ContextRouting $false
    Invoke-ApiJson -Path "/v1/cli/metrics?mode=clear" -Method "GET" -TimeoutSec 30 | Out-Null
    for ($i = 1; $i -le $WarmupRuns; $i++) {
        $null = Run-OneInference -Prompt $Prompt -MaxNewTokens $MaxTokens
    }

    $enabledRows = @()
    $baselineRows = @()

    for ($i = 1; $i -le $TimedRuns; $i++) {
        $enabledFirst = (($i % 2) -eq 1)
        Write-Host "Paired timed round $i/$TimedRuns (enabled first: $enabledFirst)..."

        if ($enabledFirst) {
            $metaE = Apply-ScenarioFeatures -SplitPrefill $true -ContextRouting $true
            Invoke-ApiJson -Path "/v1/cli/metrics?mode=clear" -Method "GET" -TimeoutSec 30 | Out-Null
            $rE = Run-OneInference -Prompt $Prompt -MaxNewTokens $MaxTokens
            Add-ScenarioMetadata -row $rE -Name "acoulm_enabled" -RunIndex $i -SplitPrefill $true -ContextRouting $true -meta $metaE
            $rE | Add-Member -NotePropertyName pair_index -NotePropertyValue $i -Force
            $enabledRows += $rE

            $metaB = Apply-ScenarioFeatures -SplitPrefill $false -ContextRouting $false
            Invoke-ApiJson -Path "/v1/cli/metrics?mode=clear" -Method "GET" -TimeoutSec 30 | Out-Null
            $rB = Run-OneInference -Prompt $Prompt -MaxNewTokens $MaxTokens
            Add-ScenarioMetadata -row $rB -Name "baseline_single_path" -RunIndex $i -SplitPrefill $false -ContextRouting $false -meta $metaB
            $rB | Add-Member -NotePropertyName pair_index -NotePropertyValue $i -Force
            $baselineRows += $rB
        } else {
            $metaB = Apply-ScenarioFeatures -SplitPrefill $false -ContextRouting $false
            Invoke-ApiJson -Path "/v1/cli/metrics?mode=clear" -Method "GET" -TimeoutSec 30 | Out-Null
            $rB = Run-OneInference -Prompt $Prompt -MaxNewTokens $MaxTokens
            Add-ScenarioMetadata -row $rB -Name "baseline_single_path" -RunIndex $i -SplitPrefill $false -ContextRouting $false -meta $metaB
            $rB | Add-Member -NotePropertyName pair_index -NotePropertyValue $i -Force
            $baselineRows += $rB

            $metaE = Apply-ScenarioFeatures -SplitPrefill $true -ContextRouting $true
            Invoke-ApiJson -Path "/v1/cli/metrics?mode=clear" -Method "GET" -TimeoutSec 30 | Out-Null
            $rE = Run-OneInference -Prompt $Prompt -MaxNewTokens $MaxTokens
            Add-ScenarioMetadata -row $rE -Name "acoulm_enabled" -RunIndex $i -SplitPrefill $true -ContextRouting $true -meta $metaE
            $rE | Add-Member -NotePropertyName pair_index -NotePropertyValue $i -Force
            $enabledRows += $rE
        }
    }

    return [pscustomobject]@{ enabledRows = $enabledRows; baselineRows = $baselineRows }
}

function Get-DoubleArrayFromRows($rows, [string]$prop) {
    $vals = New-Object "System.Collections.Generic.List[double]"
    foreach ($r in $rows) {
        $v = $r.$prop
        if ($null -ne $v) { $vals.Add([double]$v) }
    }
    return $vals.ToArray()
}

function Get-Median([double[]]$a) {
    if ($null -eq $a -or $a.Length -eq 0) { return $null }
    $s = $a | Sort-Object
    $n = $s.Count
    if (($n % 2) -eq 1) { return [math]::Round($s[($n - 1) / 2], 4) }
    return [math]::Round(($s[$n / 2 - 1] + $s[$n / 2]) / 2.0, 4)
}

function Get-SampleStdDev([double[]]$a) {
    if ($null -eq $a -or $a.Length -lt 2) { return $null }
    $mean = ($a | Measure-Object -Average).Average
    $acc = 0.0
    foreach ($x in $a) { $acc += [math]::Pow($x - $mean, 2) }
    return [math]::Sqrt($acc / ($a.Length - 1))
}

function Get-UnbiasedVariance([double[]]$a) {
    $sd = Get-SampleStdDev $a
    if ($null -eq $sd) { return $null }
    return $sd * $sd
}

function Get-Tcrit975([double]$df) {
    $t = @(
        12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
        2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086,
        2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042,
        2.040, 2.037, 2.035, 2.032, 2.030, 2.028, 2.026, 2.024, 2.021, 2.021
    )
    if ([double]::IsNaN($df) -or $df -lt 1) { return 12.706 }
    if ($df -ge 120) { return 1.980 }
    if ($df -le 40) {
        $idx = [int][math]::Ceiling($df) - 1
        if ($idx -lt 0) { $idx = 0 }
        if ($idx -ge $t.Count) { $idx = $t.Count - 1 }
        return $t[$idx]
    }
    if ($df -lt 60) { return 2.021 + (2.000 - 2.021) * ($df - 40.0) / 20.0 }
    return 2.000 + (1.980 - 2.000) * ($df - 60.0) / 60.0
}

function Get-WelchTTest([double[]]$x, [double[]]$y) {
    $n1 = $x.Length
    $n2 = $y.Length
    if ($n1 -lt 2 -or $n2 -lt 2) { return $null }
    $m1 = ($x | Measure-Object -Average).Average
    $m2 = ($y | Measure-Object -Average).Average
    $v1 = Get-UnbiasedVariance $x
    $v2 = Get-UnbiasedVariance $y
    if ($null -eq $v1 -or $null -eq $v2) { return $null }
    $se = [math]::Sqrt($v1 / $n1 + $v2 / $n2)
    if ($se -lt 1e-15) { return $null }
    $t = ($m1 - $m2) / $se
    $vn1 = $v1 / $n1
    $vn2 = $v2 / $n2
    $df = [math]::Pow($vn1 + $vn2, 2) / ([math]::Pow($vn1, 2) / ($n1 - 1) + [math]::Pow($vn2, 2) / ($n2 - 1))
    return @{
        t_stat = [math]::Round($t, 4)
        df     = [math]::Round($df, 3)
        mean_enabled = [math]::Round($m1, 3)
        mean_baseline = [math]::Round($m2, 3)
        se     = [math]::Round($se, 4)
    }
}

function Get-PooledCohenD([double[]]$x, [double[]]$y, [string]$sense) {
    $n1 = $x.Length
    $n2 = $y.Length
    if ($n1 -lt 2 -or $n2 -lt 2) { return $null }
    $m1 = ($x | Measure-Object -Average).Average
    $m2 = ($y | Measure-Object -Average).Average
    $v1 = Get-UnbiasedVariance $x
    $v2 = Get-UnbiasedVariance $y
    if ($null -eq $v1 -or $null -eq $v2) { return $null }
    $sp2 = (($n1 - 1) * $v1 + ($n2 - 1) * $v2) / ($n1 + $n2 - 2)
    if ($sp2 -lt 1e-20) { return $null }
    $sp = [math]::Sqrt($sp2)
    $raw = ($m1 - $m2) / $sp
    $oriented = if ($sense -eq "higher_better") { $raw } else { -$raw }
    return @{
        d_raw = [math]::Round($raw, 4)
        d_oriented_positive_when_enabled_better = [math]::Round($oriented, 4)
        hedges_g = [math]::Round($raw * (1.0 - 3.0 / (4.0 * ($n1 + $n2) - 9.0)), 4)
    }
}

function Get-BootstrapMeanDiffCI([double[]]$e, [double[]]$b, [int]$bootCount) {
    $n1 = $e.Length
    $n2 = $b.Length
    if ($n1 -lt 2 -or $n2 -lt 2 -or $bootCount -lt 50) { return $null }
    $diffs = New-Object "System.Collections.Generic.List[double]"
    for ($k = 0; $k -lt $bootCount; $k++) {
        $s1 = 0.0
        for ($j = 0; $j -lt $n1; $j++) { $s1 += $e[(Get-Random -Minimum 0 -Maximum $n1)] }
        $s2 = 0.0
        for ($j = 0; $j -lt $n2; $j++) { $s2 += $b[(Get-Random -Minimum 0 -Maximum $n2)] }
        $diffs.Add(($s1 / $n1) - ($s2 / $n2))
    }
    $arr = $diffs.ToArray() | Sort-Object
    $loIdx = [int][math]::Floor(0.025 * ($arr.Length - 1))
    $hiIdx = [int][math]::Floor(0.975 * ($arr.Length - 1))
    if ($hiIdx -lt $loIdx) { $hiIdx = $loIdx }
    return @{
        lo = $arr[$loIdx]
        hi = $arr[$hiIdx]
    }
}

function Get-PairedWallDiffs($enabledRows, $baselineRows) {
    $n = [math]::Min($enabledRows.Count, $baselineRows.Count)
    if ($n -eq 0) { return $null }
    $d = New-Object "System.Collections.Generic.List[double]"
    for ($i = 0; $i -lt $n; $i++) {
        $we = $enabledRows[$i].wall_ms
        $wb = $baselineRows[$i].wall_ms
        if ($null -eq $we -or $null -eq $wb) { continue }
        $d.Add([double]$we - [double]$wb)
    }
    return $d.ToArray()
}

function Get-PairedTAndDz([double[]]$diffs) {
    $n = $diffs.Count
    if ($n -lt 2) { return $null }
    $mean = ($diffs | Measure-Object -Average).Average
    $sd = Get-SampleStdDev $diffs
    if ($null -eq $sd -or $sd -lt 1e-15) { return $null }
    $t = $mean / ($sd / [math]::Sqrt($n))
    $crit = Get-Tcrit975 ($n - 1)
    return @{
        mean_wall_diff_enabled_minus_baseline_ms = [math]::Round($mean, 3)
        sd_ms                                     = [math]::Round($sd, 3)
        cohens_dz                                 = [math]::Round($mean / $sd, 4)
        t_stat_paired                             = [math]::Round($t, 4)
        t_crit_975_df_n_minus_1                   = [math]::Round($crit, 4)
        significant_trend_at_05_two_sided         = [bool]([math]::Abs($t) -gt $crit)
    }
}

function Build-MetricBlock {
    param(
        [string]$Label,
        [double[]]$enabledVals,
        [double[]]$baselineVals,
        [string]$sense,
        [int]$bootB
    )
    if ($null -eq $enabledVals -or $null -eq $baselineVals) { return $null }
    if ($enabledVals.Length -eq 0 -or $baselineVals.Length -eq 0) { return $null }
    $w = Get-WelchTTest $enabledVals $baselineVals
    $co = Get-PooledCohenD $enabledVals $baselineVals $sense
    $bs = Get-BootstrapMeanDiffCI $enabledVals $baselineVals $bootB
    $m1 = ($enabledVals | Measure-Object -Average).Average
    $m2 = ($baselineVals | Measure-Object -Average).Average
    $welchSig = $false
    if ($null -ne $w -and $w.df -gt 0) {
        $tc = Get-Tcrit975 $w.df
        $welchSig = [bool]([math]::Abs($w.t_stat) -gt $tc)
    }
    $bci = $null
    if ($null -ne $bs) {
        $bci = @{
            enabled_minus_baseline_ms_lo = [math]::Round($bs.lo, 2)
            enabled_minus_baseline_ms_hi = [math]::Round($bs.hi, 2)
            crosses_zero                 = ($bs.lo -le 0 -and $bs.hi -ge 0)
        }
    }
    return [ordered]@{
        metric                             = $Label
        sense                              = $sense
        mean_enabled                       = [math]::Round($m1, 3)
        mean_baseline                      = [math]::Round($m2, 3)
        median_enabled                     = Get-Median $enabledVals
        median_baseline                    = Get-Median $baselineVals
        welch_t_enabled_minus_baseline     = $w
        cohen_d_pooled                     = $co
        bootstrap_mean_diff_ci95         = $bci
        welch_abs_t_exceeds_crit_alpha_05  = $welchSig
    }
}

function Build-FullAnalysis {
    param(
        [array]$enabledRows,
        [array]$baselineRows,
        [bool]$pairedInterleaved,
        [int]$bootB
    )

    $we = Get-DoubleArrayFromRows $enabledRows "wall_ms"
    $wb = Get-DoubleArrayFromRows $baselineRows "wall_ms"
    $te = Get-DoubleArrayFromRows $enabledRows "ttft_ms"
    $tb = Get-DoubleArrayFromRows $baselineRows "ttft_ms"
    $pe = Get-DoubleArrayFromRows $enabledRows "tpot_ms"
    $pb = Get-DoubleArrayFromRows $baselineRows "tpot_ms"
    $se = Get-DoubleArrayFromRows $enabledRows "status_tps"
    $sb = Get-DoubleArrayFromRows $baselineRows "status_tps"

    $blocks = @(
        (Build-MetricBlock "wall_ms" $we $wb "lower_better" $bootB),
        (Build-MetricBlock "ttft_ms" $te $tb "lower_better" $bootB),
        (Build-MetricBlock "tpot_ms" $pe $pb "lower_better" $bootB),
        (Build-MetricBlock "status_tps" $se $sb "higher_better" $bootB)
    )

    $pdiffs = Get-PairedWallDiffs $enabledRows $baselineRows
    $paired = $null
    if ($pairedInterleaved -and $null -ne $pdiffs -and $pdiffs.Count -ge 2) {
        $paired = Get-PairedTAndDz $pdiffs
    }

    $interpretation = @(
        "Welch t: unequal-variance two-sample test on means (enabled vs baseline rows). With block sampling, runs are not i.i.d. paired by epoch—use -PairedInterleaved for fair paired wall deltas.",
        "Bootstrap CI: BCa-style not used; percentile CI on bootstrap distribution of mean(enabled wall)-mean(baseline wall) from independent group resampling.",
        "Cohen d (pooled): small-sample Hedges correction included in hedges_g; d_oriented_positive_when_enabled_better>0 means enabled wins on that metric."
    )

    return [ordered]@{
        schema_version      = 1
        paired_interleaved  = [bool]$pairedInterleaved
        bootstrap_samples   = $bootB
        per_metric          = ($blocks | Where-Object { $null -ne $_ })
        paired_wall_ms      = $paired
        notes               = $interpretation
    }
}

Write-Host "Checking API health at ${ApiBase}/v1/health ..."
$health = $null
$apiWaitSw = [System.Diagnostics.Stopwatch]::StartNew()
while ($true) {
    try {
        $health = Invoke-ApiJson -Path "/v1/health" -Method "GET" -TimeoutSec 20
        break
    } catch {
        $elapsed = [int]$apiWaitSw.Elapsed.TotalSeconds
        if ($WaitForApiSec -le 0 -or $elapsed -ge $WaitForApiSec) {
            Write-Host ""
            Write-Host "Cannot reach the AcouLM HTTP API at: ${ApiBase}/v1/health" -ForegroundColor Red
            Write-Host "  This script only drives an already-running API (it does not start the server)." -ForegroundColor Yellow
            Write-Host "  Start the stack first, for example:  .\start_app.ps1" -ForegroundColor Yellow
            Write-Host "  Then re-run this script, or wait for startup with:  -WaitForApiSec 120" -ForegroundColor Yellow
            Write-Host "  If your API uses another URL, pass:  -ApiBase 'http://127.0.0.1:PORT'" -ForegroundColor Yellow
            Write-Host ""
            if ($WaitForApiSec -gt 0) {
                throw "Timed out after ${WaitForApiSec}s waiting for API: $($_.Exception.Message)"
            }
            throw "API unreachable: $($_.Exception.Message)"
        }
        Write-Host "  API not ready yet (${elapsed}s / ${WaitForApiSec}s); retrying in 2s..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 2
    }
}
Write-Host ("Health: " + ($health | ConvertTo-Json -Compress))

$prompt = "Write five concise bullet points about why local LLM inference can improve privacy."

if ($PairedInterleaved) {
    $pairResult = Run-PairedInterleaved -Prompt $prompt
    $enabledRows = $pairResult.enabledRows
    $baselineRows = $pairResult.baselineRows
} else {
    $enabledRows = Run-Scenario -Name "acoulm_enabled" -SplitPrefill $true -ContextRouting $true -Prompt $prompt
    $baselineRows = Run-Scenario -Name "baseline_single_path" -SplitPrefill $false -ContextRouting $false -Prompt $prompt
}

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
    $wallArr = Get-DoubleArrayFromRows $rows "wall_ms"
    return [pscustomobject]@{
        scenario              = $name
        runs                  = $rows.Count
        avg_wall_ms           = Get-Avg $rows "wall_ms"
        median_wall_ms        = if ($wallArr.Length) { Get-Median $wallArr } else { $null }
        avg_ttft_ms           = Get-Avg $rows "ttft_ms"
        avg_tpot_ms           = Get-Avg $rows "tpot_ms"
        avg_status_tps        = Get-Avg $rows "status_tps"
        avg_calc_tokens_s     = Get-Avg $rows "calc_tokens_per_s"
        avg_gpu_peak_mb       = Get-Avg $rows "gpu_mem_peak_mb"
        avg_total_ms_metric   = Get-Avg $rows "total_ms_metrics"
    }
}

$enabledSummary = Summarize -rows $enabledRows -name "acoulm_enabled"
$baselineSummary = Summarize -rows $baselineRows -name "baseline_single_path"

$analysis = Build-FullAnalysis -enabledRows $enabledRows -baselineRows $baselineRows -pairedInterleaved ([bool]$PairedInterleaved) -bootB $BootstrapSamples

$outDir = Join-Path $PSScriptRoot "benchmark_outputs"
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -Path $outDir -ItemType Directory | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$rowsPath = Join-Path $outDir "bench_rows_$timestamp.json"
$summaryPath = Join-Path $outDir "bench_summary_$timestamp.json"
$analysisPath = Join-Path $outDir "bench_analysis_$timestamp.json"
$allRows | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $rowsPath -Encoding UTF8
@($enabledSummary, $baselineSummary) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
$analysis | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $analysisPath -Encoding UTF8

Write-Host ""
Write-Host "=== Benchmark Summary ===" -ForegroundColor Green
@($enabledSummary, $baselineSummary) | Format-Table -AutoSize | Out-String | Write-Host

$wallBlock = $analysis.per_metric | Where-Object { $_.metric -eq "wall_ms" } | Select-Object -First 1
if ($null -ne $wallBlock -and $null -ne $wallBlock.bootstrap_mean_diff_ci95) {
    Write-Host ""
    Write-Host "=== wall_ms interpretation ===" -ForegroundColor Yellow
    Write-Host ("Bootstrap 95% CI for mean(enabled)-mean(baseline) ms: [{0}, {1}] (crosses zero: {2})" -f `
            $wallBlock.bootstrap_mean_diff_ci95.enabled_minus_baseline_ms_lo,
        $wallBlock.bootstrap_mean_diff_ci95.enabled_minus_baseline_ms_hi,
        $wallBlock.bootstrap_mean_diff_ci95.crosses_zero)
    if ($null -ne $wallBlock.cohen_d_pooled) {
        Write-Host ("Cohen d (oriented, + when enabled better on latency): {0} (|d| under ~0.2 is often 'negligible')" -f $wallBlock.cohen_d_pooled.d_oriented_positive_when_enabled_better)
    }
}
if ($null -ne $analysis.paired_wall_ms) {
    Write-Host ""
    Write-Host "=== Paired wall_ms (same run index) ===" -ForegroundColor Yellow
    $analysis.paired_wall_ms | ConvertTo-Json -Compress | Write-Host
}

Write-Host ""
Write-Host "Rows JSON: $rowsPath"
Write-Host "Summary JSON: $summaryPath"
Write-Host "Analysis JSON: $analysisPath"
