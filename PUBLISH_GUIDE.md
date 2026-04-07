# Publishing NPU Companion (Browser + Terminal)

This project is now distributed as a local browser control panel plus terminal chat workflow.

## Runtime Model

- Browser control panel: `app_shell/`
- Backend API: `dist/npu_wrapper.exe` (started by scripts)
- Terminal chat/control: `npu_cli.ps1`

No desktop wrapper is required.

## Step 1: Prerequisites (per machine)

1. OpenVINO GenAI archive installed (contains `setupvars.bat`).
2. Visual Studio Build Tools 2022 + CMake (for building from source).
3. Python available (for serving `app_shell/`).

Optional but recommended:
- `huggingface-cli` for model downloads.

## Step 2: First-Run Setup Wizard

Run:

```powershell
.\portable_setup.ps1
```

Wizard actions:

1. Optional build step (`build.ps1`).
2. Choose backend (default OpenVINO or custom entrypoint).
3. Choose model source:
	- local model path, or
	- download from Hugging Face.
4. Writes:
	- `registry/models_registry.json`
	- `registry/backends_registry.json`
5. Optionally launches stack.

## Step 3: Daily Run Commands

Launch backend + browser panel:

```powershell
.\start_app.ps1
```

Then chat in terminal:

```powershell
.\npu_cli.ps1 -Command chat
```

One-shot chat:

```powershell
.\npu_cli.ps1 -Command chat -Arguments "hello"
```

## Step 4: Validation Checklist

1. API health:

```powershell
Invoke-RestMethod http://localhost:8000/health
```

2. Browser control panel opens at `http://localhost:5173`.
3. CLI chat returns assistant output in terminal.
4. Device control works:

```powershell
.\npu_cli.ps1 -Command policy -Arguments "PERFORMANCE"
.\npu_cli.ps1 -Command load -Arguments "GPU"
.\npu_cli.ps1 -Command switch -Arguments "GPU"
```

## Step 5: Publish From Source

For open-source distribution:

1. Push repo with scripts/docs.
2. Users clone and run `.\portable_setup.ps1`.
3. Users run `.\start_app.ps1` + `.\npu_cli.ps1 -Command chat`.

## Known Limits

1. OpenVINO runtime must still be installed locally.
2. Models are user-managed and not bundled by default.
3. `split-prefill` requires multi-device backend state.
