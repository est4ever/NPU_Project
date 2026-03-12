# NPU_Project — OpenVINO GenAI LLM C++ Wrapper (Windows)

A minimal C++ CLI wrapper that runs **OpenVINO GenAI LLMs** (OpenVINO-exported models) with device selection (CPU / GPU / NPU) and automatic fallback.

> **Important:** This repo does **not** ship models. You export/download models locally into `models/`.

## What This Project Does

- Loads OpenVINO GenAI LLMs from folders like `./models/Qwen2.5-0.5B-Instruct`
- **Scheduler-based device selection** with three policies: BATTERY_SAVER (NPU-first), PERFORMANCE (GPU-first), BALANCED (AUTO heterogeneous)
- **Multi-device execution mode** (`--benchmark`): Runs 2-second benchmarks on all devices, loads model on all of them, and allows runtime switching
- **REST API Server** (`--server`): OpenAI-compatible HTTP endpoints for external integration
- **Context-aware routing** (`--context-routing`): Automatically selects best device based on prompt length
- **Advanced KV-cache** (`--optimize-memory`): INT8 quantization for 50-75% memory savings
- Auto-detects available hardware and applies policy-based routing
- Interactive terminal-based prompting with automatic fallback on device errors
- Real-time benchmarking: shows execution time after each generation
- `--json` emits NDJSON metrics for UI/automation
- `--split-prefill` routes long prompts to best TTFT device, short prompts to best throughput device
- `--speculative` enables OpenVINO's native speculative decoding with draft/verify pipeline and real acceptance metrics
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
| **OpenVINO GenAI** | 2026.0.0.0 | Model inference engine |
| **Python** | 3.10+ | Model conversion (optional) |
| **C++ Standard** | C++17 | Code requirement |
| **cpp-httplib** | v0.15.3 | HTTP server (auto-fetched via CMake) |
| **nlohmann/json** | v3.11.3 | JSON parsing (auto-fetched via CMake) |
| **Windows PSAPI** | Built-in | Memory monitoring for KV-cache |

---

## OpenVINO 2026 API Changes

**Updated for OpenVINO 2026.0.0.0:**

This project has been updated to support OpenVINO GenAI 2026.0.0.0, which introduced breaking API changes:

- **Streaming API:** The new version requires using `TextStreamer` objects instead of lambda functions
- **Callback Interface:** Callbacks now return `StreamingStatus` enum (RUNNING, STOP, CANCEL) instead of `bool`
- **Tokenizer Access:** Must explicitly get the tokenizer from the pipeline via `pipe->get_tokenizer()`

**Code Changes Made:**
- Updated `OpenVINO/Backend/OpenVINOBackend.cpp` to use `ov::genai::TextStreamer`
- Modified both `generate_stream()` and `generate_output()` methods
- Changed callback return types from `bool` to `ov::genai::StreamingStatus`

**Migration from 2025.4.0.0 → 2026.0.0.0:**
- Old: `pipe->generate(prompt, cfg, [&](const std::string& text) { return false; })`
- New: `pipe->generate(prompt, cfg, std::make_shared<TextStreamer>(tokenizer, callback))`

If you're upgrading from a previous version, ensure you extract the new OpenVINO archive correctly (avoid nested folders) and update all path references in your configuration files.

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

#### C. OpenVINO GenAI (2026.0.0.0) - Archive Installation

**Important:** You need the **Archive Installation** (C++ runtime), not just the PyPI package.

**⚠️ Critical: Download the correct version (2026.0.0.0)**

The OpenVINO documentation may show curl/wget commands for **different versions** (like 2024.6.0.0). **DO NOT use those commands directly** as they will download the wrong version.

**Correct Download Method:**

