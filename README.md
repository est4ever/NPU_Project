# AcouLM

AcouLM is a local AI control plane for Windows:
- browser app shell (`app_shell/`)
- terminal client (`npu_cli.ps1`)
- first-time setup (`portable_setup.ps1`) — machine registries and optional Hub model download
- pluggable backends (`registry/backends_registry.json`)

You can run AcouLM with the built-in OpenVINO backend (`npu_wrapper`) or an external backend that supports the same API.

## User Prerequisites

### Hardware

- Windows 10/11 x64 machine
- CPU required
- Intel GPU/NPU optional (for accelerator paths with built-in backend)
- Enough RAM for your selected model size

### Software

- [Git for Windows](https://git-scm.com/download/win) (required for installer/clone flows)
- PowerShell (built into Windows)
- Optional: updated Intel GPU/NPU drivers when using accelerator devices
- Optional: [Hugging Face Hub CLI](https://huggingface.co/docs/huggingface_hub/guides/cli) (`hf` or `huggingface-cli`, from `pip install -U "huggingface_hub[cli]"`). Required for **partial** Hub downloads (non-empty file/pattern filter) in [First-time setup](#first-time-setup). Without the CLI, that path errors; with an empty filter, setup may fall back to `git clone` and pull the **entire** model repository (including `.git`).

### What AcouLM Does Not Bundle

- Model weights are not included in this repo
- External backends are not included (you provide them)

## New Computer Setup (3 Download Paths)

### Path A - App shell + bundled built-in runtime (recommended)

1. Install [Git for Windows](https://git-scm.com/download/win)
2. Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/est4ever/Loomis/main/install.ps1' -UseBasicParsing))) -ShellOnly"
```

3. Then:

```powershell
cd $env:USERPROFILE\Loomis
.\portable_setup.ps1
```

What this means:
- Installs AcouLM app shell + downloads the prebuilt runtime bundle from GitHub Releases
- Typically **no separate OpenVINO SDK install is required** for end users in this path
- Intel drivers are still recommended if you plan to use Intel GPU/NPU acceleration

### Path B - Shell-only install (external backend users)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/est4ever/Loomis/main/install.ps1' -UseBasicParsing))) -ShellOnly"
```

Then configure `registry\backends_registry.json` (`type: "external"`, valid `entrypoint`) and run `.\start_app.ps1`.

What this means:
- Installs only the AcouLM shell/control plane
- You bring your own backend/runtime
- No OpenVINO install is needed unless your chosen backend requires it
- `portable_setup.ps1` now skips built-in `dist\npu_wrapper.exe` checks when backend type is `external`

### Path C - Manual source download

1. Clone or download this repository.
2. Choose one:
   - Reference backend runtime: put `npu_wrapper.exe` + DLLs under `dist\`
   - External backend: configure `registry\backends_registry.json` with `type: "external"` and your `entrypoint`
3. Initialize with `.\portable_setup.ps1` (or copy `registry/*.example.json` to `registry/*.json`)
4. Launch with `.\start_app.ps1`

What this means:
- Most flexible path (you assemble runtime/backends yourself)
- If you use the built-in backend from source, developer dependencies may be required
- If you use external backend only, OpenVINO is optional (depends on that backend)

### Optional installer flags

Custom install folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/est4ever/Loomis/main/install.ps1' -UseBasicParsing))) -ShellOnly -InstallDir 'D:\AI\Loomis'"
```

Pin a specific release tag:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/est4ever/Loomis/main/install.ps1' -UseBasicParsing))) -ShellOnly -ReleaseTag v1.0.0"
```

### If scripts are blocked

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## First-time setup

The script **`portable_setup.ps1`** (repo root) initializes this machine. Run it once on a **new clone or new PC** before `.\start_app.ps1` (it also appears in [New Computer Setup](#new-computer-setup-3-download-paths) paths A and C). It:

- Creates or updates `registry/models_registry.json` and `registry/backends_registry.json` (or you can copy `registry/*.example.json` instead and skip much of the wizard).
- Optionally downloads model files from the Hugging Face Hub into `.\models\...` when you answer yes to the download prompt.
- If that download is **Hugging Face `.safetensors`** (not IR/GGUF), setup can run an **automatic OpenVINO IR export** via Optimum Intel (`Export-HfFolderToOpenVinoIR.ps1`), or you can run **`.\start_app.ps1 -AutoExportIr`** later to export the registry-selected HF folder and update the registry.

If you use a **non-empty** “Files/patterns” filter there (to fetch only some blobs, for example a single `.gguf`), install the **Hugging Face Hub CLI** first; see **User Prerequisites → Software**. For inference, the built-in stack uses **OpenVINO GenAI** with either **IR** (`.xml`) or a **supported `.gguf`** (see [Model Notes](#model-notes)).

## Daily Use

On a **new clone or new PC**, run `.\portable_setup.ps1` once before `.\start_app.ps1` so registries exist and paths are set. You still need **model weights** locally (not in this repository): OpenVINO **IR** and/or a **supported `.gguf`**, depending on your GenAI version; see [Model Notes](#model-notes) and [First-time setup](#first-time-setup).

Start stack:

```powershell
.\start_app.ps1
```

If the selected registry model path is a **HF checkpoint folder** (`.safetensors` only), `start_app.ps1` now attempts a one-shot **automatic HF -> IR export** by default for built-in backend users (via `Export-HfFolderToOpenVinoIR.ps1`) and updates the selected registry path on success. Export can fail for some multimodal or custom architectures.

If you want to override behavior:
- Force on: `.\start_app.ps1 -AutoExportIr` or `LOOMIS_AUTO_EXPORT_IR=1`
- Force off: `.\start_app.ps1 -NoAutoExportIr` or `LOOMIS_AUTO_EXPORT_IR=0`
- Auto-pick best model for this launch: `.\start_app.ps1 -AutoSelectBestModel` or `LOOMIS_AUTO_SELECT_MODEL=1` (heuristic prefers lower-overhead format + smaller model size among runnable/existing registry entries)
- Browser control panel: Control -> Status Cards -> **auto model select at launch** -> Save (persists in `registry/models_registry.json`; applies next stack launch)

`start_app.ps1` is the primary launcher for users (backend + app shell).

- App shell: `http://localhost:5173`
- API base (default): `http://localhost:8000/v1`

Chat from terminal:

```powershell
.\npu_cli.ps1
```

Shortcut command after running `.\portable_setup.ps1`:

```powershell
acoulm
```

This opens terminal chat by default (`.\npu_cli.ps1 -Command chat`).
`portable_setup.ps1` also installs a global `acoulm` launcher in `%USERPROFILE%\.local\bin`, so it works from any folder after opening a new terminal.
For backward compatibility, `loomis` is kept as an alias.

Interactive chat commands are intentionally minimal:
- `/status`
- `/exit`

One-shot chat:

```powershell
.\npu_cli.ps1 -Command chat -Arguments "hello"
```

Runtime control (device, policy, feature toggles, registry selection) is browser-first in `start_app.ps1` flow, via the app shell.

## Release Asset (for installer)

`install.ps1` expects this exact GitHub Release asset name:
- `loomis-dist-windows-x64.zip`

The zip must contain the contents of `dist\` at zip root.

Create/update from repo root:

```powershell
Compress-Archive -Path (Join-Path $PWD 'dist\*') -DestinationPath loomis-dist-windows-x64.zip -Force
```

Important: zip the contents of `dist\` directly at the archive root (not `dist\dist\...`).

After you populate `dist\` (or unpack a release zip), run `.\Generate-Sbom.ps1` to write a dated file list under `sbom\` (names and byte sizes of DLLs and other shipped files) for support and compliance notes.

## Persistence and Registries

Local runtime state is stored in:
- `registry/models_registry.json`
- `registry/backends_registry.json`

On fresh clone, either run `.\portable_setup.ps1` or copy:
- `registry/models_registry.example.json` -> `registry/models_registry.json`
- `registry/backends_registry.example.json` -> `registry/backends_registry.json`

These machine-specific `registry/*.json` files are intentionally not tracked in git.

Where users define runtime content:
- **Models:** `registry/models_registry.json` (model ids + paths)
- **Backends:** `registry/backends_registry.json` (backend ids + entrypoints)

Template files included:
- `registry/models_registry.example.json`
- `registry/backends_registry.example.json`

## Built-in vs External Backend

- `builtin`: usually `dist/npu_wrapper.exe`; `run.ps1` prepares OpenVINO env. **`start_app.ps1` only accepts model paths that `npu_wrapper` can load** (OpenVINO IR or supported GGUF); optional HF→IR export applies here.
- `external`: your own executable/script; must provide AcouLM API endpoints used by app shell and CLI. **`start_app.ps1` does not enforce OpenVINO layouts** — it checks that the registry path exists, then passes it to your entrypoint (HF `.safetensors`, ONNX, GGUF, etc. are your responsibility). Default `formats` on new external backends is `hf,safetensors,gguf,openvino` as documentation for integrators; adjust in `registry/backends_registry.json` if you want.

Where backends come from:
- Built-in backend runtime is delivered by the release zip (`loomis-dist-windows-x64.zip`)
- External backend is user-supplied and registered in `registry/backends_registry.json`

## Model Notes

- This repository does not ship model weights.
- Built-in backend loads **OpenVINO IR** folders (`.xml` + weights) or, with **recent OpenVINO GenAI (2025.2+)**, a **single `.gguf` path** or a folder that contains **exactly one** `.gguf` (preview; architecture and device limits apply).
- GGUF-only setups can work without a separate IR export when GenAI supports that file; if inference fails, export to IR or try another package.
- GenAI’s GGUF reader supports only **some** tensor/quant schemes (commonly **Q4_0, Q4_K_M, Q8_0, FP16**). **IQ2 / IQ3 / similar** GGUFs often fail at load with errors like `gguf_tensor_to_f16 failed` — use a **Q4_K_M** (or Q8_0) file from the same Hub repo, or IR.
- If `selected_model` points to a folder that is not runnable (no IR / no single GGUF), `start_app.ps1` may fall back to another runnable registry path.

Where models come from:
- Hugging Face model hub (or internal model storage)
- For built-in backend, supply OpenVINO IR or a GenAI-supported GGUF path before selecting in registry/app shell (IR is the most portable option across devices)
- Partial Hub download during setup (file/patterns prompt) needs the Hugging Face CLI; see **User Prerequisites → Software** and [First-time setup](#first-time-setup). Leave the filter **blank** to snapshot the **whole** repo (e.g. all `model.safetensors-*` shards). For a partial snapshot, use **comma-separated** Hub paths or globs (see `portable_setup.ps1` prompts for a sharded example).

## Troubleshooting

- **Model/backend seems to disappear after restart**
  - Launch via `.\start_app.ps1` / `.\run.ps1` so registry paths stay consistent.

- **CLI cannot connect**
  - Wait a few seconds (backend may be restarting), then retry.
  - Start stack again with `.\start_app.ps1`.
  - Check backend terminal output for bad entrypoint/path/runtime failures.
  - In interactive terminal mode, use `/status` and `/exit` only.

- **Built-in backend fails to start**
  - Confirm `dist/npu_wrapper.exe` exists.
  - Confirm OpenVINO runtime is available (bundled DLLs or valid `OPENVINO_GENAI_DIR`).
  - Rebuild with `.\build.ps1` if needed.

- **Model load failure**
  - Confirm selected model path exists: IR folder with `.xml`, or one `.gguf` / folder with a single `.gguf` if using GenAI GGUF loading.
  - Re-import/select model in app shell or update `registry/models_registry.json`.
- **GGUF: `gguf_tensor_to_f16 failed` or GenAI GGUF load error**
  - The file’s **quantization type** is likely unsupported (e.g. **IQ2_M**). Download a **Q4_K_M** or **Q8_0** GGUF from the same model family, or use an **OpenVINO IR** export instead.

## Security Automation

Secret scanning is enabled in CI via `.github/workflows/secret-scan.yml` (gitleaks on push/PR).

Local pre-commit protection:

1. Install gitleaks (example on Windows):
   ```powershell
   winget install gitleaks.gitleaks
   ```
2. Install the repo hook:
   ```powershell
   .\Install-PreCommitHook.ps1
   ```
3. Optional manual scan anytime:
   ```powershell
   .\Scan-Secrets.ps1
   ```

Runtime secrets/registries remain excluded from git:
- `.webui_secret_key`
- `registry/*.json` (except `registry/*.example.json`)

## Developer Docs

- `ARCHITECTURE.md`
- `API_CONTRACT_V1.md`
- `CLI_USAGE.md`
- `PUBLISH_GUIDE.md`

## Repo vs Release Contents

- **Repository:** source, scripts, docs, `app_shell`, `registry/*.example.json`
- **Releases:** optional runtime bundle zip (`loomis-dist-windows-x64.zip`)
- **Do not commit:** machine-specific `registry/*.json`, model files, build outputs

Release zips are for end users of the built-in backend; external-backend users can install with `-ShellOnly` and skip runtime zip distribution.

## License

MIT. See `LICENSE`.
