# Architecture: Chat vs. Configuration Control

## New Architecture (After Refactoring)

```
┌─────────────────────────────────────────────────────────────┐
│                         Terminal                             │
│                                                               │
│  npu_cli.ps1                                                 │
│  ├─ status                                                   │
│  ├─ switch GPU                                               │
│  ├─ policy PERFORMANCE                                       │
│  ├─ split-prefill on                                         │
│  ├─ metrics summary                                          │
│  └─ ... (all configuration commands)                         │
│                                                               │
└────────────────────────┬────────────────────────────────────┘
                         │
                         │ /v1/cli/* endpoints (JSON)
                         │
                    ┌────▼─────────┐
                    │  RestAPI     │
                    │  Server      │
                    │  Port 8000   │
                    └────┬─────────┘
                         ▲
                    ┌────┴──────┐
                    │            │
      ┌─── /v1/chat/completions (pure chat, no commands) ───┐
      │                                                       │
      │                                                       │
┌─────▼──────────────────────────────────────────────────────▼────┐
│                         OpenWebUI                                 │
│                     (Browser: localhost:8080)                     │
│                                                                   │
│  Chat Input: "What is machine learning?"  ──────┐               │
│                                                   │               │
│                                                   ▼               │
│                                            Model Response        │
│                                    "Machine learning is..."     │
│                                                                   │
│  Note: Commands like /status, /switch no longer work here!       │
│        Use terminal (.\npu_cli.ps1) for configuration instead    │
└───────────────────────────────────────────────────────────────────┘
```

## Previous Architecture (Before Refactoring)

```
┌──────────────────────────────────────────────────────────────┐
│                      OpenWebUI Chat                           │
│                                                               │
│  User: "/status"          ─────────┐                         │
│  User: "hello"                      │                         │
│  User: "/switch GPU"       ────────►│ Parsed as command        │
│  User: "/policy PERF"               │ or normal chat          │
│                                     │                         │
│  All commands and chat mixed! ◄─────┘                        │
│  (Confusing UX, hard to maintain)                            │
│                                                               │
└──────────────────────────────────────────────────────────────┘
      │
      │ Everything flows through /v1/chat/completions
      │
      ▼
   RestAPI ────► Backend (OpenVINO)
```

## Key Benefits of New Architecture

| Aspect | Before | After |
|--------|--------|-------|
| **Chat UX** | Confusing - mixed commands/chat | **Pure conversation** ✓ |
| **Configuration** | Lost in chat interface | **Dedicated CLI tool** ✓ |
| **API** | One endpoint handling everything | **Clean separation** ✓ |
| **Debuggability** | Hard to trace issues | **Clear flow** ✓ |
| **Performance Tuning** | Had to type in chat | **Dedicated terminal tool** ✓ |
| **API Compliance** | Non-standard command parsing | **Standard OpenAI format** ✓ |

## Workflow Changes

### Configuration (Terminal)

```powershell
# 1. Terminal commands for model configuration
.\npu_cli.ps1 -Command status
.\npu_cli.ps1 -Command policy -Arguments "PERFORMANCE"
.\npu_cli.ps1 -Command switch -Arguments "GPU"
.\npu_cli.ps1 -Command split-prefill -Arguments "on"
```

### Chat (OpenWebUI)

```
User: "Tell me about climate change"
Model: "Climate change refers to long-term shifts..."

User: "What are renewable energy sources?"
Model: "Renewable energy comes from natural sources..."

# No commands in chat - just conversation!
```

## API Endpoints

### Chat Endpoint (Pure)

```
POST /v1/chat/completions
Content-Type: application/json

{
  "model": "openvino",
  "messages": [
    {"role": "user", "content": "Tell me a joke"}
  ],
  "stream": false
}

Response: Standard OpenAI chat completion (no command interference)
```

### CLI Endpoints (Configuration)

```
GET /v1/cli/status
Response: {"policy": "PERFORMANCE", "active_device": "GPU", ...}

POST /v1/cli/device/switch
Body: {"device": "GPU"}
Response: {"new_active_device": "GPU", "success": true}

POST /v1/cli/policy
Body: {"policy": "PERFORMANCE"}
Response: {"new_policy": "PERFORMANCE", "success": true}

POST /v1/cli/feature/split-prefill
Body: {"enabled": true}
Response: {"feature": "split-prefill", "status": "enabled", ...}

POST /v1/cli/threshold
Body: {"threshold": 100}
Response: {"new_threshold": 100, ...}

GET /v1/cli/metrics?mode=last
Response: {...metrics data...}
```

## Implementation Details

### RestAPIServer Changes

1. **Removed from chat handler:**
   - Command parsing logic
   - All "/status", "/switch", "/policy" etc. command handlers
   - Mixed response types

2. **Added CLI endpoints:**
   - `/v1/cli/status` - System status
   - `/v1/cli/device/switch` - Device management
   - `/v1/cli/policy` - Policy settings
   - `/v1/cli/feature/{feature}` - Feature toggles
   - `/v1/cli/threshold` - Threshold configuration
   - `/v1/cli/metrics` - Metrics retrieval

3. **Chat handler now:**
   - Only generates text completion
   - Always calls backend's generate_output()
   - Returns standard OpenAI format
   - No special command handling

### CLI Tool (npu_cli.ps1)

- PowerShell wrapper around REST API
- User-friendly terminal interface
- All CLI endpoints use this tool
- Can be called from scripts or manually

## Migration Guide

If you were using commands in the OpenWebUI chat:

| Before | After |
|--------|-------|
| User types: `/status` in chat | `.\npu_cli.ps1 -Command status` in terminal |
| User types: `/switch GPU` in chat | `.\npu_cli.ps1 -Command switch -Arguments "GPU"` in terminal |
| User types: `/metrics summary` in chat | `.\npu_cli.ps1 -Command metrics -Arguments "summary"` in terminal |

## Next Steps

1. **Rebuild the project:**
   ```powershell
   .\build.ps1
   ```

2. **Start the stack:**
   ```powershell
   .\start_openwebui_stack.ps1
   ```

3. **Use terminal for configuration:**
   ```powershell
   .\npu_cli.ps1 -Command status
   ```

4. **Use OpenWebUI for chat:**
   - Open browser: http://localhost:8080
   - Start chatting (no commands!)

## Testing the New System

### Test 1: Pure Chat Works

```powershell
# Terminal
.\npu_cli.ps1 -Command status

# Browser (http://localhost:8080)
User: "What is AI?"
# Should get model response, not error
```

### Test 2: Configuration Via CLI

```powershell
# Terminal
.\npu_cli.ps1 -Command switch -Arguments "GPU"
.\npu_cli.ps1 -Command status  # Verify change

# Browser
User: "Talk about machine learning"
# Should use GPU now
```

### Test 3: No Commands in Chat

```
# Browser
User: "/status"
# Should send as chat prompt, not execute command
# Model will try to respond to "/status" as text
```

## Troubleshooting

**Q: Chat shows error when I type a command?**
A: That's expected! Commands are no longer in chat. Use `.\npu_cli.ps1` in terminal instead.

**Q: How do I check if my settings changed?**
A: Run `.\npu_cli.ps1 -Command status` in terminal to verify configuration.

**Q: Can I use the API directly?**
A: Yes! Use the `/v1/cli/*` endpoints with JSON payloads. See "API Endpoints" section above.
