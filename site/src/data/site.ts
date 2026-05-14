export const navItems = [
  { label: "Quick Start", href: "#quick-start" },
  { label: "Architecture", href: "#architecture" },
  { label: "API", href: "#api" },
  { label: "CLI", href: "#cli" },
  { label: "GitHub", href: "https://github.com/est4ever/AcouLM", external: true, cta: true },
];

export const quickStartCommands = [
  {
    title: "Install",
    command:
      "powershell -NoProfile -ExecutionPolicy Bypass -Command \"& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/est4ever/AcouLM/main/install.ps1' -UseBasicParsing))) -ShellOnly\"",
  },
  { title: "Setup", command: "cd $env:USERPROFILE\\AcouLM\n.\\portable_setup.ps1" },
  { title: "One command (daily use)", command: "acoulm" },
  { title: "Start (UI + API)", command: ".\\start_app.ps1" },
  { title: "Optional: persist performance mode", command: ".\\start_app.ps1 -PerformanceMode" },
  { title: "Feature A/B benchmark (PowerShell)", command: ".\\benchmark_acoulm_toggle.ps1" },
  { title: "Terminal Chat (direct)", command: ".\\npu_cli.ps1" },
  { title: "One-shot Chat", command: ".\\npu_cli.ps1 -Command chat -Arguments \"hello\"" },
];

export const apiEndpoints = [
  "GET /v1/health",
  "POST /v1/chat/completions",
  "POST /v1/cli/device/switch",
  "POST /v1/cli/policy",
  "GET /v1/cli/metrics",
];

export const cliCommands = [
  ".\\npu_cli.ps1 -Command status",
  ".\\npu_cli.ps1 -Command switch -Arguments \"GPU\"",
  ".\\npu_cli.ps1 -Command policy -Arguments \"PERFORMANCE\"",
  ".\\npu_cli.ps1 -Command metrics -Arguments \"summary\"",
  ".\\npu_cli.ps1 -Command model -Arguments \"list\"",
  ".\\npu_cli.ps1 -Command backend -Arguments \"list\"",
];

export const features = [
  {
    title: "Browser Control Plane",
    description: "Local dashboard for runtime status, policies, and model/backend orchestration.",
  },
  {
    title: "Terminal CLI",
    description: "Scriptable PowerShell interface for fast operations and low-friction control.",
  },
  {
    title: "OpenAI-compatible API",
    description: "Chat and runtime endpoints at localhost:8000/v1 with clear separation of concerns.",
  },
  {
    title: "Pluggable Backends",
    description: "Use built-in npu_wrapper or attach external backends through the same API contract.",
  },
  {
    title: "Model Registry",
    description: "Register and switch local model paths without modifying core runtime scripts.",
  },
  {
    title: "CPU / GPU / NPU Switching",
    description: "Route inference across available devices based on operational goals.",
  },
  {
    title: "OpenVINO + GGUF support",
    description: "Built-in runtime supports OpenVINO IR and supported GGUF via OpenVINO GenAI.",
  },
  {
    title: "Metrics & Diagnostics",
    description: "Track runtime health and latency signals for practical troubleshooting, including optional feature A/B benchmarks in the Control panel or via benchmark_acoulm_toggle.ps1.",
  },
];

export const faqs = [
  {
    q: "Why doesn't chat in the browser accept /status commands?",
    a: "Runtime and device operations are terminal-first in npu_cli.ps1 and CLI API endpoints. Use the browser app shell for status, visibility, and control panel workflows.",
  },
  {
    q: "Do I need an NPU to use AcouLM?",
    a: "No. CPU-only and other backend paths are supported. NPU/GPU acceleration depends on hardware, drivers, and backend support.",
  },
  {
    q: "Does AcouLM include model weights?",
    a: "No. AcouLM does not bundle model weights. You register local model paths in the model registry.",
  },
  {
    q: "Do I need OpenVINO installed?",
    a: "Not always. Built-in backend users typically use bundled runtime assets, while external backend users follow their own runtime requirements.",
  },
  {
    q: "Can I use an external backend?",
    a: "Yes. AcouLM supports external backends through the same API contract used by the built-in backend.",
  },
  {
    q: "What is the difference between app shell and CLI?",
    a: "The app shell provides browser-based control and visibility, while the CLI is optimized for terminal-first operation and scripting.",
  },
  {
    q: "Is AcouLM Windows-only?",
    a: "AcouLM is currently targeted at Windows for local control plane workflows.",
  },
];
