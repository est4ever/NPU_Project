# NPU_Project — OpenVINO GenAI LLM C++ Wrapper (Windows)

A minimal C++ CLI wrapper that runs **OpenVINO GenAI LLMs** (OpenVINO-exported models) with device selection (CPU / GPU / NPU) and automatic fallback.

> **Important:** This repo does **not** ship models. You export/download models locally into `models/`.

## What This Project Does

- Loads OpenVINO GenAI LLMs from folders like `./models/TinyLlama_ov`
- Auto-detects devices and prioritizes NPU when available (otherwise defaults to CPU)
- Lists all available devices (CPU, GPU, NPU) in output
- Interactive terminal-based prompting with automatic NPU→CPU fallback on error
- Real-time benchmarking: shows execution time after each generation
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

#### C. OpenVINO GenAI (2025.4.0.0)
1. Download from [GitHub Releases](https://github.com/openvinotoolkit/openvino.genai/releases)
2. Find: `openvino_genai_windows_2025.4.0.0_x86_64.zip`
3. Extract to: `C:\Users\<YourUsername>\Downloads\openvino_genai_windows_2025.4.0.0_x86_64\`

#### D. Python 3.10+ (for model conversion only)
1. Download from [python.org](https://www.python.org/downloads/)
2. **Important:** Check "Add Python to PATH"

### Step 2: Copy Project Files

Copy these from your source machine:
```
NPU_Project/
├── CMakeLists.txt
├── README.md
├── src/
│   └── main.cpp
└── .gitignore
```

**Do NOT copy:**
- `build/` → Auto-generated during compilation
- `dist/` → Auto-generated after build
- `runlog.txt` → Auto-deleted after successful runs
- Model folders → Download on your own

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

### Step 5: Configure OpenVINO (Optional)

The `build.ps1` script automatically detects OpenVINO if extracted to the default location:
- `C:\Users\<YourUsername>\Downloads\openvino_genai_windows_2025.4.0.0_x86_64\`
- `C:\Users\<YourUsername>\Downloads\openvino_genai_windows_2025.4.1.0_x86_64\`

If your OpenVINO is in a different location, set the environment variable before running build.ps1:
```powershell
$env:OPENVINO_GENAI_DIR = "C:\path\to\your\openvino_genai_windows_2025.4.0.0_x86_64"
.\build.ps1
```

---

## Getting Models

### Option A: Download Models

**TinyLlama (recommended for testing)**
- ~1.5B parameters, very fast
- Download from Hugging Face: [TinyLlama-1.1B-Chat-v1.0-ov](https://huggingface.co/Xenova/TinyLlama-1.1B-Chat-v1.0-ov)
- Extract to: `models/TinyLlama_ov/`

**Qwen 0.6B**
- ~0.6B parameters, extremely fast
- Download from: [Qwen2.5-0.5B-Instruct](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct)
- Extract to: `models/Qwen3_0.6B_ov/`

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

## How to Run

### Basic Usage

```powershell
cd C:\Users\<YourUsername>\NPU_Project

# Run with TinyLlama
.\dist\npu_wrapper.exe ./models/TinyLlama_ov

# Run with Qwen 0.6B
.\dist\npu_wrapper.exe ./models/Qwen3_0.6B_ov
```

### Expected Output

```
MAIN STARTED
Model dir: ./models/TinyLlama_ov
Available devices:
  - CPU
  - GPU
Device chosen: CPU

Running warm-up...
READY. Type prompt (exit to quit)

You: What is 2+2?
AI: 2 + 2 equals 4.
[Time: 1.234 seconds]

You: exit
```

**Features:**
1. Auto-selects best device (NPU > GPU > CPU)
2. Runs warm-up generation to stabilize performance
3. Shows execution time after each response: `[Time: X.XXX seconds]`
4. Auto-deletes `runlog.txt` on successful exit
5. Keeps `runlog.txt` if there's an error (for debugging)

---

## Rebuilding After Code Changes

### Using the Automated Script (Recommended)

**Use the included `build.ps1` script:**

```powershell
# Normal rebuild
.\build.ps1

# Clean rebuild (deletes and recreates build folder)
.\build.ps1 -Clean
```

The script automatically detects OpenVINO and compiles everything in one command. If OpenVINO is not found, it will show instructions on how to set `$env:OPENVINO_GENAI_DIR`.

### Manual Option: Step-by-Step

#### If you modify `src/main.cpp`:

```powershell
# First, ensure OpenVINO setupvars.bat has been run:
$OV = "$HOME\Downloads\openvino_genai_windows_2025.4.0.0_x86_64"
cmd /c "`"$OV\setupvars.bat`""

# Then build
cd C:\Users\<YourUsername>\NPU_Project
cmake --build build --config Release
```

#### If you modify `CMakeLists.txt` or change OpenVINO version:

```powershell
# First, ensure OpenVINO setupvars.bat has been run:
$OV = "$HOME\Downloads\openvino_genai_windows_2025.4.0.0_x86_64"
cmd /c "`"$OV\setupvars.bat`""

# Then reconfigure and build
cd C:\Users\<YourUsername>\NPU_Project
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

---

## Code Features & Configuration

### Built-in Features

**Your code includes these features (see `src/main.cpp`):**

| Feature | What It Does |
|---------|---|
| **Turn Marker Detection** | Auto-stops generation when model tries to start a new dialogue turn (detects `\nYou:`, `\nUser:`, `\nAI:`) |
| **Auto-Device Fallback** | If NPU fails, automatically retries on CPU |
| **Token Streaming** | Outputs tokens in real-time as they're generated |
| **Execution Benchmarking** | Shows timing for each generation: `[Time: X.XXX seconds]` |
| **Automatic Logging** | Logs all activity to `../runlog.txt` (auto-deleted on success, kept on error) |
| **Warm-up Run** | First generation runs silently with "Hello" prompt to stabilize device |
| **Exe Path Detection** | Can show executable location for debugging (see code comment) |

### Device Selection Logic

**The code implements this priority:**

1. Scan all available devices (CPU, GPU, NPU, etc.)
2. Print all detected devices
3. If **NPU found** → use NPU
4. If **NPU not found** → use CPU (even if GPU is available)

```cpp
// From src/main.cpp pick_device_and_print()
std::string chosen = "CPU";  // Default
for (const auto& d : devs) {
    if (d.find("NPU") != std::string::npos) {
        chosen = "NPU";  // Switch to NPU if found
    }
}
```

**Note:** GPU devices will be listed in output, but the selection logic doesn't explicitly branch on GPU. Primary goal is NPU support with CPU as reliable fallback.

### Known Issue in Usage Message

⚠️ **The executable has an incorrect model name in its help text:**

```cpp
// src/main.cpp line 48 (WRONG)
"Example: npu_wrapper.exe ./models/Qwen3_0_6B_ov"
                                       ^^^ underscore
```

Should be:
```
./models/Qwen3_0.6B_ov
                ^^ dot
```

**If you see the wrong example, ignore it.** Use the correct folder name with a dot: `Qwen3_0.6B_ov`

---

These values are in `src/main.cpp` and can be customized:

```cpp
// Line 75-76: Main generation settings
cfg.max_new_tokens = 128;      // Max tokens to generate per prompt
cfg.temperature = 0.7f;        // Creativity level (0.0 = deterministic, 1.0+ = creative)

// Line 76: CPU fallback uses lower token limit
cfg.max_new_tokens = 64;       // (only when NPU fails and falls back to CPU)
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
C++ code: std::filesystem::remove("../runlog.txt")
    ↓
runlog.txt automatically deleted
```

**Location:** Writes to `../runlog.txt` in project root (because exe runs from `dist/` folder)

**Code that handles this (src/main.cpp, end of main):**
```cpp
logline("=== RUN END ===");

// Delete the log file when done (success path only)
try {
    std::filesystem::remove("../runlog.txt");
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
├── dist/                           ← Runtime folder (AUTO-POPULATED)
│   ├── npu_wrapper.exe             ← Copied from build/Release/
│   ├── openvino*.dll               ← OpenVINO runtime libraries
│   ├── tbb*.dll                    ← Intel TBB threading libraries
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

### Automatic Exe Copy

After each build, `CMakeLists.txt` automatically copies the executable:

```cmake
add_custom_command(TARGET npu_wrapper POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy
        $<TARGET_FILE:npu_wrapper>
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

### Error: "Could not find a model in the directory"

**Solution:**
- Check model path is correct: `./models/ModelName_ov/`
- Verify `openvino_model.xml` exists in that folder
- Check for typos: `Qwen3_0.6B_ov` (not `Qwen3_0_6B_ov`)

### Error: "OpenVINO not found" during build

**Solution:**
- Verify OpenVINO path in `CMakeLists.txt` (lines 7-8):
  ```cmake
  set(OpenVINO_DIR "C:/Users/<YourUsername>/Downloads/openvino_genai_windows_2025.4.0.0_x86_64/runtime/cmake")
  ```
- Replace `<YourUsername>` with your actual Windows username

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
| `cmake --build build --config Release` | Rebuild after code changes |
| `.\dist\npu_wrapper.exe ./models/ModelName_ov` | Run a model |
| `.\venv\Scripts\Activate.ps1` | Activate Python virtual environment |
| `pip install optimum[openvino]` | Install model conversion tools |
| `optimum-cli export openvino --model <HF-ID> ./models/output` | Convert model to OpenVINO |
| `rm -r build` | Clean build directory |

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

## Support & Resources

- **OpenVINO Docs:** [docs.openvino.ai](https://docs.openvino.ai/)
- **Optimum Intel:** [huggingface.co/docs/optimum/intel](https://huggingface.co/docs/optimum/intel/index)
- **Hugging Face Models:** [huggingface.co/models](https://huggingface.co/models)

---

## License

This repository does **not** distribute model weights. You export/download models locally and must follow each model's license terms.
