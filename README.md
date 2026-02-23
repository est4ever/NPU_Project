# NPU_Project — OpenVINO GenAI LLM C++ Wrapper (Windows)

A minimal C++ CLI wrapper that runs **OpenVINO GenAI LLMs** (OpenVINO-exported models) with device selection (CPU / GPU / NPU) and automatic fallback.

> **Important:** This repo does **not** ship models. You export/download models locally into `models/`.

## What This Project Does

- Loads OpenVINO GenAI LLMs from folders like `./models/Qwen2.5-0.5B-Instruct`
- **Scheduler-based device selection** with three policies: BATTERY_SAVER (NPU-first), PERFORMANCE (GPU-first), BALANCED (AUTO heterogeneous)
- **Multi-device execution mode** (`--benchmark`): Runs 2-second benchmarks on all devices, loads model on all of them, and allows runtime switching
- Auto-detects available hardware and applies policy-based routing
- Interactive terminal-based prompting with automatic fallback on device errors
- Real-time benchmarking: shows execution time after each generation
- `stats` command prints OpenVINO GenAI performance metrics (TTFT, TPOT, throughput)
- Clean backend interface (`IBackend.h`) and scheduler interface (`IScheduler.h`) with OpenVINO implementations
- Auto-cleanup: deletes log files on successful exit (keeps them on errors for debugging)

---

## System Requirements

| Component | Version | Purpose |
|---|---|---|
| **OS** | Windows 10/11 | Required |
| **Visual Studio Build Tools** | 2022 (MSVC) | C++ compiler |
| **CMake** | 3.18+ | Build system |
| **OpenVINO GenAI** | 2025.4.0.0 | Model inference engine |
| **Python** | 3.10+ | Model conversion (optional) |
| **C++ Standard** | C++17 | Code requirement |

---

## One-Time Setup (Fresh Computer)

### Step 1: Download & Install Prerequisites