1. Go to [OpenVINO GenAI GitHub Releases](https://github.com/openvinotoolkit/openvino.genai/releases)
2. Find **Release 2026.0.0.0**
3. Download: `openvino_genai_windows_2026.0.0.0_x86_64.zip`
4. Extract to: `C:\Users\<YourUsername>\Downloads\openvino_genai_windows_2026.0.0.0_x86_64\`
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
set(OpenVINO_DIR "C:/Users/<YourUsername>/Downloads/openvino_genai_windows_2026.0.0.0_x86_64/runtime/cmake")
set(OpenVINOGenAI_DIR "C:/Users/<YourUsername>/Downloads/openvino_genai_windows_2026.0.0.0_x86_64/runtime/cmake")
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

> **Easiest Way:** Use the `run.ps1` wrapper script - it handles all environment setup automatically!

#### Quick Start (Recommended)

```powershell
cd C:\Users\<YourUsername>\NPU_Project

# Run with any arguments you want - environment setup is automatic
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --policy PERFORMANCE
```

That's it! The `run.ps1` script automatically:
- Loads the OpenVINO environment
- Runs the executable with your arguments
- No manual environment setup needed

#### Usage Examples

```powershell
# Default policy (BATTERY_SAVER = prioritize NPU)
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct

# PERFORMANCE policy (GPU preferred)
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --policy PERFORMANCE

# BATTERY_SAVER policy (NPU preferred)
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --policy BATTERY_SAVER

# BALANCED policy (AUTO heterogeneous)
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --policy BALANCED

# Force specific device
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --device NPU
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --device GPU

# Benchmark mode (test all devices)
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --benchmark

# Benchmark with PERFORMANCE policy
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --benchmark --policy PERFORMANCE

# NDJSON metrics (one JSON line per generation, printed to stderr)
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --json

# REST API Server mode (OpenAI-compatible endpoints)
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --server
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --server --port 3000

# Server with advanced features
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --server --optimize-memory --context-routing

# Split prefill vs decode routing (long prompts -> best TTFT device)
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --benchmark --split-prefill --prefill-threshold 256

# Calibrate a good prefill threshold and exit
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --calibrate-prefill

# Speculative decoding with real metrics
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --speculative --draft-model ./models/Qwen2.5-0.5B-Instruct --draft-device CPU --verify-device CPU --draft-k 4 --json 2> spec_metrics.ndjson
```

#### JSON Metrics (NDJSON)

Use `--json` to emit **one JSON line per generation** to `stderr`. This keeps normal assistant text on `stdout` and makes the output easy to pipe into tools or a UI.

**Fields:**
- `schema` (number)
- `ts` (unix epoch ms)
- `model` (string)
- `device` (string)
- `policy` (string)
- `ttft_ms`, `tpot_ms`, `throughput_tok_s`, `total_ms` (number or null)
- `prompt_tokens`, `generated_tokens` (number or null)
- `token_count_source` (string: `openvino_native`, `estimated`, `unknown`)
- `throughput_derived` (bool or null)
- `speculative_requested`, `speculative_active` (bool)
- `draft_k` (number or null)
- `draft_model`, `draft_device`, `verify_device` (string or null)
- `accept_rate` (number or null)
- `accepted_tokens`, `proposed_tokens` (number or null)
- `spec_disabled_reason` (string or null)
- `fallback_used` (bool)
- `error` (string or null)

**Example output:**
```json
{"schema":1,"ts":1739999999000,"model":"Qwen2.5-0.5B-Instruct","device":"NPU","policy":"PERFORMANCE","ttft_ms":124.531,"tpot_ms":13.902,"throughput_tok_s":71.942,"total_ms":1012.300,"prompt_tokens":18,"generated_tokens":64,"token_count_source":"openvino_native","throughput_derived":false,"speculative_requested":false,"speculative_active":false,"draft_k":null,"draft_model":null,"draft_device":null,"verify_device":null,"accept_rate":null,"accepted_tokens":null,"proposed_tokens":null,"spec_disabled_reason":null,"fallback_used":false,"error":null}
```

**Redirect to a file (PowerShell):**
```powershell
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --json 2> metrics.ndjson
```

#### Split Prefill vs Decode Routing

Use `--split-prefill` to route long prompts to the device with the best **TTFT** and short prompts to the device with the best **throughput**. In benchmark mode, the routing uses the benchmark results. Outside benchmark mode, it prefers GPU for TTFT and NPU for throughput if available.

**Options:**
- `--split-prefill` (enable routing)
- `--prefill-threshold N` (token threshold, default 256)

**Notes:**
- Prompt length uses a lightweight token estimate (whitespace token count). It does not load a tokenizer.
- If you pass `--device`, split-prefill is disabled.

#### Speculative Decoding

Use `--speculative` to enable **OpenVINO's native speculative decoding** with draft token proposal and verification. The wrapper uses `ov::genai::LLMPipeline` with integrated draft model support for optimal performance.

**Real Metrics Tracked:**
- `accept_rate`: Ratio of draft tokens verified successfully by main model
- `accepted_tokens`: Number of draft tokens that matched main model output
- `proposed_tokens`: Total draft tokens proposed per iteration
- `spec_disabled_reason`: Why speculative decoding was disabled (if applicable)

**Options:**
- `--speculative` (enable speculative decoding)
- `--draft-model PATH` (path to draft model, required)
- `--draft-device DEVICE` (device for draft model, e.g., `NPU` or `CPU`)
- `--verify-device DEVICE` (device for main model, defaults to policy selection)
- `--draft-k N` (draft tokens per iteration, default 5; typical range 3–8)
- `--min-accept X` (acceptance rate threshold for auto-disable, default 0.55)
- `--spec-disable-on-low-accept` (auto-disable if acceptance rate drops below threshold)

**Example:**
```powershell
# Typical setup: draft on NPU (low latency), verify on GPU (high throughput)
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct `
  --speculative `
  --draft-model ./models/Qwen2.5-0.5B-Instruct `
  --draft-device NPU `
  --verify-device GPU `
  --draft-k 4 `
  --json 2> metrics.ndjson
```

**Metrics Example:**
```json
{
  "speculative_requested": true,
  "speculative_active": true,
  "draft_k": 4,
  "accept_rate": 0.75,
  "accepted_tokens": 15,
  "proposed_tokens": 20,
  "generated_tokens": 20
}
```

**Notes:**
- `--device` acts as an alias for `--verify-device` when `--speculative` is set.
- In benchmark mode, verify defaults to the best benchmarked device unless overridden.
- Accept rate is updated in real time and available in NDJSON output per generation.

---

## Advanced Features

### REST API Server Mode (OpenAI-Compatible)

Run the wrapper as an **HTTP server** with OpenAI-compatible endpoints for integration with external applications, UIs, or automation tools.

**Quick Start:**
```powershell
# Start server on default port 8080
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --server

# Custom port
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --server --port 3000

# Server with advanced features
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --server --optimize-memory --context-routing
```

**REST Endpoints:**

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/v1/chat/completions` | Generate chat completions (OpenAI format) |
| GET | `/v1/models` | List available models |
| GET | `/health` | Health check with active backend info |

**Example Request (PowerShell - Recommended):**
```powershell
$body = @'
{
  "model": "openvino-local",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "Explain quantum computing in simple terms"}
  ],
  "max_tokens": 150,
  "temperature": 0.7
}
'@

# Make the request and store the response
$response = Invoke-RestMethod -Uri "http://localhost:8080/v1/chat/completions" `
  -Method Post `
  -ContentType "application/json" `
  -Body $body

# Extract the AI's response text
$response.choices[0].message.content
```

**Quick one-liner for testing:**
```powershell
# For quick tests, access .choices[0].message.content directly
(Invoke-RestMethod http://localhost:8080/v1/chat/completions -Method Post -ContentType "application/json" -Body '{"model":"openvino-local","messages":[{"role":"user","content":"Hello!"}],"max_tokens":50}').choices[0].message.content
```

**Alternative (real cURL in PowerShell):**
```powershell
curl.exe http://localhost:8080/v1/chat/completions `
  -H "Content-Type: application/json" `
  -d '{"model":"openvino-local","messages":[{"role":"system","content":"You are a helpful assistant."},{"role":"user","content":"Explain quantum computing in simple terms"}],"max_tokens":150,"temperature":0.7}'
```

**Example Response:**
```json
{
  "id": "chatcmpl-1739999999000",
  "object": "chat.completion",
  "created": 1739999999,
  "model": "openvino-local",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": "Quantum computing uses qubits that can exist in multiple states..."
    },
    "finish_reason": "stop"
  }],
  "usage": {
    "prompt_tokens": 0,
    "completion_tokens": 28,
    "total_tokens": 28
  }
}
```

**Accessing the response in PowerShell:**
```powershell
# The AI's message is nested in: .choices[0].message.content
$response.choices[0].message.content

# Output: "Quantum computing uses qubits that can exist in multiple states..."
```
> **Note:** If you call `Invoke-RestMethod` without storing the result, PowerShell will display `message=` as empty. Always store the response in a variable and access `.choices[0].message.content` to see the generated text.

**Features:**
- **OpenAI-compatible JSON format** - works with existing OpenAI client libraries
- **CORS enabled** - allows browser-based applications
- **Automatic error handling** - returns structured error responses
- **Thread-safe** - handles concurrent requests via backend pool
- **Dependencies auto-fetched** - uses CMake FetchContent for cpp-httplib and nlohmann/json
- **Works standalone or with benchmark mode** - combine with `--benchmark` for runtime device switching

**Notes:**
- Server mode disables the interactive REPL
- Uses the active backend selected by policy/device flags
- Port default is 8080, customize with `--port <number>`
- Streaming endpoint now returns OpenAI-compatible SSE chunks (`role`, `content`, final stop chunk, `[DONE]`)
- To stop the server: Press **Ctrl+C** in the terminal, or from PowerShell: `Stop-Process -Name "npu_wrapper" -Force`

### Open-WebUI Integration (Windows + venv)

If PowerShell shows `open-webui : The term 'open-webui' is not recognized...`, the virtual environment is not active in that terminal.

**One-command launcher (recommended):**
```powershell
.\start_openwebui_stack.ps1
```
This script stops stale processes, starts both services, waits for readiness, and opens `http://localhost:8080`.

**One-command refresh after code changes (build + deploy + restart):**
```powershell
.\refresh_stack.ps1
```
This script stops stale backend/UI processes, runs `build.ps1`, copies `build\Release\npu_wrapper.exe` to `dist\npu_wrapper.exe` with retry logic, then starts the stack.

**Useful options:**
```powershell
# Skip build (just deploy/restart)
.\refresh_stack.ps1 -SkipBuild

# Force backend args while refreshing
.\refresh_stack.ps1 -BackendArgs @("--device","NPU")
```

### Fixes Added (March 2026)

This project now includes the following Open-WebUI and local API compatibility fixes:

1. **Streaming compatibility for Open-WebUI**
- `/v1/chat/completions` now returns valid OpenAI-style SSE events (`role`, `content`, `finish_reason`, `[DONE]`).

2. **Message content compatibility**
- Handles both string content and array-style content parts (for UI payload variations).

3. **Backend abstraction fix**
- REST server now calls generation through the `IBackend` interface (no fragile runtime cast requirement).

4. **Fail-fast backend load behavior**
- `BackendPool` now throws a clear startup error if all requested device loads fail, instead of failing later per request.

5. **Startup script reliability updates**
- Browser auto-open uses a more reliable Windows launcher path.
- UI URL guidance explicitly uses `http://localhost:8080` (not `https`).
- Added optional `-HideServiceWindows` switch.
- Added `-BackendArgs` passthrough so Open-WebUI backend startup can match your known-good terminal flags.
- `-BackendArgs` defaults to empty so stack startup matches normal `run.ps1` defaults unless explicitly overridden.

6. **Open-WebUI chat is now pure chat (commands moved to terminal)**
- Open-WebUI should be used for conversation only.
- Runtime control commands are handled via terminal using `npu_cli.ps1`.
- This keeps the `/v1/chat/completions` behavior OpenAI-compatible and avoids command/chat mixing.

**Use terminal for control commands:**
```powershell
# Show current settings
.\npu_cli.ps1 -Command status

# Switch device
.\npu_cli.ps1 -Command switch -Arguments "GPU"

# Change policy
.\npu_cli.ps1 -Command policy -Arguments "PERFORMANCE"

# Toggle features
.\npu_cli.ps1 -Command split-prefill -Arguments "on"
.\npu_cli.ps1 -Command context-routing -Arguments "off"

# Metrics
.\npu_cli.ps1 -Command metrics -Arguments "last"
```

**CLI command list:**
- `help`
- `status`, `health`, `devices`, `stats`
- `switch <CPU|GPU|NPU>`
- `policy <PERFORMANCE|BATTERY_SAVER|BALANCED>`
- `json on|off`
- `split-prefill on|off`
- `context-routing on|off`
- `optimize-memory on|off`
- `threshold <N>`
- `metrics <last|summary|clear>`
- `benchmark` and `calibrate` (terminal-mode guidance)

**Model manager (new):**
- `model list`
- `model import <id> <path> [format]`
- `model select <id>` (applies on next stack restart)
- `model download <huggingface_repo> [id]`

**Backend manager (new):**
- `backend list`
- `backend add <id> <type> <entrypoint>`
- `backend select <id>` (applies on next stack restart)

**Examples:**
```powershell
# Register and select a local model
.\npu_cli.ps1 -Command model -Arguments "import","qwen-local","./models/Qwen2.5-0.5B-Instruct","openvino"
.\npu_cli.ps1 -Command model -Arguments "select","qwen-local"

# Download from Hugging Face into ./models and register automatically
.\npu_cli.ps1 -Command model -Arguments "download","Qwen/Qwen2.5-0.5B-Instruct","qwen-hf"

# Register and select an additional backend entry
.\npu_cli.ps1 -Command backend -Arguments "add","onnxruntime","external","C:/tools/onnxruntime_runner.exe"
.\npu_cli.ps1 -Command backend -Arguments "select","onnxruntime"
```

Registries are persisted in:
- `registry/models_registry.json`
- `registry/backends_registry.json`

7. **Runtime terminal commands (no restart needed)**

**Available in ALL startup modes (single-device, benchmark, and speculative):**

**Core Commands:**
- `help` - Show all available commands
- `status` or `info` - Show current policy, device, and all settings
- `exit` - Exit the program
- `memory` - Show RAM/VRAM usage

**Device Management Commands:**
- `devices` - List all loaded devices
- `switch <device>` - Change active device (e.g., `switch GPU`)
- `policy <PERFORMANCE|BATTERY_SAVER|BALANCED>` - Change scheduling policy at runtime
- `benchmark` - Run device benchmarks and load all devices (upgrades from single-device mode)

**Feature Toggle Commands:**
- `json on|off` - Toggle JSON metrics output
- `split-prefill on|off` - Toggle split prefill/decode routing (requires multiple devices)
- `context-routing on|off` - Toggle context-aware device routing
- `optimize-memory on|off` - Toggle INT8 KV-cache compression (takes effect on next load)

**Advanced Configuration:**
- `threshold <N>` - Set prefill token threshold for split-prefill (e.g., `threshold 50`)
- `calibrate` - Run TTFT tests across devices to find optimal threshold (requires multiple devices)
- `stats` - Show OpenVINO performance metrics (TTFT, TPOT, throughput)

**Example Runtime Workflow:**
```
You: status
[Current Settings]
Policy: BALANCED
Active device: NPU
JSON output: OFF
Split-prefill: OFF
...

You: benchmark
[Benchmark] Running device benchmarks...
[Benchmark] Loading model on all tested devices...
[Benchmark] Done. Active device: GPU

You: split-prefill on
[Split-prefill ENABLED]
TTFT device: NPU
Throughput device: GPU
Threshold: 50 tokens

You: calibrate
[Calibrate] Running prefill threshold calibration...
[Calibrate] 10 tokens: NPU=0.15s, GPU=0.22s
[Calibrate] 25 tokens: NPU=0.18s, GPU=0.20s
[Calibrate] 50 tokens: NPU=0.25s, GPU=0.18s
[Calibrate] Recommended threshold: 25 tokens
```

**Notes:**
- Commands work in both single-device and benchmark startup modes
- Use `benchmark` command to transition from single-device → multi-device at runtime
- Some features (split-prefill, calibrate) require multiple devices loaded
- Policy changes affect future device selections; run `benchmark` to apply immediately

**Important:** Rebuild after pulling/changing code so these fixes are included in `dist/npu_wrapper.exe`.

```powershell
Get-Process npu_wrapper -ErrorAction SilentlyContinue | Stop-Process -Force
.\build.ps1
```

Then start stack:

```powershell
.\start_openwebui_stack.ps1
```

or force specific backend behavior:

```powershell
.\start_openwebui_stack.ps1 -BackendArgs @("--device","NPU")
.\start_openwebui_stack.ps1 -BackendArgs @("--policy","PERFORMANCE")
```

**1) Start NPU REST server (Terminal A):**
```powershell
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --server --port 8000
```

**2) Start Open-WebUI with venv activated (Terminal B):**
```powershell
cd C:\Users\ser13\NPU_Project
.\venv\Scripts\Activate.ps1
open-webui serve --host 0.0.0.0 --port 8080
```

