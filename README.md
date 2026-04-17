# Loomis

Unified local AI control plane for Windows:
- browser app shell (`app_shell/`)
- terminal client (`npu_cli.ps1`)
- pluggable backend registry (`registry/backends_registry.json`)

Loomis can run with the built-in OpenVINO backend (`npu_wrapper`) or with your own external backend, as long as it exposes the same API surface.

## Quick Start (Windows)

1. Open PowerShell in the project root.
2. First-time setup:
   - built-in backend: `.\portable_setup.ps1`
   - already configured: `.\start_app.ps1`
3. App shell opens at `http://localhost:5173`
4. API base is `http://localhost:8000/v1` by default.

If PowerShell blocks scripts:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## What Loomis Includes

- **App shell UI** for status, model/backend registry, device/policy, feature toggles, and metrics.
- **CLI** for terminal chat and control commands via `npu_cli.ps1`.
- **Registry-driven backend selection**:
  - `builtin` for `npu_wrapper`
  - `external` for your own server process

## Common Commands

### Start / Stop

```powershell
.\start_app.ps1
```

### Terminal Chat

```powershell
.\npu_cli.ps1 -Command chat -Arguments "hello"
.\npu_cli.ps1
```

### Runtime Control

```powershell
.\npu_cli.ps1 -Command status
.\npu_cli.ps1 -Command switch -Arguments "GPU"
.\npu_cli.ps1 -Command policy -Arguments "PERFORMANCE"
.\npu_cli.ps1 -Command load -Arguments "NPU"
.\npu_cli.ps1 -Command metrics -Arguments "last"
```

### Build (developers)

```powershell
.\build.ps1
```

## Registries (Persistent Local State)

Loomis stores local selections in:
- `registry/models_registry.json`
- `registry/backends_registry.json`

On a fresh clone, copy templates or run setup:
- `registry/models_registry.example.json` -> `registry/models_registry.json`
- `registry/backends_registry.example.json` -> `registry/backends_registry.json`
- or run `.\portable_setup.ps1`

These files are intentionally not tracked in git because they contain machine-specific paths.

## Built-in vs External Backend

### Built-in (`npu_wrapper`)
- `type: "builtin"`
- typical `entrypoint`: `dist/npu_wrapper.exe`
- `run.ps1` sets up OpenVINO runtime automatically

### External
- `type: "external"`
- `entrypoint`: your executable/script
- backend must expose Loomis API endpoints (for app shell + CLI to work)

## Model Notes

- This repo does not ship model weights.
- For the built-in backend, selected model paths should point to **OpenVINO IR** folders (contain `.xml` + weights).
- GGUF entries can be kept for tracking but are not directly runnable by `npu_wrapper` until converted/exported to IR.

## Troubleshooting

### 1) Added models/backends disappear after restart

Use project launch scripts (`.\start_app.ps1`, `.\run.ps1`) so registry paths resolve consistently from project root.

### 2) CLI cannot connect

- Backend may still be starting/restarting
- Wait a few seconds and retry
- Run `.\start_app.ps1`
- Check backend terminal output for bad entrypoint/path/runtime errors

### 3) Built-in backend fails to start

- Verify `dist/npu_wrapper.exe` exists
- Verify OpenVINO runtime is available (bundled `dist\` DLLs or valid `OPENVINO_GENAI_DIR`)
- Rebuild with `.\build.ps1` if needed

### 4) No model found / model load failure

- Confirm selected model path exists
- Confirm folder contains OpenVINO IR `.xml`
- Update `registry/models_registry.json` or re-import the model in the app shell

## Developer Notes

- Architecture and implementation details: `ARCHITECTURE.md`
- API contract details: `API_CONTRACT_V1.md`
- CLI behavior details: `CLI_USAGE.md`

## License

MIT. See `LICENSE`.
