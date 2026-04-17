# Loomis

Loomis is a local AI control plane for Windows:
- browser app shell (`app_shell/`)
- terminal client (`npu_cli.ps1`)
- pluggable backends (`registry/backends_registry.json`)

You can run Loomis with the built-in OpenVINO backend (`npu_wrapper`) or an external backend that supports the same API.

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

### What Loomis Does Not Bundle

- Model weights are not included in this repo
- External backends are not included (you provide them)

## New Computer Setup (3 Download Paths)

### Path A - App shell + bundled built-in runtime (recommended)

1. Install [Git for Windows](https://git-scm.com/download/win)
2. Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/est4ever/Loomis/main/install.ps1' -UseBasicParsing)))"
```

3. Then:

```powershell
cd $env:USERPROFILE\Loomis
.\portable_setup.ps1
```

What this means:
- Installs Loomis app shell + downloads the prebuilt runtime bundle from GitHub Releases
- Typically **no separate OpenVINO SDK install is required** for end users in this path
- Intel drivers are still recommended if you plan to use Intel GPU/NPU acceleration

### Path B - Shell-only install (external backend users)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/est4ever/Loomis/main/install.ps1' -UseBasicParsing))) -ShellOnly"
```

Then configure `registry\backends_registry.json` (`type: "external"`, valid `entrypoint`) and run `.\start_app.ps1`.

What this means:
- Installs only the Loomis shell/control plane
- You bring your own backend/runtime
- No OpenVINO install is needed unless your chosen backend requires it

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
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/est4ever/Loomis/main/install.ps1' -UseBasicParsing))) -InstallDir 'D:\AI\Loomis'"
```

Pin a specific release tag:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/est4ever/Loomis/main/install.ps1' -UseBasicParsing))) -ReleaseTag v1.0.0"
```

### If scripts are blocked

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## Daily Use

Start stack:

```powershell
.\start_app.ps1
```

`start_app.ps1` is the primary launcher for users (backend + app shell).

- App shell: `http://localhost:5173`
- API base (default): `http://localhost:8000/v1`

Chat from terminal:

```powershell
.\npu_cli.ps1
```

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

- `builtin`: usually `dist/npu_wrapper.exe`; `run.ps1` prepares OpenVINO env.
- `external`: your own executable/script; must provide Loomis API endpoints used by app shell and CLI.

Where backends come from:
- Built-in backend runtime is delivered by the release zip (`loomis-dist-windows-x64.zip`)
- External backend is user-supplied and registered in `registry/backends_registry.json`

## Model Notes

- This repository does not ship model weights.
- Built-in backend requires OpenVINO IR model folders (contain `.xml` + weights).
- GGUF entries may be tracked in registry, but are not directly runnable by `npu_wrapper` until converted/exported to IR.
- If `selected_model` points to a non-IR folder, `start_app.ps1` may fall back to another runnable IR path.

Where models come from:
- Hugging Face model hub (or internal model storage)
- For built-in backend, convert/export to OpenVINO IR before selecting in registry/app shell

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
  - Confirm selected model path exists and contains OpenVINO IR `.xml`.
  - Re-import/select model in app shell or update `registry/models_registry.json`.

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