**3) Connect Open-WebUI to this project API:**
- Open `http://localhost:8080` in your browser (or use VS Code **Simple Browser**)
- Click the **⚙️ Settings icon** (usually bottom-left or top-right)
- Navigate to **Admin Settings → Connections** (or just **Connections**)
- Under **OpenAI API** section:
  - Set **Base URL** to: `http://localhost:8000/v1`
  - **API Key**: Enter any placeholder like `sk-dummy` (not validated)
- Click **Save**
- Return to chat and select **openvino-local** from the model dropdown
- Type a message to test the generation pipeline (or test `help`, `devices`, `stats`)

**4) Verify API before connecting UI (recommended):**
```powershell
Invoke-RestMethod http://localhost:8000/health
Invoke-RestMethod http://localhost:8000/v1/models
```

**Restart checklist if connection fails:**
1. Stop both terminals with **Ctrl+C**
2. Confirm no old process is left:
  ```powershell
  Get-Process npu_wrapper -ErrorAction SilentlyContinue | Stop-Process -Force
  Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force
  ```
3. Start Terminal A (NPU server) again
4. Start Terminal B (activate venv, then `open-webui serve`) again
5. Re-check `http://localhost:8000/health` before reconnecting in UI

### Context-Aware Device Routing

Automatically route prompts to the **optimal device** based on estimated context length, applying intelligent thresholds for different prompt sizes.

