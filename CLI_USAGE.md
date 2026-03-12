# NPU CLI - Model Control Terminal Interface

## Overview

The NPU CLI tool separates concerns: the **chat interface is now for conversations only**, and all **model configuration and control commands are handled through the terminal**.

This provides:
- **Pure chat experience** in OpenWebUI
- **Powerful terminal control** for model performance tuning
- **Clear separation** between chat and configuration

## Setup

The CLI tool is: `npu_cli.ps1`

### Basic Usage

```powershell
# Show help
.\npu_cli.ps1 -Command help

# View current configuration
.\npu_cli.ps1 -Command status

# Switch to a different device
.\npu_cli.ps1 -Command switch -Arguments "GPU"

# Set performance policy
.\npu_cli.ps1 -Command policy -Arguments "PERFORMANCE"

# Enable split prefill feature
.\npu_cli.ps1 -Command split-prefill -Arguments "on"
```

## Command Reference

### Informational Commands

View system status and configuration without making changes.

#### `help`
Shows all available commands and usage examples.
```powershell
.\npu_cli.ps1 -Command help
```

#### `status`
Displays all current settings and performance metrics in a concise summary.
```powershell
.\npu_cli.ps1 -Command status
```
**Output includes:**
- Active scheduling policy
- Current device
- Loaded devices list
- Feature toggle states (JSON, split-prefill, context-routing, optimize-memory)
- Performance metrics (TTFT, TPOT, throughput)

#### `health`
Quick server heartbeat check.
```powershell
.\npu_cli.ps1 -Command health
```

#### `stats`
Performance metrics only (TTFT, TPOT, throughput).
```powershell
.\npu_cli.ps1 -Command stats
```

#### `devices`
List all loaded devices and highlight the active one.
```powershell
.\npu_cli.ps1 -Command devices
```

#### `model`
Model manager command group.
```powershell
# List registered models
.\npu_cli.ps1 -Command model -Arguments "list"

# Import/register local model
.\npu_cli.ps1 -Command model -Arguments "import","qwen-local","./models/Qwen2.5-0.5B-Instruct","openvino"

# Select active model (applies on next stack restart)
.\npu_cli.ps1 -Command model -Arguments "select","qwen-local"

# Download from Hugging Face and register
.\npu_cli.ps1 -Command model -Arguments "download","Qwen/Qwen2.5-0.5B-Instruct","qwen-hf"
```

#### `backend`
Backend manager command group.
```powershell
# List registered backends
.\npu_cli.ps1 -Command backend -Arguments "list"

# Add/register backend
.\npu_cli.ps1 -Command backend -Arguments "add","onnxruntime","external","C:/tools/onnxruntime_runner.exe"

# Select backend (applies on next stack restart)
.\npu_cli.ps1 -Command backend -Arguments "select","onnxruntime"
```

#### `memory`
Alias for `status` in the current CLI build.
```powershell
.\npu_cli.ps1 -Command memory
```

### Device Management

#### `switch`
Change the active device for inference.
```powershell
.\npu_cli.ps1 -Command switch -Arguments "GPU"
.\npu_cli.ps1 -Command switch -Arguments "CPU"
.\npu_cli.ps1 -Command switch -Arguments "NPU"
```

#### `policy`
Set the scheduling/power policy for the backend.
```powershell
# Maximum performance
.\npu_cli.ps1 -Command policy -Arguments "PERFORMANCE"

# Power-efficient
.\npu_cli.ps1 -Command policy -Arguments "BATTERY_SAVER"

# Balanced (default)
.\npu_cli.ps1 -Command policy -Arguments "BALANCED"
```

### Feature Toggles

#### `json`
Enable/disable JSON metrics output mode.
```powershell
.\npu_cli.ps1 -Command json -Arguments "on"
.\npu_cli.ps1 -Command json -Arguments "off"
```

#### `split-prefill`
Toggle split prefill/decode routing by device (requires 2+ devices).
```powershell
# Enable: routes prefill to high-throughput device, decode to low-latency device
.\npu_cli.ps1 -Command split-prefill -Arguments "on"

# Disable: uses single device for all phases
.\npu_cli.ps1 -Command split-prefill -Arguments "off"
```

#### `context-routing`
Toggle context-aware device routing (intelligent device selection based on input).
```powershell
.\npu_cli.ps1 -Command context-routing -Arguments "on"
.\npu_cli.ps1 -Command context-routing -Arguments "off"
```

#### `optimize-memory`
Toggle INT8 KV-cache compression to reduce memory usage.
```powershell
.\npu_cli.ps1 -Command optimize-memory -Arguments "on"
.\npu_cli.ps1 -Command optimize-memory -Arguments "off"
```

### Advanced Configuration

#### `threshold`
Set the prefill token count threshold for split-prefill decisions.
```powershell
# If input has > 50 tokens, route to prefill device
.\npu_cli.ps1 -Command threshold -Arguments "50"
```

**Note:** Automatically sets low threshold to 80% of the high value.

### Model and Backend Registry

The CLI persists model/backend metadata in registry files:

- `registry/models_registry.json`
- `registry/backends_registry.json`

