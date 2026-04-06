# API Contract V1

This document freezes the app-facing contract for chat and core runtime control APIs.

## Base URL

- Local: `http://localhost:8000`
- Versioned path prefix: `/v1`

## Error Schema (Unified)

All non-2xx responses in the endpoints below use:

```json
{
  "error": {
    "code": "string_code",
    "message": "Human-readable message",
    "details": {
      "optional": "context object"
    }
  }
}
```

Notes:
- `details` is optional.
- UI should render `error.message` and log `error.code` + `error.details`.

## 0) Health

### `GET /v1/health`

Success:

```json
{
  "status": "healthy",
  "backend": "GPU"
}
```

Notes:
- `/health` is also available as a compatibility alias with the same payload.
- This endpoint currently does not emit custom application error payloads.

## 1) Chat Completion

### `POST /v1/chat/completions`

Request:

```json
{
  "model": "openvino",
  "messages": [
    {"role": "user", "content": "Hello"}
  ],
  "stream": false,
  "temperature": 0.7,
  "max_tokens": 128
}
```

Success (non-streaming): OpenAI-style `chat.completion` JSON.

Success (streaming): `text/event-stream` with OpenAI-style chunk payloads and final `data: [DONE]`.

Notes:
- If a chat prompt is recognized as a CLI control command (for example `"/status"`), the assistant returns guidance text to use `npu_cli.ps1` instead of executing control actions in chat.

Error codes:
- `invalid_json` (400)
- `internal_error` (500)

## 2) CLI Status

### `GET /v1/cli/status`

Success response fields:
- `policy`
- `active_device`
- `devices`
- `json_output` (`"ON" | "OFF"`)
- `split_prefill` (`"ON" | "OFF"`)
- `context_routing` (`"ON" | "OFF"`)
- `optimize_memory` (`"ON" | "OFF"`)
- `ttft_ms`
- `tpot_ms`
- `throughput`
- `selected_model`
- `selected_backend`
- optional: `prefill_device`, `decode_device`, `threshold`

Error codes:
- `status_fetch_failed` (500)

## 3) Device Switch

### `POST /v1/cli/device/switch`

Request:

```json
{
  "device": "GPU"
}
```

Success:

```json
{
  "new_active_device": "GPU",
  "success": true
}
```

Notes:
- `success` is `false` when the requested device is not actually activated by the backend.

Error codes:
- `missing_device` (400)
- `device_switch_failed` (500)

## 4) Policy Update

### `POST /v1/cli/policy`

Request:

```json
{
  "policy": "PERFORMANCE"
}
```

Accepted policy strings are parsed by `string_to_policy(...)` in the runtime.

Success:

```json
{
  "new_policy": "PERFORMANCE",
  "success": true
}
```

Error codes:
- `missing_policy` (400)
- `policy_update_failed` (500)

## 5) Feature Toggle

### `POST /v1/cli/feature/{feature}`

Supported feature values:
- `json`
- `split-prefill`
- `context-routing`
- `optimize-memory`

Request:

```json
{
  "enabled": true
}
```

Notes:
- If `enabled` is omitted, server behavior defaults to `false`.

Success:

```json
{
  "feature": "split-prefill",
  "status": "enabled",
  "success": true
}
```

Error codes:
- `missing_feature` (400)
- `unknown_feature` (400)
- `insufficient_devices` (409)
- `feature_toggle_failed` (500)

## 6) Threshold Update

### `POST /v1/cli/threshold`

Request:

```json
{
  "threshold": 100
}
```

Success:

```json
{
  "new_threshold": 100,
  "low_threshold": 80,
  "success": true
}
```

Error codes:
- `invalid_threshold` (400)
- `threshold_update_failed` (500)

## 7) Metrics

### `GET /v1/cli/metrics?mode={last|summary|clear}`

Success (`mode=last`): latest metrics record object.

Success (`mode=summary`):

```json
{
  "record_count": 10,
  "avg_ttft_ms": 123.4,
  "avg_tpot_ms": 11.2,
  "avg_throughput": 25.9
}
```

Success (`mode=clear`):

```json
{
  "cleared": true,
  "files_removed": 1
}
```

Error codes:
- `metrics_not_found` (404)
- `invalid_mode` (400)
- `metrics_query_failed` (500)

## 8) Model Registry

### `GET /v1/cli/model/list`

Success:

```json
{
  "schema": 1,
  "selected_model": "openvino-local",
  "models": [
    {
      "id": "openvino-local",
      "path": "./models/Qwen2.5-0.5B-Instruct",
      "format": "openvino",
      "backend": "openvino",
      "status": "ready"
    }
  ]
}
```

Error codes:
- `model_list_failed` (500)

### `POST /v1/cli/model/import`

Request:

```json
{
  "id": "qwen-local",
  "path": "./models/Qwen2.5-0.5B-Instruct",
  "format": "openvino",
  "backend": "openvino",
  "status": "ready"
}
```

Required request fields:
- `id`
- `path`

Success:

```json
{
  "success": true,
  "updated": false,
  "id": "qwen-local",
  "note": "Model registered. Restart stack to load a newly selected model."
}
```

Error codes:
- `missing_required_fields` (400)
- `invalid_json` (400)
- `model_import_failed` (500)

### `POST /v1/cli/model/select`

Request:

```json
{
  "id": "qwen-local"
}
```

Success:

```json
{
  "success": true,
  "selected_model": "qwen-local",
  "note": "Selection saved. Restart stack to apply model change."
}
```

Error codes:
- `missing_id` (400)
- `model_not_found` (404)
- `invalid_json` (400)
- `model_select_failed` (500)

## 9) Backend Registry

### `GET /v1/cli/backend/list`

Success:

```json
{
  "schema": 1,
  "selected_backend": "openvino",
  "backends": [
    {
      "id": "openvino",
      "type": "builtin",
      "entrypoint": "dist/npu_wrapper.exe",
      "formats": ["openvino"],
      "status": "ready"
    }
  ]
}
```

Error codes:
- `backend_list_failed` (500)

### `POST /v1/cli/backend/add`

Request:

```json
{
  "id": "onnxruntime",
  "type": "external",
  "entrypoint": "C:/tools/onnxruntime_runner.exe",
  "formats": ["openvino"]
}
```

Required request fields:
- `id`
- `entrypoint`

Success:

```json
{
  "success": true,
  "updated": false,
  "id": "onnxruntime"
}
```

Error codes:
- `missing_required_fields` (400)
- `invalid_json` (400)
- `backend_add_failed` (500)

### `POST /v1/cli/backend/select`

Request:

```json
{
  "id": "onnxruntime"
}
```

Success:

```json
{
  "success": true,
  "selected_backend": "onnxruntime",
  "note": "Selection saved. Restart stack to apply backend change."
}
```

Error codes:
- `missing_id` (400)
- `backend_not_found` (404)
- `invalid_json` (400)
- `backend_select_failed` (500)
