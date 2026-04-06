#requires -Version 5.0
param(
    [string]$ApiBase = "http://localhost:8000",
    [string]$Model = "openvino",
    [string]$ReportDir = "./runlogs/cutover"
)

$ErrorActionPreference = "Stop"

$script:Passed = 0
$script:Failed = 0
$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Name,
        [bool]$Pass,
        [string]$Message
    )

    $entry = [pscustomobject]@{
        name = $Name
        pass = $Pass
        message = $Message
        timestamp = (Get-Date).ToString("o")
    }

    $results.Add($entry)
    if ($Pass) {
        Write-Host "PASS: $Name" -ForegroundColor Green
        $script:Passed++
    } else {
        Write-Host "FAIL: $Name -- $Message" -ForegroundColor Red
        $script:Failed++
    }
}

function Invoke-ApiJson {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [object]$Body = $null,
        [int]$TimeoutSec = 120
    )

    $params = @{
        Uri         = "$ApiBase$Endpoint"
        Method      = $Method
        TimeoutSec  = $TimeoutSec
        ErrorAction = "Stop"
    }

    if ($null -ne $Body) {
        $params.ContentType = "application/json"
        $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }

    Invoke-RestMethod @params
}

function Invoke-ApiRaw {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [object]$Body = $null,
        [int]$TimeoutSec = 120
    )

    $request = [System.Net.HttpWebRequest]::Create("$ApiBase$Endpoint")
    $request.Method = $Method
    $request.Timeout = $TimeoutSec * 1000
    $request.ReadWriteTimeout = $TimeoutSec * 1000

    if ($null -ne $Body) {
        $jsonBody = $Body | ConvertTo-Json -Depth 10 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
        $request.ContentType = "application/json"
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try {
            $stream.Write($bytes, 0, $bytes.Length)
        } finally {
            $stream.Dispose()
        }
    }

    $response = $request.GetResponse()
    try {
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        try {
            $content = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }

        [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Content = $content
        }
    } finally {
        $response.Dispose()
    }
}

function Invoke-Check {
    param(
        [string]$Name,
        [scriptblock]$Body
    )

    try {
        & $Body
        Add-Result -Name $Name -Pass $true -Message "ok"
    } catch {
        Add-Result -Name $Name -Pass $false -Message $_.Exception.Message
    }
}

Write-Host "Running daily cutover checks against $ApiBase" -ForegroundColor Cyan

$statusSnapshot = $null
Invoke-Check -Name "GET /v1/health" -Body {
    $health = Invoke-ApiJson -Endpoint "/v1/health" -TimeoutSec 20
    if ($health.status -ne "healthy") { throw "unexpected status: $($health.status)" }
}

Invoke-Check -Name "GET /v1/cli/status" -Body {
    $script:statusSnapshot = Invoke-ApiJson -Endpoint "/v1/cli/status" -TimeoutSec 20
    if ([string]::IsNullOrWhiteSpace([string]$script:statusSnapshot.active_device)) {
        throw "active_device missing"
    }
}

Invoke-Check -Name "POST /v1/cli/feature/json idempotent" -Body {
    if ($null -eq $script:statusSnapshot) { throw "status snapshot missing" }
    $enabled = ([string]$script:statusSnapshot.json_output).ToUpper() -eq "ON"
    $resp = Invoke-ApiJson -Endpoint "/v1/cli/feature/json" -Method "POST" -Body @{ enabled = $enabled } -TimeoutSec 20
    if (-not $resp.success) { throw "toggle did not report success" }
}

Invoke-Check -Name "POST /v1/chat/completions non-stream" -Body {
    $body = @{
        model = $Model
        stream = $false
        temperature = 0.1
        max_tokens = 24
        messages = @(
            @{ role = "user"; content = "Return exactly: daily_cutover_ok" }
        )
    }
    $resp = Invoke-ApiJson -Endpoint "/v1/chat/completions" -Method "POST" -Body $body -TimeoutSec 180
    if ($resp.object -ne "chat.completion") { throw "unexpected object: $($resp.object)" }
    $content = [string]$resp.choices[0].message.content
    if ([string]::IsNullOrWhiteSpace($content)) { throw "empty completion" }
}

Invoke-Check -Name "POST /v1/chat/completions stream" -Body {
    $body = @{
        model = $Model
        stream = $true
        temperature = 0.1
        max_tokens = 24
        messages = @(
            @{ role = "user"; content = "Return exactly: daily_cutover_stream_ok" }
        )
    }
    $resp = Invoke-ApiRaw -Endpoint "/v1/chat/completions" -Method "POST" -Body $body -TimeoutSec 180
    $content = [string]$resp.Content
    if (-not $content.Contains("data: [DONE]")) { throw "missing [DONE] marker" }
    if (-not $content.Contains('"object":"chat.completion.chunk"')) { throw "missing chunk object" }
}

if (-not (Test-Path $ReportDir)) {
    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportPath = Join-Path $ReportDir "daily_check_$stamp.json"
$report = [pscustomobject]@{
    timestamp = (Get-Date).ToString("o")
    api_base = $ApiBase
    passed = $script:Passed
    failed = $script:Failed
    checks = $results
}

$report | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $reportPath

Write-Host ""
Write-Host "Daily cutover summary: Passed=$script:Passed Failed=$script:Failed" -ForegroundColor Cyan
Write-Host "Report written: $reportPath" -ForegroundColor Cyan

if ($script:Failed -gt 0) {
    exit 1
}
exit 0