Notes:
- `model select` and `backend select` save selection for the next restart.
- Current running process may continue with already loaded model/backend until restart.
- `model download` uses `huggingface-cli` if installed, otherwise attempts `git clone` from Hugging Face.

### Metrics & Monitoring

#### `metrics`
Retrieve detailed performance metrics from NDJSON log.
```powershell
# Show latest metrics record
.\npu_cli.ps1 -Command metrics -Arguments "last"

# Show aggregate statistics across all records
.\npu_cli.ps1 -Command metrics -Arguments "summary"

# Clear the metrics log
.\npu_cli.ps1 -Command metrics -Arguments "clear"
```

## Use Case Examples

### Example 1: Performance Tuning

You want maximum performance for a real-time application:

```powershell
# Check current status
.\npu_cli.ps1 -Command status

# Switch to GPU if available
.\npu_cli.ps1 -Command switch -Arguments "GPU"

# Set performance policy
.\npu_cli.ps1 -Command policy -Arguments "PERFORMANCE"

# Check performance improved
.\npu_cli.ps1 -Command stats
```

### Example 2: Low-Latency Inference with Split Routing

Route prefill (high throughput) and decode (low latency) to different devices:

```powershell
# Check available devices
.\npu_cli.ps1 -Command devices

# Enable split-prefill (requires 2+ devices)
.\npu_cli.ps1 -Command split-prefill -Arguments "on"

# Adjust threshold for your use case (default is usually good)
.\npu_cli.ps1 -Command threshold -Arguments "100"

# Monitor performance
.\npu_cli.ps1 -Command metrics -Arguments "summary"
```

### Example 3: Power Efficiency

Minimize power consumption for edge/mobile deployment:

```powershell
# Use battery saver policy
.\npu_cli.ps1 -Command policy -Arguments "BATTERY_SAVER"

# Enable memory optimization
.\npu_cli.ps1 -Command optimize-memory -Arguments "on"

# Use NPU if available (more efficient than GPU/CPU)
.\npu_cli.ps1 -Command switch -Arguments "NPU"

# Check status
.\npu_cli.ps1 -Command status
```

### Example 4: Add and Switch Model

```powershell
# Register a local model folder
.\npu_cli.ps1 -Command model -Arguments "import","qwen-local","./models/Qwen2.5-0.5B-Instruct","openvino"

# Select it for next restart
.\npu_cli.ps1 -Command model -Arguments "select","qwen-local"

# Verify selection
.\npu_cli.ps1 -Command status
```

### Example 5: Add and Switch Backend

```powershell
# Register external backend entry
.\npu_cli.ps1 -Command backend -Arguments "add","onnxruntime","external","C:/tools/onnxruntime_runner.exe"

# Select backend for next restart
.\npu_cli.ps1 -Command backend -Arguments "select","onnxruntime"

# Verify selection
.\npu_cli.ps1 -Command status
```

## Chat Interface (Pure Conversation)

OpenWebUI is now purely for conversations. The following workflow applies:

1. **Start the stack:** `.\start_openwebui_stack.ps1`
2. **Configure model** via terminal: `.\npu_cli.ps1 -Command ...`
3. **Chat in browser** (no commands, just conversation)
4. **Adjust performance** back in terminal as needed

## API Details (For Integration)

The CLI tool communicates with the backend via HTTP endpoints. If you want to integrate with other tools:

```
GET  /v1/cli/status                    - Get all configuration
POST /v1/cli/device/switch             - {"device": "GPU"}
POST /v1/cli/policy                    - {"policy": "PERFORMANCE"}
POST /v1/cli/feature/{feature}         - {"enabled": true}
POST /v1/cli/threshold                 - {"threshold": 100}
GET  /v1/cli/metrics?mode=last         - Fetch metrics
GET  /v1/cli/model/list                - List model registry
POST /v1/cli/model/import              - {"id":"qwen-local","path":"./models/...","format":"openvino"}
POST /v1/cli/model/select              - {"id":"qwen-local"}
GET  /v1/cli/backend/list              - List backend registry
POST /v1/cli/backend/add               - {"id":"onnxruntime","type":"external","entrypoint":"C:/tools/onnxruntime_runner.exe"}
POST /v1/cli/backend/select            - {"id":"onnxruntime"}
```

## Troubleshooting

### "API call failed"
- Ensure the backend server is running: `.\start_openwebui_stack.ps1`
- Check the server is listening on port 8000 (or configured port)
- Verify firewall isn't blocking 127.0.0.1:8000

### "No active backend"
- Run the backend first
- Check device is properly loaded

### "Need at least 2 devices loaded"
- split-prefill requires multiple devices
- Check available devices: `.\npu_cli.ps1 -Command devices`

### Command takes long time to execute
- Some operations (device switching, model loading) may take several seconds
- Use appropriate timeout settings

## Quick Checks

```powershell
# Validate API and selections
.\npu_cli.ps1 -Command status

# Validate model/backend registries
.\npu_cli.ps1 -Command model -Arguments "list"
.\npu_cli.ps1 -Command backend -Arguments "list"

# If you changed model/backend selection, restart stack to apply
.\start_openwebui_stack.ps1
```
