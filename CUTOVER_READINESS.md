# App Shell Cutover Readiness (Day 10)

This runbook defines how to operate app-shell-only safely.

## Goal

Run app shell as the primary UI with daily validation checks and clear rollback criteria.

## Trial Setup

1. Start backend/API + app shell with one command:

  ```powershell
  .\start_app.ps1
  ```

2. Use app shell (`http://localhost:5173`) for normal chat and control actions.
3. In app shell, open **Cutover Readiness** panel and click **Start App-Only Trial**.
4. Run readiness and daily checks from terminal:

  ```powershell
  .\preflight_check.ps1
  .\cutover_daily_check.ps1
  ```

## Required Rule

Continue app-shell-only operation when all conditions are true:

- Streaming and non-streaming chat are both reliable in app shell.
- App shell supports all control actions currently used via `npu_cli.ps1`.
- No blocker bugs appear after at least 48 hours of normal use.
- Recovery path is validated (logs + status endpoints are enough to diagnose issues quickly).

## Control Actions Coverage

Use this checklist during the trial:

- Device switch (`/v1/cli/device/switch`)
- Policy change (`/v1/cli/policy`)
- Feature toggles (`json`, `split-prefill`, `context-routing`, `optimize-memory`) via instant checkbox updates
- Threshold update (`/v1/cli/threshold`)
- Metrics query (`/v1/cli/metrics`)
- Model registry list/import/select (`/v1/cli/model/*`)
- Backend registry list/add/select (`/v1/cli/backend/*`)

## Suggested Daily Verification

1. Send one non-streaming chat.
2. Send one streaming chat.
3. Toggle one feature checkbox on/off and verify status output updates.
4. Import/select a model entry and re-check status.
5. Add/select a backend entry and re-check status.
6. Validate `/v1/cli/status` and `/v1/health` responses.
7. Save the `cutover_daily_check.ps1` JSON report for each day of the trial window.

## Rollback Rule

If blocker issues appear, keep backend/API running, revert to scripted CLI operations (`npu_cli.ps1`) for critical control paths, fix blockers, and restart a fresh app-only trial window.

## Notes

- The app shell now includes a persistent cutover tracker with:
  - 48-hour timer
  - rule checklist
- State is persisted in browser local storage under `npu-app-shell.cutover-readiness.v1`.
- `split-prefill` validation should only be considered required when 2+ devices are loaded; otherwise the backend correctly returns `insufficient_devices`.
