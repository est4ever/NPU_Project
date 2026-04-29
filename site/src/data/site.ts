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
  { title: "Start", command: ".\\start_app.ps1" },
  { title: "Terminal Chat", command: ".\\npu_cli.ps1" },
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
    description: "Track runtime health and latency signals for practical troubleshooting.",
  },
];

export const faqs = [
  {
    q: "Why doesn't chat in the browser accept /status commands?",
    a: "Browser chat is for conversation. Runtime and device operations are intentionally terminal-first in npu_cli.ps1 and CLI API endpoints.",
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
    q: "Does it support GGUF?",
    a: "Yes. The built-in backend supports OpenVINO IR and supported GGUF through OpenVINO GenAI.",
  },
  {
    q: "Can I deploy this website without buying a domain?",
    a: "Yes. Use GitHub Pages at https://est4ever.github.io/AcouLM/ or a free Vercel subdomain. A .ai domain is paid and optional.",
  },
  {
    q: "Is AcouLM Windows-only?",
    a: "AcouLM is currently targeted at Windows for local control plane workflows.",
  },
];