**Enable:**
```powershell
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --context-routing
```

**How It Works:**

The scheduler analyzes prompt length and routes based on device characteristics:

| Context Size | Threshold | Best Device | Reasoning |
|--------------|-----------|-------------|-----------|
| **Short** | < 100 tokens | NPU | Minimal overhead, best latency |
| **Medium** | 100-500 tokens | GPU or CPU | Balanced throughput |
| **Long** | 500-2000 tokens | GPU | High memory bandwidth needed |
| **Very Long** | > 2000 tokens | CPU | Large context handling |

**Policy Modifiers:**
- **PERFORMANCE**: Prefers GPU for medium/long prompts
- **BATTERY_SAVER**: Prefers NPU for short, CPU for long
- **BALANCED**: Uses AUTO heterogeneous mode

**Example Scenario:**
```
User enters: "Hello" (5 tokens estimated)
  → Routes to NPU (low latency)

User enters: "Write a detailed essay..." (450 tokens estimated)
  → Routes to GPU (high throughput)

User enters: "Analyze this 10-page document..." (2500 tokens estimated)
  → Routes to CPU (large memory)
```

**Token Estimation:**
- Uses fast whitespace-based estimation (no tokenizer loading)
- Adds 20% overhead for safety margin
- Accurate enough for routing decisions without latency penalty