#### A. Visual Studio Build Tools 2022
1. Download from [visualstudio.microsoft.com](https://visualstudio.microsoft.com/downloads/)
2. Run installer and select **"Desktop development with C++"**
3. Complete installation

#### B. CMake 3.18+
1. Download from [cmake.org](https://cmake.org/download/)
2. Run installer
3. **Important:** Check "Add CMake to system PATH"

#### C. OpenVINO GenAI (2025.4.0.0) - Archive Installation

**Important:** You need the **Archive Installation** (C++ runtime), not just the PyPI package.

**⚠️ Critical: Download the correct version (2025.4.0.0)**

The OpenVINO documentation may show curl/wget commands for **different versions** (like 2024.6.0.0). **DO NOT use those commands directly** as they will download the wrong version.

**Correct Download Method:**

1. Go to [OpenVINO GenAI GitHub Releases](https://github.com/openvinotoolkit/openvino.genai/releases)
2. Find **Release 2025.4.0.0**
3. Download: `openvino_genai_windows_2025.4.0.0_x86_64.zip`
4. Extract to: `C:\Users\<YourUsername>\Downloads\openvino_genai_windows_2025.4.0.0_x86_64\`
5. **Verify:** The extracted folder should contain:
   - `setupvars.bat` (at the root)
   - `runtime/bin/intel64/Release/` (DLLs)
   - `runtime/cmake/` (CMake config files)

**⚠️ Common Mistakes:**
- **DON'T** run `pip install openvino-genai` - that only installs Python bindings
- **DON'T** copy curl commands from documentation - they may download the wrong version
- You **NEED** the full archive with C++ runtime and `setupvars.bat` for this project

#### D. Python 3.10+ (for model conversion only)

**Note:** Python is optional - only needed if you want to convert models yourself.

1. Download from [python.org](https://www.python.org/downloads/)
2. **Important:** Check "Add Python to PATH"
3. Later you'll run `pip install openvino-genai optimum[openvino]` for model conversion tools

### Step 2: Copy Project Files

Copy these from your source machine:
```
NPU_Project/
├── CMakeLists.txt
├── build.ps1              ← Build automation script
├── README.md
├── src/
│   └── main.cpp
└── .gitignore
```

**Do NOT copy:**
- `build/` → Auto-generated during compilation
- `dist/` → Auto-generated after build
- `runlog.txt` → Auto-deleted after successful runs
- `venv/` → Python virtual environment (recreate on new machine)
- Model folders → Download separately

### Step 3: Create Directories

```powershell
cd C:\Users\<YourUsername>\NPU_Project

mkdir build
mkdir dist
mkdir models
```

### Step 4: Set Up Python Virtual Environment

```powershell
# Create virtual environment
python -m venv venv

# Activate it
.\venv\Scripts\Activate.ps1

# Install model conversion tools
pip install optimum[openvino] torch transformers
```

### Step 5: Update OpenVINO Path in CMakeLists.txt

Edit `CMakeLists.txt` lines 13-14 and replace `ser13` with your Windows username:
```cmake
set(OpenVINO_DIR "C:/Users/<YourUsername>/Downloads/openvino_genai_windows_2025.4.0.0_x86_64/runtime/cmake")
set(OpenVINOGenAI_DIR "C:/Users/<YourUsername>/Downloads/openvino_genai_windows_2025.4.0.0_x86_64/runtime/cmake")
```

**Important:** Use forward slashes `/` not backslashes `\` in CMakeLists.txt.

The `build.ps1` script already uses `$env:USERNAME` so it will work on any machine automatically.

---

## Getting Models

### Option A: Download Models

**Qwen2.5-0.5B-Instruct (recommended for testing)**
- ~0.5B parameters, extremely fast
- Download from: [Qwen/Qwen2.5-0.5B-Instruct](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct)
- Or download pre-converted OpenVINO version if available
- Place in: `models/Qwen2.5-0.5B-Instruct/`

**TinyLlama (alternative)**
- ~1.1B parameters, very fast
- Download from Hugging Face: [TinyLlama-1.1B-Chat-v1.0](https://huggingface.co/TinyLlama/TinyLlama-1.1B-Chat-v1.0)
- Place in: `models/TinyLlama_ov/`

### Option B: Convert Models Yourself

#### From Hugging Face

```powershell
# Activate venv first
.\venv\Scripts\Activate.ps1

# Example: Convert TinyLlama
optimum-cli export openvino `
  --model "TinyLlama/TinyLlama-1.1B-Chat-v1.0" `
  --task text-generation-with-past `
  "./models/TinyLlama_ov"

# Example: Convert Mistral 7B
optimum-cli export openvino `
  --model "mistralai/Mistral-7B-Instruct-v0.2" `
  --task text-generation-with-past `
  "./models/Mistral_7B_ov"
```

#### From Local GGUF File

```powershell
# Install converter
pip install openvino-genai

# Convert your GGUF file
ovc --input_model model.gguf -o ./models/my_model_ov/
```

---

## How to Build and Run

### First Time Setup

```powershell
cd C:\Users\<YourUsername>\NPU_Project

# Build the project (this also sets up OpenVINO environment)
.\build.ps1 -Clean
```

The build script will:
1. Load OpenVINO environment variables
2. Create the `build/` directory
3. Configure CMake with Visual Studio 2022
4. Compile in Release mode
5. Copy executable and all DLLs to `dist/`

### Running the Model

**Single-Device Mode (default):**
```powershell
# Run with default policy (BATTERY_SAVER = prioritize NPU)
.\dist\npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct

# Run with specific policy
.\dist\npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --policy PERFORMANCE    # GPU preferred
.\dist\npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --policy BATTERY_SAVER  # NPU preferred
.\dist\npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --policy BALANCED       # AUTO heterogeneous

# Force device selection (overrides policy)
.\dist\npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --device NPU
.\dist\npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --device CPU
.\dist\npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --device GPU
```

**Multi-Device Benchmark Mode:**
```powershell
# Run benchmarks and load on all devices (CPU, GPU, NPU)
.\dist\npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --benchmark

# Benchmark with specific policy for device selection
.\dist\npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --benchmark --policy PERFORMANCE
```

In benchmark mode:
- Runs a 2-second test on each available device (CPU, GPU, NPU)
- Loads the model on **all** tested devices simultaneously
- Selects the best device based on measured TTFT and throughput
- Allows runtime device switching with the `switch [device]` command

### Device Scheduling Policies

The scheduler uses **EnginePolicy** to intelligently select hardware:

| Policy | Behavior | Best For |
|---|---|---|
| **BATTERY_SAVER** (default) | NPU preferred, fallback CPU | Battery-powered devices, power efficiency |
| **PERFORMANCE** | GPU preferred, fallback CPU | High-speed inference, low latency |
| **BALANCED** | AUTO heterogeneous GPU→NPU→CPU | Mixed workloads with diverse hardware |

The `--device` flag **overrides** policy selection if provided.

### Automatic Device Switching (Multi-Device Mode)

When running with `--benchmark`, the system enables **automatic device switching** by default. After each generation, it monitors performance and switches devices if:

**Trigger conditions:**
- **TTFT degradation**: Current TTFT exceeds benchmark by 50% or more
- **Throughput drop**: Current throughput falls below 70% of benchmark
- **Better alternative**: Another device is at least 20% faster

**Example scenario:**
```
You start on NPU (best for battery)
  ↓
User enters a very long prompt
  ↓
NPU struggles → TTFT: 892ms (benchmark was 189ms)
  ↓
System detects: "TTFT degraded by 370%"
  ↓
Checks GPU: benchmark shows 156ms TTFT, ~79 tok/s
  ↓
Switches to GPU automatically
  ↓
Next prompts stay on GPU until performance improves
```

**Manual control:**
- Type `auto` to toggle automatic switching on/off
- Type `switch [device]` to manually select a device
- Prompt shows `AUTO` indicator when auto-switching is enabled: `You [GPU AUTO]:`

### Expected Output

**Single-Device Mode:**
```
MAIN STARTED
Model dir: ./models/Qwen2.5-0.5B-Instruct
Policy: BATTERY_SAVER

[Scheduler] Hardware Discovered:
  - CPU : Intel(R) Core(TM) i7-13700K
  - GPU : Intel(R) Arc(TM) A770M
  - NPU : Intel(R) AI Boost NPU

[Scheduler] Applying routing policy...
[Scheduler] Policy: BATTERY SAVER. Routing to NPU.
Device chosen: NPU

[Backend] Loading model from: ./models/Qwen2.5-0.5B-Instruct to NPU...
[Backend] Model loaded successfully.

READY. Type prompt (exit to quit)

You: What is 2+2?
Assistant: 2 + 2 equals 4.
[Time: 1.234 seconds]

You: stats
--- Hardware Performance Stats ---
Time To First Token (TTFT): 45.32 ms
Time Per Output Token (TPOT): 12.15 ms/token
Throughput: 82.35 tokens/s
----------------------------------

You: exit
```

**Multi-Device Benchmark Mode:**
```
MAIN STARTED
Model dir: ./models/Qwen2.5-0.5B-Instruct
Policy: BATTERY_SAVER

[Scheduler] Hardware Discovered:
  - CPU : Intel(R) Core(TM) i7-13700K
  - GPU : Intel(R) Arc(TM) A770M
  - NPU : Intel(R) AI Boost NPU

[MULTI-DEVICE MODE ENABLED]

[Scheduler] Starting device benchmarks (2 sec per device)...
[Scheduler] Testing CPU... ✓ TTFT: 234.5 ms, Throughput: 45.2 tok/s
[Scheduler] Testing GPU... ✓ TTFT: 156.3 ms, Throughput: 78.9 tok/s
[Scheduler] Testing NPU... ✓ TTFT: 189.7 ms, Throughput: 62.4 tok/s
[Scheduler] Benchmarking complete.

[Scheduler] Selecting best device based on benchmarks and policy...
  - CPU: score = 45.2
  - GPU: score = 39.45
  - NPU: score = 1000062.4
[Scheduler] Selected: NPU (score: 1000062.4)

[BackendPool] Loading model on 3 device(s)...
[Backend] Loading model from: ./models/Qwen2.5-0.5B-Instruct to CPU...
[Backend] Model loaded successfully.
[Backend] Loading model from: ./models/Qwen2.5-0.5B-Instruct to GPU...
[Backend] Model loaded successfully.
[Backend] Loading model from: ./models/Qwen2.5-0.5B-Instruct to NPU...
[Backend] Model loaded successfully.
[BackendPool] Successfully loaded on 3 device(s)

READY. Type prompt (exit to quit, stats/devices/auto/switch [device])

You [NPU AUTO]: What is 2+2?
Assistant: 2 + 2 equals 4.
[Device: NPU, Time: 1.234 seconds]

You [NPU AUTO]: Tell me a long story about space exploration.
Assistant: [generates long response]
[Auto-Switch] TTFT degraded: 892.5 ms vs benchmark 189.7 ms
[Auto-Switch] Switching from NPU to GPU (expected +26.5% throughput)
[BackendPool] Switched to device: GPU
[Device: GPU, Time: 8.456 seconds]

You [GPU AUTO]: What is 5+5?
Assistant: 5 + 5 equals 10.
[Device: GPU, Time: 0.987 seconds]

You [GPU AUTO]: auto
[Auto-switching DISABLED]

You [GPU]: switch NPU
[BackendPool] Switched to device: NPU

You [NPU]: devices
Loaded devices:
  - CPU
  - GPU
  - NPU (active)

You [NPU]: stats
[Device: NPU]
--- Hardware Performance Stats ---
Time To First Token (TTFT): 45.32 ms
Time Per Output Token (TPOT): 12.15 ms/token
Throughput: 82.35 tokens/s
----------------------------------

You [NPU]: auto
[Auto-switching ENABLED]

You [NPU AUTO]: exit
```

**Features:**
1. Device discovery and intelligent scheduling based on policy
2. Multi-device mode: benchmark all devices, load on all
3. **Automatic device switching**: Monitors performance after each generation and switches if current device underperforms
4. Auto-switching triggers when:
   - TTFT exceeds benchmark by 50% or more
   - Throughput drops below 70% of benchmark
   - Alternative device is at least 20% faster
5. Shows execution time after each response: `[Time: X.XXX seconds]`
6. `stats` prints OpenVINO GenAI TTFT/TPOT/throughput metrics
7. `switch [device]` manually changes active device
8. `devices` lists all loaded devices
9. `auto` toggles automatic device switching on/off (enabled by default)
10. Auto-deletes `runlog.txt` on successful exit
11. Keeps `runlog.txt` if there's an error (for debugging)

---

## Important: Environment Variables & setupvars.bat

**The Problem:**
OpenVINO requires environment variables (PATH, OPENVINO_DIR, etc.) to be set before the executable runs. These are configured by running `setupvars.bat`.

**Why this is tricky in PowerShell:**
When you run `cmd /c "setupvars.bat"` from PowerShell:
1. PowerShell spawns a **new cmd.exe process**
2. `setupvars.bat` sets environment variables **inside that cmd process only**
3. When cmd.exe exits, **all those environment variables are lost**
4. Your PowerShell session never receives them

**How build.ps1 solves this:**
The script uses a clever workaround:
```powershell
# Capture environment variables from setupvars.bat
$envOutput = cmd /c "call `"$OV\setupvars.bat`" > nul && set"

# Import each variable into current PowerShell session
foreach ($line in $envOutput) {
    $idx = $line.IndexOf('=')
    if ($idx -gt 0) {
        $name = $line.Substring(0, $idx)
        $value = $line.Substring($idx + 1)
        Set-Item -Path "Env:$name" -Value $value
    }
}
```

This runs `setupvars.bat` in cmd, captures the resulting environment variables with `set`, then imports them into your PowerShell session where they **persist** for future commands.

**Result:** After running `.\build.ps1`, your PowerShell session has all OpenVINO environment variables set, so the executable runs without issues.

---

## Rebuilding After Code Changes

### Using the Automated Script (Recommended)

The `build.ps1` script handles everything automatically:

```powershell
# Normal rebuild (incremental)
.\build.ps1

# Clean rebuild (deletes build folder first)
.\build.ps1 -Clean
```

**What build.ps1 does:**
1. Loads OpenVINO environment variables from `setupvars.bat` into your PowerShell session
2. Cleans build directory if `-Clean` flag is used
3. Runs CMake configuration with proper paths
4. Builds in Release mode
5. Automatically copies:
   - `npu_wrapper.exe` to `dist/`
   - All OpenVINO DLLs (openvino*.dll, tbb*.dll, etc.)
   - MSVC runtime DLLs (msvcp140.dll, vcruntime140.dll)

### Manual Rebuild (Not Recommended)

Only use this if build.ps1 fails:

```powershell
# Load OpenVINO environment
$OV = "C:\Users\$env:USERNAME\Downloads\openvino_genai_windows_2025.4.0.0_x86_64"
cmd /c "call `"$OV\setupvars.bat`" && cd /d C:\Users\ser13\NPU_Project && cmake --build build --config Release"
```

---

## Architecture Overview

The project is organized in layers:

**Single-Device Mode:**
```
┌─────────────────────────────────┐
│       src/main.cpp              │ REPL, command parsing, stats
│     (Orchestration Layer)       │
└────────────┬────────────────────┘
             │ Calls
             ↓
┌─────────────────────────────────┐
│    OpenVINOScheduler             │ Device discovery & policy routing
│  (Device Scheduling Layer)      │ (IScheduler interface)
└────────────┬────────────────────┘
             │ Chooses device
             ↓
┌─────────────────────────────────┐
│    OpenVINOBackend               │ Model loading & token streaming
│ (OpenVINO Inference Layer)      │ (IBackend interface)
└────────────┬────────────────────┘
             │ Wraps
             ↓
┌─────────────────────────────────┐
│  ov::genai::LLMPipeline          │ OpenVINO GenAI C++ SDK
│ (Hardware Runtime)              │
└─────────────────────────────────┘
```

**Multi-Device Mode (--benchmark):**
```
┌─────────────────────────────────────────────────────────┐
│                   src/main.cpp                          │
│      (Orchestration + Multi-Device Routing)             │
└────────────┬────────────────────────────────────────────┘
             │ Uses
             ↓
┌─────────────────────────────────────────────────────────┐
│              OpenVINOScheduler                          │
│  • discover_devices()                                   │
│  • benchmark_devices()  ← Runs 2-sec tests on each      │
│  • get_best_device_from_benchmarks()                    │
└────────────┬────────────────────────────────────────────┘
             │ Recommends devices
             ↓
┌─────────────────────────────────────────────────────────┐
│                 BackendPool                             │
│  Manages multiple OpenVINOBackend instances             │
│  • load_on_devices([CPU, GPU, NPU])                     │
│  • set_active_device() ← Runtime switching              │
│  • generate_stream() → delegates to active backend      │
└────────────┬────────────────────────────────────────────┘
             │ Contains
             ↓
┌──────────────────┬──────────────────┬──────────────────┐
│  OpenVINOBackend │  OpenVINOBackend │  OpenVINOBackend │
│     (CPU)        │     (GPU)        │     (NPU)        │
└────────┬─────────┴────────┬─────────┴────────┬─────────┘
         │                  │                  │
         ↓                  ↓                  ↓
┌────────────────┬──────────────────┬──────────────────┐
│ LLMPipeline    │ LLMPipeline      │ LLMPipeline      │
│   (CPU)        │   (GPU)          │   (NPU)          │
└────────────────┴──────────────────┴──────────────────┘
```

**Key files:**
- `OpenVINO/Scheduler/IScheduler.h` — Abstract device scheduler (defines `EnginePolicy`, `DeviceBenchmark`)
- `OpenVINO/Scheduler/OpenVINOScheduler.{h,cpp}` — Concrete scheduler with benchmarking
- `OpenVINO/Backend/IBackend.h` — Abstract inference backend
- `OpenVINO/Backend/OpenVINOBackend.{h,cpp}` — Concrete backend wrapping LLMPipeline
- `OpenVINO/Backend/BackendPool.{h,cpp}` — Multi-backend manager for device switching
- `src/main.cpp` — REPL and command-line interface

---

## Code Features & Configuration

### Built-in Features

**Your code includes these features (see `src/main.cpp`, `OpenVINOScheduler.cpp`, and `OpenVINOBackend.cpp`):**

| Feature | What It Does |
|---------|---|
| **Scheduler Interface** | `IScheduler.h` defines device discovery and policy-based routing, implemented by `OpenVINOScheduler` |
| **Backend Interface** | `IBackend.h` defines the inference API, implemented by `OpenVINOBackend` |
| **Device Policies** | BATTERY_SAVER (NPU-first), PERFORMANCE (GPU-first), BALANCED (AUTO heterogeneous) |
| **Turn Marker Detection** | Auto-stops generation when model tries to start a new dialogue turn (detects `\nYou:`, `\nUser:`, `\nAI:`) |
| **Auto-Device Fallback** | If NPU fails, automatically retries on CPU |
| **Token Streaming** | Outputs tokens in real-time as they're generated |
| **Execution Benchmarking** | Shows timing for each generation: `[Time: X.XXX seconds]` |
| **Perf Stats Command** | `stats` prints TTFT/TPOT/throughput from OpenVINO GenAI |
| **Automatic Logging** | Logs all activity to `runlog.txt` in project root (auto-deleted on success, kept on error) |

### Device Selection & Scheduling

**The code uses a three-tier system:**

1. **Scheduler discovery** — `OpenVINOScheduler` scans all available devices via `ov::Core::get_available_devices()`
2. **Policy routing** — Based on the `--policy` flag, choose the optimal device:
   - `BATTERY_SAVER` (default): Return NPU if available, else CPU
   - `PERFORMANCE`: Return GPU if available, else CPU
   - `BALANCED`: Return `AUTO:GPU,NPU,CPU` for OpenVINO heterogeneous routing
3. **Override option** — `--device` flag bypasses policy and forces a specific device

```cpp
// From OpenVINOScheduler.cpp
switch (policy) {
    case EnginePolicy::PERFORMANCE:
        return has_gpu ? "GPU" : "CPU";
    case EnginePolicy::BATTERY_SAVER:
        return has_npu ? "NPU" : "CPU";
    case EnginePolicy::BALANCED:
    default:
        return "AUTO:GPU,NPU,CPU";
}
```

**Priority within each policy:**
- **Policies are explicit**, not nested. Each one has its own logic.
- `--device` always wins if provided (overrides `--policy`).

### Example Device Selection Flow

```
User runs: npu_wrapper.exe ./models/Qwen2.5 --policy BATTERY_SAVER
    ↓
Scheduler discovers: [CPU, GPU, NPU]
    ↓
Policy = BATTERY_SAVER → find NPU?
    ↓
Yes → Device = "NPU"
    ↓
Load model on NPU
```

Another example with override:

```
User runs: npu_wrapper.exe ./models/Qwen2.5 --policy PERFORMANCE --device CPU
    ↓
Scheduler discovers: [CPU, GPU, NPU]
    ↓
Policy = PERFORMANCE → GPU preferred
    ↓
Override detected! Device = "CPU" (from --device flag)
    ↓
Load model on CPU (ignoring policy)
```

### Model Path in Help Message

The executable's help message shows the correct usage:

```cpp
// src/main.cpp line ~50
"Example: npu_wrapper.exe ./models/Qwen3_0_6B_ov"
```

**Use your actual model folder name instead:**
```
./models/Qwen2.5-0.5B-Instruct    (current recommended model)
./models/TinyLlama_ov              (alternative)
```

---

These values are in `OpenVINOBackend.cpp` and can be customized:

```cpp
// Main generation settings
cfg.max_new_tokens = 128;      // Max tokens to generate per prompt
cfg.temperature = 0.7f;        // Creativity level (0.0 = deterministic, 1.0+ = creative)
```

**To change these values:**
1. Edit `src/main.cpp` at the lines above
2. Rebuild: `.\build.ps1`

### Log File Location & Auto-Deletion

The log file has smart cleanup behavior:

**When logs are KEPT (on errors):**
```
Error occurs
    ↓
Program returns early (return 1)
    ↓
runlog.txt stays on disk
    ↓
User can review errors for debugging
```

**When logs are AUTO-DELETED (successful exit):**
```
User types "exit"
    ↓
Program reaches end (return 0)
    ↓
C++ code: std::filesystem::remove("runlog.txt")
    ↓
runlog.txt automatically deleted
```

**Location:** Writes to `runlog.txt` in current working directory (project root when running from project root)

**Code that handles this (src/main.cpp, end of main):**
```cpp
logline("=== RUN END ===");

// Delete the log file when done (success path only)
try {
    std::filesystem::remove("runlog.txt");
} catch (...) {
    // Silently ignore if deletion fails
}

return 0;  // Success exit - log gets deleted
```

**Why this design:**
- Clean exit leaves no logs
- Errors keep logs for troubleshooting
- Try-catch prevents crash if deletion fails

---

**Show Exe Path (optional):**
1. In `src/main.cpp` around line 56, uncomment:
```cpp
MessageBoxA(nullptr, exePath, "EXE PATH", MB_OK);
```
2. Rebuild with `.\build.ps1`
3. Program will show a popup with the executable location

---

### What Gets Created

```
NPU_Project/
├── build/                          ← CMake build files (AUTO-GENERATED)
│   ├── CMakeFiles/
│   ├── Release/
│   │   └── npu_wrapper.exe         ← Compiled executable
│   └── NPU_Project.sln
│
├── dist/                           ← Runtime folder (AUTO-POPULATED by build.ps1)
│   ├── npu_wrapper.exe             ← Copied from build/Release/
│   ├── openvino*.dll               ← OpenVINO runtime libraries (19 DLLs)
│   ├── icudt70.dll, icuuc70.dll    ← Unicode support libraries
│   ├── msvcp140.dll                ← MSVC runtime (auto-copied)
│   ├── vcruntime140.dll            ← MSVC runtime (auto-copied)
│   ├── cache.json                  ← OpenVINO device cache
│   └── runlog.txt                  ← Auto-deleted after successful run
│
├── models/                         ← Your models (YOU POPULATE)
│   ├── TinyLlama_ov/
│   ├── Qwen3_0.6B_ov/
│   └── ...other models/
│
├── src/
│   └── main.cpp                    ← Source code
│
├── CMakeLists.txt                  ← Build configuration
├── README.md                       ← This file
└── .gitignore
```

### Automatic Exe and DLL Copy

After each build, `CMakeLists.txt` automatically:

1. **Creates dist/ folder** if it doesn't exist
2. **Copies the executable** from build/Release/ to dist/
3. **Copies all OpenVINO DLLs** from `runtime/bin/intel64/Release/`
4. **Copies MSVC runtime DLLs** (msvcp140.dll, vcruntime140.dll)

```cmake
add_custom_command(TARGET npu_wrapper POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
        ${CMAKE_SOURCE_DIR}/dist/
    COMMAND ${CMAKE_COMMAND} -E copy
        $<TARGET_FILE:npu_wrapper>
        ${CMAKE_SOURCE_DIR}/dist/
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "C:/Users/ser13/Downloads/openvino_genai_windows_2025.4.0.0_x86_64/runtime/bin/intel64/Release"
        ${CMAKE_SOURCE_DIR}/dist/
    COMMAND ${CMAKE_COMMAND} -E copy
        "C:/Windows/System32/msvcp140.dll"
        ${CMAKE_SOURCE_DIR}/dist/
    COMMAND ${CMAKE_COMMAND} -E copy
        "C:/Windows/System32/vcruntime140.dll"
        ${CMAKE_SOURCE_DIR}/dist/
)
```

### Benchmarking & Logging Features

**Automatic in main.cpp:**
1. **Warm-up run** — First generation stabilizes device performance
2. **Per-prompt timing** — Shows `[Time: X.XXX seconds]` after each response
3. **Error logging** — `runlog.txt` stays on disk if error occurs (for debugging)
4. **Auto-cleanup** — Log file deletes on successful exit
5. **Device fallback** — Auto-retries on CPU if NPU/GPU fails

---

## Troubleshooting

### Program exits immediately with no output

**Cause:** Exit code `-1073741515` means DLL entry point not found.

**Solution:**
```powershell
# Run build.ps1 first to set up environment
.\build.ps1

# Then run the executable in the same PowerShell session
.\dist\npu_wrapper.exe .\models\Qwen2.5-0.5B-Instruct
```

**Why this happens:**
- OpenVINO DLLs need environment variables set by `setupvars.bat`
- `build.ps1` now loads these into your PowerShell session automatically
- Running the exe in the same session where you ran `build.ps1` should work

**Alternative workaround:**
```powershell
# Run everything in one cmd session
$OV = "C:\Users\$env:USERNAME\Downloads\openvino_genai_windows_2025.4.0.0_x86_64"
cmd /c "call `"$OV\setupvars.bat`" && cd /d C:\Users\ser13\NPU_Project && .\dist\npu_wrapper.exe .\models\Qwen2.5-0.5B-Instruct"
```

### Error: "Could not find a model in the directory"

**Solution:**
- Check model path is correct: `./models/Qwen2.5-0.5B-Instruct/`
- Verify `openvino_model.xml` and `openvino_model.bin` exist in that folder
- Model folder must contain the full OpenVINO IR format (not just .gguf files)

### Error: "OpenVINO not found" during build

**Solution 1: Update build.ps1**
Edit `build.ps1` line 8 with the correct path:
```powershell
$OV = "C:\Users\<YourUsername>\Downloads\openvino_genai_windows_2025.4.0.0_x86_64"
```

**Solution 2: Update CMakeLists.txt**
Edit `CMakeLists.txt` lines 13-14:
```cmake
set(OpenVINO_DIR "C:/Users/<YourUsername>/Downloads/openvino_genai_windows_2025.4.0.0_x86_64/runtime/cmake")
set(OpenVINOGenAI_DIR "C:/Users/<YourUsername>/Downloads/openvino_genai_windows_2025.4.0.0_x86_64/runtime/cmake")
```

**Important:** Use forward slashes `/` in CMakeLists.txt, not backslashes `\`

### Error: "setupvars.bat not found" or missing runtime DLLs

**Cause:** You downloaded the PyPI package instead of the Archive Installation.

**How to check:**
```powershell
# Navigate to your OpenVINO folder
cd C:\Users\$env:USERNAME\Downloads\openvino_genai_windows_2025.4.0.0_x86_64

# Check for these files/folders:
ls setupvars.bat                    # Should exist at root
ls runtime\bin\intel64\Release\     # Should contain .dll files
ls runtime\cmake\                   # Should contain .cmake files
```

**Solution:**
1. Delete the existing OpenVINO folder
2. Go to [OpenVINO GenAI GitHub Releases](https://github.com/openvinotoolkit/openvino.genai/releases)
3. Download **Release 2025.4.0.0** - `openvino_genai_windows_2025.4.0.0_x86_64.zip`
4. Extract to `C:\Users\<YourUsername>\Downloads\`
5. Verify the folder structure matches above

**Note:** Don't use curl/wget commands from documentation as they may point to wrong versions (e.g., 2024.6.0.0 instead of 2025.4.0.0).

**Note:** Running `pip install openvino-genai` only installs Python bindings, not the C++ runtime needed for this project.

### Error: Wrong OpenVINO version installed

**Symptoms:**
- Build succeeds but executable crashes with DLL errors
- Missing functions or incompatible library messages
- setupvars.bat exists but wrong version number

**How to check your version:**
```powershell
# Look at the folder name:
ls C:\Users\$env:USERNAME\Downloads\openvino_genai_windows_*

# Should show: openvino_genai_windows_2025.4.0.0_x86_64
# NOT: openvino_genai_windows_2024.6.0.0_x86_64 or other versions
```

**Solution:**
1. Delete the wrong version folder
2. Download the correct version from [GitHub Releases - 2025.4.0.0](https://github.com/openvinotoolkit/openvino.genai/releases/tag/2025.4.0.0)
3. Update paths in `CMakeLists.txt` and `build.ps1` if needed
4. Run `.\build.ps1 -Clean`

### Build fails with linker errors ("undefined reference to `__imp__...")

**Solution:**
- Use **MSVC** (Visual Studio), not MinGW
- Clean and rebuild:
  ```powershell
  rm -r build
  mkdir build
  cd build
  cmake -G "Visual Studio 17 2022" -A x64 ..
  cmake --build . --config Release
  ```

### Model runs very slowly

**Solution:**
- Check device selection in output (should show `Device chosen: CPU`, `GPU`, or `NPU`)
- If CPU, use smaller models: 0.6B or 1.5B instead of 7B+
- Check system RAM and VRAM

### venv activation fails

**Solution:**
```powershell
# If .\venv\Scripts\Activate.ps1 fails, try:
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
.\venv\Scripts\Activate.ps1
```

---

## Command Reference

| Command | Purpose |
|---------|---------|
| `.\build.ps1` | Build project (sets up OpenVINO env automatically) |
| `.\build.ps1 -Clean` | Clean rebuild (deletes build folder first) |
| `.\dist\npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct` | Run the model |
| `\.\dist\npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --device NPU` | Run on NPU |
| `\.\dist\npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --device CPU` | Run on CPU |
| `.\venv\Scripts\Activate.ps1` | Activate Python virtual environment |
| `pip install optimum[openvino]` | Install model conversion tools |
| `optimum-cli export openvino --model <HF-ID> ./models/output` | Convert model to OpenVINO |

---

## Versions

| Software | Version |
|----------|---------|
| Visual Studio Build Tools | 2022 (17.x) |
| CMake | 3.28+ |
| OpenVINO GenAI | 2025.4.0.0 |
| Python | 3.11+ |
| C++ Standard | C++17 |

---

## How It Works

```
User Prompt
    ↓
main.cpp (C++ code)
    ↓
ov::genai::LLMPipeline (OpenVINO inference engine)
    ↓
Device Selection (NPU → GPU → CPU)
    ↓
Model Output (streamed token-by-token)
    ↓
Benchmark Timing + Logging
    ↓
Display to user + `runlog.txt` (if error)
```

---

---

## Pushing to GitHub

### Files to Push

**Essential files:**
```
CMakeLists.txt
build.ps1
README.md
.gitignore
src/main.cpp
```

**DO NOT push:**
- `build/` - Build artifacts (auto-generated)
- `dist/` - Compiled executables and DLLs (auto-generated)
- `venv/` - Python virtual environment (recreate on each machine)
- `models/` - Model files (too large, download separately)
- `*.exe`, `*.dll`, `*.obj` - Binaries
- `runlog.txt` - Log file (auto-deleted after successful runs)

The `.gitignore` file is already configured to ignore these automatically.

### Before Pushing

Make sure to update hardcoded paths in `CMakeLists.txt`:
- Replace `C:/Users/ser13/` with `C:/Users/<YourUsername>/`
- Or document the required path in README

The `build.ps1` script already uses `$env:USERNAME` so it's portable.

---

## Support & Resources

- **OpenVINO Docs:** [docs.openvino.ai](https://docs.openvino.ai/)
- **Optimum Intel:** [huggingface.co/docs/optimum/intel](https://huggingface.co/docs/optimum/intel/index)
- **Hugging Face Models:** [huggingface.co/models](https://huggingface.co/models)

---

## License

This repository does **not** distribute model weights. You export/download models locally and must follow each model's license terms.
