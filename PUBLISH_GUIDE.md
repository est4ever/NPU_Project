# Publishing NPU Companion — Step-by-Step Guide

## What Exists Already

| Artifact | Location | Status |
|---|---|---|
| Tauri config | `src-tauri/tauri.conf.json` | Done |
| App icons (all sizes) | `src-tauri/icons/` | Done |
| Build script | `tauri_build.ps1` | Done |
| C++ backend | `build/Release/npu_wrapper.exe` | Built via `build.ps1` |
| App shell UI | `app_shell/` | Done |
| Cargo project | `src-tauri/Cargo.toml` v0.1.0 | Done |

---

## Step 1: Prerequisites

Install these once per machine:

### A. Rust toolchain
```powershell
# Install from https://rustup.rs — then verify:
cargo --version
```

### B. Tauri CLI
```powershell
cargo install tauri-cli --version "^2"
# Verify:
cargo tauri --version
```

### C. WebView2 (Windows target)
- WebView2 is pre-installed on Windows 10/11 (version 1903+).
- If building for clean VMs, download installer from: https://developer.microsoft.com/en-us/microsoft-edge/webview2/

### D. Build the C++ backend first
```powershell
.\build.ps1
# Confirms presence of: build\Release\npu_wrapper.exe
```

---

## Step 2: Build the Desktop Installer

```powershell
.\tauri_build.ps1
```

This script:
1. Checks cargo, tauri-cli, and npu_wrapper.exe are present.
2. Copies `npu_wrapper.exe` next to the Tauri output.
3. Runs `cargo tauri build` to produce installers.

Output location:
```
src-tauri\target\release\bundle\
├── msi\    ← Windows MSI installer (for enterprise/AD deployment)
└── nsis\   ← NSIS installer (for direct/consumer distribution)
```

---

## Step 3: What the Packaged App Includes

- `NPU Companion.exe` — Tauri desktop shell wrapping the app_shell UI.
- `npu_wrapper.exe` — The C++ OpenVINO backend (copied by build script).
- WebView2 runtime — embedded via installer.

**Not bundled (users must have locally):**
- OpenVINO runtime DLLs (from `setupvars.bat`). Documented in README.
- Model files in `./models/`.

---

## Step 4: Test the Installer Locally

```powershell
# Install from NSIS output:
.\src-tauri\target\release\bundle\nsis\NPU Companion_0.1.0_x64-setup.exe

# Launch the installed app, verify:
# 1. App shell loads (no browser required).
# 2. Tauri badge appears in header ("Tauri desktop").
# 3. API connectivity badge shows after starting backend separately.
```

---

## Step 5: Pre-Publish Checklist

Before shipping to others:

- [ ] All preflight checks pass: `.\preflight_check.ps1`
- [ ] All daily cutover checks pass: `.\cutover_daily_check.ps1`
- [ ] 48h trial window completed (see `CUTOVER_READINESS.md`)
- [ ] Tested installer on a clean profile (no dev tools)
- [ ] `version` in `src-tauri/Cargo.toml` and `src-tauri/tauri.conf.json` match
- [ ] README has correct OpenVINO version and download link
- [ ] Known limitations documented below

---

## Step 6: Distribution Options

### Option A: Direct file share (internal pilot)
Share the `.exe` or `.msi` from `src-tauri\target\release\bundle\`.

### Option B: GitHub Releases
1. Tag the release: `git tag v0.1.0`
2. Push: `git push origin v0.1.0`
3. Create GitHub Release and attach the bundles from `bundle\msi\` and `bundle\nsis\`.

### Option C: Tauri Updater (future)
Tauri supports auto-updates via a signed update server. Requires code-signing and an update endpoint. Not configured yet — suitable for v0.2+.

---

## Known Limitations (v0.1.0)

- OpenVINO runtime must be installed separately on the user's machine (`setupvars.bat`).
- Models are not bundled — users download their own into `./models/`.
- `split-prefill` requires backend launched with `--benchmark` for multi-device mode.
- Model/backend registry changes require stack restart to take effect.
- App shell requires backend running separately (not auto-started in this version).

---

## Version Bump Workflow

Before each release:
1. Update `src-tauri/Cargo.toml` → `version = "x.y.z"`
2. Update `src-tauri/tauri.conf.json` → `"version": "x.y.z"`
3. Run `.\tauri_build.ps1`
4. Tag and release.