**Combine with Benchmark:**
```powershell
# Context routing with live device metrics
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --benchmark --context-routing
```

### Advanced KV-Cache Management

Optimize memory usage with **INT8 quantized KV-cache** for reduced RAM consumption during inference.

**Enable Memory Optimization:**
```powershell
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --optimize-memory
```

**Features:**

#### 1. INT8 Quantization (Active)
- **Reduces memory usage by 50-75%** compared to FP16/FP32 cache
- **Device-specific optimizations:**
  - **NPU**: Enables NPUW (NPU weight unification) for better cache efficiency
  - **GPU**: Enables SDPA optimizations for attention computation
  - **CPU**: Standard cache compression
- **Minimal quality impact** - tested with various models
- **Automatic configuration** - no manual tuning required

#### 2. Memory Monitoring (Active)
- **Real-time RAM tracking** via Windows PSAPI
- **Initial check at startup** - displays memory status when enabled
- **Continuous monitoring** - checks memory after each generation
- **90% threshold warnings** - automatic alerts when memory is critical
- **On-demand checks** - use `memory` command anytime to view current usage
- **Per-device metrics** - monitors each backend independently
- **Predictive estimation** - calculates expected cache size per token

**Technical Details:**

```cpp
// Configured in OpenVINOBackend::load_model()
config.KV_CACHE_PRECISION = "u8";  // INT8 quantization

// Device-specific optimizations
if (device == "NPU") {
    config.NPU_USE_NPUW = true;     // Weight unification
} else if (device.find("GPU") != std::string::npos) {
    config.GPU_ENABLE_SDPA_OPTIMIZATION = true;  // SDPA for attention
}
```

