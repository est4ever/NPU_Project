export const navItems = [
  { label: "Quick Start", href: "#quick-start" },
  { label: "Architecture", href: "#architecture" },
  { label: "Models", href: "#models" },
  { label: "API", href: "#api" },
  { label: "CLI", href: "#cli" },
  { label: "FAQ", href: "#faq" },
  { label: "GitHub", href: "https://github.com/est4ever/AcouLM", external: true },
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
  "GET /v1/cli/status",
  "POST /v1/cli/device/switch",
  "POST /v1/cli/policy",
  "GET /v1/cli/metrics",
  "GET /v1/cli/model/list",
  "GET /v1/cli/backend/list",
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
  "Browser control plane",
  "Terminal CLI",
  "OpenAI-style chat endpoint",
  "Pluggable backend registry",
  "Model registry",
  "CPU/GPU/NPU device control",
  "OpenVINO IR and supported GGUF workflows",
  "Metrics and diagnostics",
  "Local-first Windows deployment",
];

export const faqs = [
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
