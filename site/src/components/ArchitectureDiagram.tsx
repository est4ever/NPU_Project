import { ArrowRight, Binary, Cpu, Globe, Server, TerminalSquare, type LucideIcon } from "lucide-react";

function Node({
  title,
  subtitle,
  icon: Icon,
}: {
  title: string;
  subtitle: string;
  icon: LucideIcon;
}) {
  return (
    <article className="rounded-xl border border-line bg-[#0d1320] p-4 shadow-glow">
      <div className="flex items-start justify-between gap-3">
        <div className="inline-flex h-8 w-8 items-center justify-center rounded-lg border border-accent/35 bg-accent/10 text-accent">
          <Icon size={16} />
        </div>
        <span className="rounded-full border border-line bg-[#0a0f1a] px-2 py-1 font-mono text-[10px] text-slate-400">{subtitle}</span>
      </div>
      <p className="mt-3 text-sm font-semibold text-slate-100">{title}</p>
    </article>
  );
}

function FlowChip({
  from,
  to,
  tone = "cyan",
}: {
  from: string;
  to: string;
  tone?: "cyan" | "violet";
}) {
  const toneClass =
    tone === "violet"
      ? "border-violet-400/25 bg-violet-400/10 text-violet-200"
      : "border-accent/30 bg-accent/10 text-cyan-200";

  return (
    <div className={`inline-flex items-center gap-2 rounded-full border px-3 py-1.5 font-mono text-[11px] ${toneClass}`}>
      <span>{from}</span>
      <ArrowRight size={12} />
      <span>{to}</span>
    </div>
  );
}

export function ArchitectureDiagram({ compact = false }: { compact?: boolean }) {
  return (
    <section id={compact ? undefined : "architecture"} className={compact ? "" : "section-wrap"}>
      {!compact && <h2 className="section-title">Architecture</h2>}
      {!compact && (
        <p className="section-subtitle">
          Browser app shell and terminal CLI converge on one local API surface that routes to built-in or external backends.
        </p>
      )}
      <div className="mt-6 grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <Node title="Browser App Shell" subtitle="localhost:5173" icon={Globe} />
        <Node title="HTTP API" subtitle="localhost:8000/v1" icon={Server} />
        <Node title="Backend Runtime" subtitle="npu_wrapper / external" icon={Cpu} />
        <Node title="Terminal CLI" subtitle="npu_cli.ps1" icon={TerminalSquare} />
      </div>
      <svg viewBox="0 0 1000 210" className="mt-6 w-full" aria-label="AcouLM data flow diagram">
        <defs>
          <marker id="arrowhead-tech" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto">
            <polygon points="0,0 8,4 0,8" fill="#00d4ff" />
          </marker>
        </defs>
        <path d="M90 60 L390 60" stroke="#00d4ff" strokeWidth="2" markerEnd="url(#arrowhead-tech)" fill="none" />
        <path d="M430 60 L735 60" stroke="#00d4ff" strokeWidth="2" markerEnd="url(#arrowhead-tech)" fill="none" />
        <path d="M825 70 L825 150" stroke="#6f7cff" strokeWidth="2" markerEnd="url(#arrowhead-tech)" fill="none" />
        <path d="M90 155 L390 88" stroke="#6f7cff" strokeWidth="2" markerEnd="url(#arrowhead-tech)" fill="none" />

        <text x="195" y="44" fill="#8fa4bd" fontSize="13">Browser -&gt; API</text>
        <text x="548" y="44" fill="#8fa4bd" fontSize="13">API -&gt; Runtime</text>
        <text x="158" y="172" fill="#8fa4bd" fontSize="13">CLI -&gt; API</text>
      </svg>
      <div className="mt-4 flex flex-wrap items-center gap-2">
        <FlowChip from="Browser UI" to="API Layer" />
        <FlowChip from="API Layer" to="Runtime" />
        <FlowChip from="CLI" to="API" tone="violet" />
        <span className="inline-flex items-center gap-2 rounded-full border border-line bg-[#0a0f1a] px-3 py-1.5 font-mono text-[11px] text-slate-300">
          <Binary size={12} className="text-accent" />
          CPU | GPU | NPU
        </span>
      </div>
    </section>
  );
}