**Memory Savings Example:**
```
Model: Llama-3.1-8B-INT4
Context: 2048 tokens
Cache without INT8: ~512 MB
Cache with INT8: ~128 MB
Savings: 75% reduction
```

**Monitoring in Action:**
```
You [NPU]: Generate a long story...

[Generation output...]
[Time: 2.345 seconds]

⚠️ [Memory Warning] RAM usage > 90% - Type 'memory' for details

You [NPU]: memory

[KVCache Monitor] Memory Status:
  System RAM: 14720 / 16384 MB (89.8%)
  ⚠️  WARNING: Memory usage above 90%!
  ✅ INT8 KV-cache quantization is active (50-75% memory savings)
```

**Usage with Other Features:**
```powershell
# Full feature stack: server + routing + optimization
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct `
  --server `
  --port 8080 `
  --context-routing `
  --optimize-memory `
  --benchmark

# Speculative + memory optimization for long contexts
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct `
  --speculative `
  --draft-model ./models/Qwen2.5-0.5B-Instruct `
  --optimize-memory `
  --json 2> metrics.ndjson
```

**Notes:**
- INT8 quantization is always enabled with `--optimize-memory`
- Use the `memory` command during sessions to check current RAM/VRAM usage
- Automatic warnings appear after each generation when RAM > 90%
- Monitor memory usage via Task Manager → Performance → Memory/GPU
- Works seamlessly with heterogeneous device execution
- Provides 50-75% memory savings with negligible quality impact

---

#### Alternative: Manual Environment Setup

If you prefer to set up the environment manually:

```powershell
cd C:\Users\<YourUsername>\NPU_Project

# Activate venv
.\venv\Scripts\Activate.ps1

