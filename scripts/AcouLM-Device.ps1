# Host GPU tier hints for AcouLM launchers (integrated vs discrete).

function Get-AcouLMGpuTier {
    $forced = [string]$env:ACOULM_GPU_TIER
    if ($forced -match '^(weak|integrated|discrete|none|unknown)$') {
        return $forced
    }
    if ($env:ACOULM_FORCE_GPU -eq "1") {
        return "discrete"
    }
    try {
        $controllers = @(
            Get-CimInstance Win32_VideoController -ErrorAction Stop |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) }
        )
        $discrete = $false
        $integrated = $false
        foreach ($c in $controllers) {
            $n = [string]$c.Name
            if ($n -match 'Microsoft Basic|Remote Desktop|Virtual|VMware|Parsec|Hyper-V') {
                continue
            }
            if ($n -match 'NVIDIA|GeForce|RTX|Quadro|Tesla|Radeon RX|Intel\(R\) Arc|AMD Radeon RX') {
                $discrete = $true
            }
            if ($n -match 'Intel.*(UHD|Iris|HD Graphics)|AMD Radeon\(TM\) Graphics|Radeon Vega|Radeon\(TM\) Vega') {
                $integrated = $true
            }
        }
        if ($discrete) { return "discrete" }
        if ($integrated) { return "weak" }
        if ($controllers.Count -gt 0) { return "unknown" }
    } catch {}
    return "none"
}

function Initialize-AcouLMDeviceEnvironment {
    $tier = Get-AcouLMGpuTier
    if ($tier -ne "unknown") {
        $env:ACOULM_GPU_TIER = $tier
    }
    if ($tier -eq "weak" -or $tier -eq "integrated") {
        Write-Host "[AcouLM] Low-end / integrated GPU detected. CPU is often similar speed on 3B GGUF; fastest wins: OpenVINO IR export or a smaller model." -ForegroundColor DarkYellow
        if ($env:ACOULM_DEVICE -ne "GPU" -and $env:ACOULM_FORCE_GPU -ne "1") {
            # Do not override device — only inform. NPU (if present) is tried by the backend scheduler.
        }
    }
}
