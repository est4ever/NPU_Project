# NPU_Project (OpenVINO GenAI C++)

A minimal C++ wrapper that runs an OpenVINO GenAI LLM pipeline (TinyLlama exported to OpenVINO IR).

## Project Layout

src/
main.cpp
models/
TinyLlama_ov/ # local model export (NOT tracked in git)
dist/ # optional portable bundle (NOT tracked in git)
CMakeLists.txt
.gitignore


## Prerequisites

- Windows + Visual Studio Build Tools (C++ toolchain)
- CMake
- OpenVINO GenAI Windows package (download/extract)
- A model exported to OpenVINO IR in: `models/TinyLlama_ov/`

## Build

```powershell
cmake -S . -B build
cmake --build build --config Release
$env:OV_ROOT="C:\path\to\openvino_genai_windows_2025.4.0.0_x86_64"
$env:PATH="$env:OV_ROOT\runtime\bin\intel64\Release;$env:OV_ROOT\runtime\3rdparty\tbb\bin;$env:PATH"

.\build\Release\npu_wrapper.exe