# Load OpenVINO environment
cmd /c "call C:\Users\<YourUsername>\Downloads\openvino_genai_windows_2026.0.0.0_x86_64\setupvars.bat"

# Run the executable
.\dist\npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --policy PERFORMANCE
```


In benchmark mode:
- Runs a 2-second test on each available device (CPU, GPU, NPU)
- Loads the model on **all** tested devices simultaneously
- Selects the best device based on measured TTFT and throughput
- Allows runtime device switching with the `switch [device]` command
- Shows instant throughput metrics after each generation

**Example Benchmark Output:**
```
[Scheduler] Starting device benchmarks (2 sec per device)...
[Scheduler] Testing CPU... TTFT: 535.354 ms, Throughput: 44.1819 tok/s
[Scheduler] Testing GPU... TTFT: 143.247 ms, Throughput: 54.5372 tok/s
[Scheduler] Testing NPU... TTFT: 268.961 ms, Throughput: 61.3961 tok/s

[Scheduler] Selecting best device based on benchmarks and policy...
  - CPU: score = 44.1819
  - GPU: score = 54.5372
  - NPU: score = 61.3961
[Scheduler] Selected: NPU (score: 61.3961)
```

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

### Interactive Commands

While the program is running, you can use these commands:

| Command | Description |
|---------|-------------|
| `help` | Display all available commands and flags |
| `exit` | Quit the program |
| `stats` | Show performance metrics (TTFT, TPOT, throughput) |
| `memory` | Show current RAM/VRAM usage (available with `--optimize-memory`) |
| `devices` | List all loaded devices and show which is active |
| `switch <device>` | Switch to a different device (CPU/GPU/NPU) |
| `auto` | Toggle automatic device switching on/off |

**Example:**
```
You [NPU]: memory

[KVCache Monitor] Memory Status:
  System RAM: 8240 / 16384 MB (50.3%)

You [NPU]: stats

OpenVINO GenAI Performance Metrics:
  - TTFT (Time to First Token): 124.531 ms
  - TPOT (Time per Output Token): 13.902 ms
  - Throughput: 71.942 tok/s
```

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
$OV = "C:\Users\$env:USERNAME\Downloads\openvino_genai_windows_2026.0.0.0_x86_64"
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
| **Memory Monitor Command** | `memory` shows current RAM/VRAM usage with `--optimize-memory` flag |
| **Automatic Memory Warnings** | Alerts when RAM > 90% after each generation (with `--optimize-memory`) |
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
        "C:/Users/ser13/Downloads/openvino_genai_windows_2026.0.0.0_x86_64/runtime/bin/intel64/Release"
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

**Cause:** Exit code `-1073741515` (or other errors) means OpenVINO DLLs are not found.

**Solution (Easiest):**
Use the `run.ps1` wrapper script which handles all environment setup:

```powershell
.\run.ps1 ./models/Qwen2.5-0.5B-Instruct --policy PERFORMANCE
```

Or if that doesn't work, run it step-by-step:

```powershell
# Step 1: Activate virtual environment
.\venv\Scripts\Activate.ps1

# Step 2: Load OpenVINO environment
cmd /c "call C:\Users\$env:USERNAME\Downloads\openvino_genai_windows_2026.0.0.0_x86_64\setupvars.bat"

# Step 3: Run the executable
.\dist\npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct
```

**Why this happens:**
- OpenVINO DLLs require environment variables set by `setupvars.bat`
- Python venv may be needed for implicit dependencies
- Running `.exe` alone without these setup steps will fail
- The `run.ps1` script automates all of this for you

### Error: "Could not find a model in the directory"

**Solution:**
- Check model path is correct: `./models/Qwen2.5-0.5B-Instruct/`
- Verify `openvino_model.xml` and `openvino_model.bin` exist in that folder
- Model folder must contain the full OpenVINO IR format (not just .gguf files)

### Error: "OpenVINO not found" during build

**Solution 1: Update build.ps1**
Edit `build.ps1` line 8 with the correct path:
```powershell
$OV = "C:\Users\<YourUsername>\Downloads\openvino_genai_windows_2026.0.0.0_x86_64"
```

**Solution 2: Update CMakeLists.txt**
Edit `CMakeLists.txt` lines 13-14:
```cmake
set(OpenVINO_DIR "C:/Users/<YourUsername>/Downloads/openvino_genai_windows_2026.0.0.0_x86_64/runtime/cmake")
set(OpenVINOGenAI_DIR "C:/Users/<YourUsername>/Downloads/openvino_genai_windows_2026.0.0.0_x86_64/runtime/cmake")
```

**Important:** Use forward slashes `/` in CMakeLists.txt, not backslashes `\`

### Error: "setupvars.bat not found" or missing runtime DLLs

**Cause:** You downloaded the PyPI package instead of the Archive Installation.

**How to check:**
```powershell
# Navigate to your OpenVINO folder
cd C:\Users\$env:USERNAME\Downloads\openvino_genai_windows_2026.0.0.0_x86_64

