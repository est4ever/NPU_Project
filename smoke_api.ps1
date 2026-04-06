#requires -Version 5.0
param(
    [string]$ApiBase = "http://localhost:8000",
    [string]$Model = "openvino"
)

$ErrorActionPreference = "Stop"

$script:Passed = 0
$script:Failed = 0

function Write-Pass {
    param([string]$Name)
    Write-Host "PASS: $Name" -ForegroundColor Green
    $script:Passed++
}

function Write-Fail {
    param([string]$Name, [string]$Message)
    Write-Host "FAIL: $Name -- $Message" -ForegroundColor Red
    $script:Failed++
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-Test {
    param(
        [string]$Name,
        [scriptblock]$Body
    )

    try {
        & $Body
        Write-Pass $Name
    } catch {
        Write-Fail $Name "$($_.Exception.Message)"
    }
}

function Invoke-ApiJson {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [object]$Body = $null,
        [int]$TimeoutSec = 60
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

    return Invoke-RestMethod @params
}

function Invoke-ApiRaw {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [object]$Body = $null,
        [int]$TimeoutSec = 60
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

        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Content    = $content
        }
    } finally {
        $response.Dispose()
    }
}

Write-Host "Running smoke tests against $ApiBase" -ForegroundColor Cyan

$statusSnapshot = $null
Invoke-Test -Name "GET /v1/cli/status snapshot" -Body {
    $script:statusSnapshot = Invoke-ApiJson -Endpoint "/v1/cli/status"
    Assert-True ($script:statusSnapshot -ne $null) "status response is null"
    Assert-True (-not [string]::IsNullOrWhiteSpace($script:statusSnapshot.active_device)) "active_device missing"
    Assert-True (-not [string]::IsNullOrWhiteSpace($script:statusSnapshot.policy)) "policy missing"
}

Invoke-Test -Name "GET /v1/health" -Body {
    $health = Invoke-ApiJson -Endpoint "/v1/health"
    Assert-True ($health.status -eq "healthy") "unexpected health status: $($health.status)"
    Assert-True (-not [string]::IsNullOrWhiteSpace($health.backend)) "backend missing"
}

Invoke-Test -Name "POST /v1/cli/policy (idempotent)" -Body {
    Assert-True ($script:statusSnapshot -ne $null) "status snapshot not available"
    $policy = [string]$script:statusSnapshot.policy
    $resp = Invoke-ApiJson -Endpoint "/v1/cli/policy" -Method "POST" -Body @{ policy = $policy }
    Assert-True ($resp.success -eq $true) "policy update did not report success"
    Assert-True ($resp.new_policy -eq $policy) "new_policy mismatch"
}

Invoke-Test -Name "POST /v1/cli/device/switch (idempotent)" -Body {
    Assert-True ($script:statusSnapshot -ne $null) "status snapshot not available"
    $device = [string]$script:statusSnapshot.active_device
    $resp = Invoke-ApiJson -Endpoint "/v1/cli/device/switch" -Method "POST" -Body @{ device = $device }
    Assert-True ($resp.success -eq $true) "device switch did not report success"
    Assert-True ($resp.new_active_device -eq $device) "new_active_device mismatch"
}

Invoke-Test -Name "POST /v1/cli/feature/json (idempotent)" -Body {
    Assert-True ($script:statusSnapshot -ne $null) "status snapshot not available"
    $enabled = ([string]$script:statusSnapshot.json_output).ToUpper() -eq "ON"
    $resp = Invoke-ApiJson -Endpoint "/v1/cli/feature/json" -Method "POST" -Body @{ enabled = $enabled }
    Assert-True ($resp.success -eq $true) "feature toggle did not report success"
    Assert-True ($resp.feature -eq "json") "feature name mismatch"
}

$modelSnapshot = $null
Invoke-Test -Name "GET /v1/cli/model/list snapshot" -Body {
    $script:modelSnapshot = Invoke-ApiJson -Endpoint "/v1/cli/model/list"
    Assert-True ($script:modelSnapshot -ne $null) "model list response is null"
    Assert-True (-not [string]::IsNullOrWhiteSpace($script:modelSnapshot.selected_model)) "selected_model missing"
    Assert-True ($script:modelSnapshot.models.Count -ge 1) "models list is empty"
}

Invoke-Test -Name "POST /v1/cli/model/select (idempotent)" -Body {
    Assert-True ($script:modelSnapshot -ne $null) "model snapshot not available"
    $modelId = [string]$script:modelSnapshot.selected_model
    $resp = Invoke-ApiJson -Endpoint "/v1/cli/model/select" -Method "POST" -Body @{ id = $modelId }
    Assert-True ($resp.success -eq $true) "model select did not report success"
    Assert-True ($resp.selected_model -eq $modelId) "selected_model mismatch"
}

$backendSnapshot = $null
Invoke-Test -Name "GET /v1/cli/backend/list snapshot" -Body {
    $script:backendSnapshot = Invoke-ApiJson -Endpoint "/v1/cli/backend/list"
    Assert-True ($script:backendSnapshot -ne $null) "backend list response is null"
    Assert-True (-not [string]::IsNullOrWhiteSpace($script:backendSnapshot.selected_backend)) "selected_backend missing"
    Assert-True ($script:backendSnapshot.backends.Count -ge 1) "backends list is empty"
}

Invoke-Test -Name "POST /v1/cli/backend/select (idempotent)" -Body {
    Assert-True ($script:backendSnapshot -ne $null) "backend snapshot not available"
    $backendId = [string]$script:backendSnapshot.selected_backend
    $resp = Invoke-ApiJson -Endpoint "/v1/cli/backend/select" -Method "POST" -Body @{ id = $backendId }
    Assert-True ($resp.success -eq $true) "backend select did not report success"
    Assert-True ($resp.selected_backend -eq $backendId) "selected_backend mismatch"
}

Invoke-Test -Name "POST /v1/chat/completions (non-stream)" -Body {
    $body = @{
        model = $Model
        stream = $false
        temperature = 0.1
        max_tokens = 24
        messages = @(
            @{ role = "user"; content = "Return exactly: smoke_ok" }
        )
    }
    $resp = Invoke-ApiJson -Endpoint "/v1/chat/completions" -Method "POST" -Body $body -TimeoutSec 180
    Assert-True ($resp.object -eq "chat.completion") "unexpected object: $($resp.object)"
    $content = [string]$resp.choices[0].message.content
    Assert-True (-not [string]::IsNullOrWhiteSpace($content)) "empty completion content"
}

Invoke-Test -Name "POST /v1/chat/completions (stream SSE + DONE)" -Body {
    $body = @{
        model = $Model
        stream = $true
        temperature = 0.1
        max_tokens = 24
        messages = @(
            @{ role = "user"; content = "Return exactly: smoke_stream_ok" }
        )
    }

    $resp = Invoke-ApiRaw -Endpoint "/v1/chat/completions" -Method "POST" -Body $body -TimeoutSec 180
    $content = [string]$resp.Content
    Assert-True ($content.Contains("data: [DONE]")) "SSE payload missing [DONE] marker"
    Assert-True ($content.Contains('"object":"chat.completion.chunk"')) "SSE payload missing chunk objects"
}

Write-Host ""
Write-Host "Smoke test summary: Passed=$script:Passed Failed=$script:Failed" -ForegroundColor Cyan
if ($script:Failed -gt 0) {
    exit 1
}
exit 0
