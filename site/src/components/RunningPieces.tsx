import { Activity, MonitorSmartphone, Server, TerminalSquare } from "lucide-react";

const pieces = [
  {
    title: "Browser App Shell",
    label: "localhost:5173",
    icon: MonitorSmartphone,
    desc: "Chat and status dashboard. Talks to the local API on port 8000.",
  },
  {
    title: "HTTP API",
    label: "localhost:8000/v1",
    icon: Server,
    desc: "Versioned REST surface for chat and runtime endpoints.",
  },
  {
    title: "Terminal CLI",
    label: "npu_cli.ps1",
    icon: TerminalSquare,
    desc: "Scriptable runtime control: status, policy, backend, and model actions.",
  },
];

export function RunningPieces() {
  return (
    <section className="section-wrap">
      <p className="font-mono text-xs uppercase tracking-[0.2em] text-accent/90">// What you are running</p>
      <h2 className="mt-2 text-4xl font-bold tracking-tight text-white">Three pieces, one API surface</h2>
      <div className="mt-6 grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        {pieces.map((piece) => {
          const Icon = piece.icon;
          return (
            <article key={piece.title} className="rounded-xl border border-line bg-panel/80 p-5 transition hover:shadow-glow">
              <p className="mb-3 inline-flex items-center gap-2 rounded-full border border-accent/30 px-2 py-1 font-mono text-[11px] text-accent">
                <Icon size={12} />
                {piece.label}
              </p>
              <h3 className="text-lg font-semibold text-white">{piece.title}</h3>
              <p className="mt-2 text-sm leading-6 text-slate-400">{piece.desc}</p>
            </article>
          );
        })}
      </div>
      <div className="mt-4 inline-flex items-center gap-2 font-mono text-xs text-slate-400">
        <Activity size={14} className="text-accent" /> Browser -&gt; API -&gt; Backend | Terminal -&gt; API
      </div>
    </section>
  );
}
