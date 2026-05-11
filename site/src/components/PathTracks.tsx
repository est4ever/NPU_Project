import { Cpu, ExternalLink, Layers, TerminalSquare } from "lucide-react";

const paths = [
  {
    id: "Path A",
    title: "App shell + bundled built-in runtime (recommended)",
    tag: "Bundled runtime",
    icon: Cpu,
    why: "Recommended path for most users.",
    steps: [
      "Install Git for Windows.",
      "Run install.ps1 with -ShellOnly.",
      "Run: cd $env:USERPROFILE\\AcouLM; .\\portable_setup.ps1",
    ],
    details: [
      "Installs AcouLM app shell + downloads the prebuilt runtime bundle from GitHub Releases.",
      "Typically no separate OpenVINO SDK install is required for end users in this path.",
      "Intel drivers are still recommended for Intel GPU/NPU acceleration.",
    ],
  },
  {
    id: "Path B",
    title: "Shell-only install (external backend users)",
    tag: "External backend",
    icon: Layers,
    why: "Use this when you already have your own backend/runtime.",
    steps: [
      "Run install.ps1 with -ShellOnly.",
      "Configure registry\\backends_registry.json with type: external and a valid entrypoint.",
      "Run .\\start_app.ps1.",
    ],
    details: [
      "Installs only the AcouLM shell/control plane.",
      "You bring your own backend/runtime.",
      "No OpenVINO install is needed unless your chosen backend requires it.",
      "portable_setup.ps1 skips built-in dist\\npu_wrapper.exe checks when backend type is external.",
    ],
  },
  {
    id: "Path C",
    title: "Manual source download",
    tag: "Source + release assets",
    icon: TerminalSquare,
    why: "Most flexible path for source/developer workflows.",
    steps: [
      "Clone or download this repository.",
      "Choose one: put npu_wrapper.exe + DLLs under dist, or configure external backend entrypoint.",
      "Initialize with .\\portable_setup.ps1 (or copy registry/*.example.json to registry/*.json).",
      "Launch with .\\start_app.ps1.",
    ],
    details: [
      "Most flexible path (you assemble runtime/backends yourself).",
      "Built-in backend from source may require developer dependencies.",
      "If you use external backend only, OpenVINO is optional (depends on that backend).",
    ],
  },
];

export function PathTracks() {
  return (
    <section className="section-wrap">
      <p className="font-mono text-xs uppercase tracking-[0.2em] text-accent/90">// Choose your path</p>
      <h2 className="mt-2 text-4xl font-bold tracking-tight text-white">Three ways to run AcouLM</h2>
      <p className="section-subtitle">Pick the path that matches your setup. Every path ends at the same local browser UI and API surface.</p>
      <div className="mt-6 grid gap-4 lg:grid-cols-3">
        {paths.map((path) => {
          const Icon = path.icon;
          return (
            <article key={path.id} className="rounded-xl border border-line bg-panel/80 p-5 transition hover:shadow-glow">
              <div className="mb-4 flex items-center justify-between">
                <p className="text-sm font-medium text-slate-300">{path.id}</p>
                <span className="rounded-full border border-accent/30 px-2 py-1 font-mono text-[11px] text-accent">{path.tag}</span>
              </div>
              <h3 className="flex items-center gap-2 text-xl font-semibold text-white"><Icon size={18} className="text-accent" />{path.title}</h3>
              <p className="mt-2 text-sm leading-6 text-slate-400">{path.why}</p>
              <ol className="mt-4 space-y-2 text-sm text-slate-300">
                {path.steps.map((step) => (
                  <li key={step} className="flex gap-2"><span className="text-accent">-</span>{step}</li>
                ))}
              </ol>
              <details className="mt-4">
                <summary className="cursor-pointer text-sm text-accent">Details</summary>
                <ul className="mt-2 space-y-1 text-xs text-slate-400">
                  {path.details.map((detail) => (
                    <li key={detail}>- {detail}</li>
                  ))}
                </ul>
              </details>
            </article>
          );
        })}
      </div>
      <a href="https://github.com/est4ever/AcouLM/blob/main/API_CONTRACT_V1.md" target="_blank" rel="noreferrer" className="mt-4 inline-flex items-center gap-2 text-sm text-accent underline">
        API contract reference <ExternalLink size={14} />
      </a>
    </section>
  );
}
