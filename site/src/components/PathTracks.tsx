import { Cpu, ExternalLink, Layers, TerminalSquare } from "lucide-react";

const paths = [
  {
    id: "Path A",
    title: "Reference Backend",
    tag: "OpenVINO / npu_wrapper",
    icon: Cpu,
    why: "Use this when you want the default AcouLM runtime path with local CPU/GPU/NPU routing where supported.",
    steps: [
      "Run install.ps1 from the repo",
      "Place OpenVINO IR model under %USERPROFILE%\\AcouLM\\models\\...",
      "Run .\\portable_setup.ps1, then .\\start_app.ps1",
    ],
  },
  {
    id: "Path B",
    title: "Shell Only",
    tag: "External backend",
    icon: Layers,
    why: "Use this when you already have your own inference server and only need AcouLM UI + CLI control plane.",
    steps: [
      "Install with -ShellOnly",
      "Copy registry/*.example.json to registry/*.json",
      "Set backend type to external and valid entrypoint",
    ],
  },
  {
    id: "Path C",
    title: "Manual / Developer",
    tag: "Source + release assets",
    icon: TerminalSquare,
    why: "Use this when you want full control over source, dist runtime contents, and custom local configuration.",
    steps: [
      "Clone repository",
      "Optionally unpack release zip into dist/",
      "Configure registry and run .\\start_app.ps1",
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
                <p className="mt-2 text-xs text-slate-400">See README paths A/B/C for full matrix, driver notes, and backend contract details.</p>
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