# Check for these files/folders:
ls setupvars.bat                    # Should exist at root
ls runtime\bin\intel64\Release\     # Should contain .dll files
ls runtime\cmake\                   # Should contain .cmake files
```

**Solution:**
1. Delete the existing OpenVINO folder
2. Go to [OpenVINO GenAI GitHub Releases](https://github.com/openvinotoolkit/openvino.genai/releases)
3. Download **Release 2026.0.0.0** - `openvino_genai_windows_2026.0.0.0_x86_64.zip`
4. Extract to `C:\Users\<YourUsername>\Downloads\`
5. Verify the folder structure matches above

**Note:** Don't use curl/wget commands from documentation as they may point to wrong versions (e.g., 2024.6.0.0 instead of 2026.0.0.0).

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

# Should show: openvino_genai_windows_2026.0.0.0_x86_64
# NOT: openvino_genai_windows_2024.6.0.0_x86_64 or other versions
```

**Solution:**
1. Delete the wrong version folder
2. Download the correct version from [GitHub Releases - 2026.0.0.0](https://github.com/openvinotoolkit/openvino.genai/releases/tag/2026.0.0.0)
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

### Server mode: curl command fails in PowerShell

**Symptoms:**
- Running `curl http://localhost:8080/...` returns errors or unexpected output
- Bash-style curl examples with `\` line continuations fail
- `-H` and `-d` flags not recognized

**Cause:** 
In PowerShell, `curl` is an alias for `Invoke-WebRequest`, not the real cURL binary. It doesn't support:
- Bash-style backslash `\` line continuation (PowerShell uses backtick `` ` ``)
- cURL flags like `-H`, `-d` (PowerShell uses different parameter names)
- Single quotes around JSON with double quotes inside

**Solutions:**

**Option 1: Use PowerShell native commands (Recommended)**
```powershell
$body = @'
{
  "model": "openvino-local",
  "messages": [
    {"role": "user", "content": "Hello!"}
  ],
  "max_tokens": 50
}
'@

Invoke-RestMethod -Uri "http://localhost:8080/v1/chat/completions" `
  -Method Post `
  -ContentType "application/json" `
  -Body $body
```

**Option 2: Use real cURL**
```powershell
# Use curl.exe explicitly (not the alias)
curl.exe http://localhost:8080/v1/chat/completions `
  -H "Content-Type: application/json" `
  -d '{"model":"openvino-local","messages":[{"role":"user","content":"Hello!"}],"max_tokens":50}'
```

**Key differences:**
- PowerShell: Here-string `@'...'@`, backtick `` ` `` for line continuation
- Bash: Backslash `\` for line continuation, single quotes preserve literals
- Always use `curl.exe` in PowerShell if you need real cURL behavior

### Server mode: API response shows empty content or `message=`

**Symptoms:**
When calling `Invoke-RestMethod` for `/v1/chat/completions`, you see:
```
choices : {@{finish_reason=stop; index=0; message=}}
usage   : @{completion_tokens=0; prompt_tokens=0; total_tokens=0}
```
The `message=` appears empty and no actual AI response text is visible.

**Cause:** 
PowerShell's default object formatter truncates nested properties. The content IS there, but PowerShell doesn't display it when showing the raw object.

**Solution:**
Always store the response and explicitly access the nested content:

```powershell
# Store the response
$response = Invoke-RestMethod -Uri "http://localhost:8080/v1/chat/completions" `
  -Method Post `
  -ContentType "application/json" `
  -Body $body

# Access the actual message content
$response.choices[0].message.content
```

Or as a one-liner:
```powershell
(Invoke-RestMethod http://localhost:8080/v1/chat/completions -Method Post -ContentType "application/json" -Body $body).choices[0].message.content
```

**To see the full JSON response:**
```powershell
$response | ConvertTo-Json -Depth 5
```

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
| `Stop-Process -Name "npu_wrapper" -Force` | Stop running server/process (when Ctrl+C doesn't work) |

---

## Versions

| Software | Version |
|----------|---------|
| Visual Studio Build Tools | 2022 (17.x) |
| CMake | 3.28+ |
| OpenVINO GenAI | 2026.0.0.0 |
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
