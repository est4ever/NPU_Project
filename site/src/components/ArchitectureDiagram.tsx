function Node({ title, subtitle }: { title: string; subtitle: string }) {
  return (
    <div className="rounded-xl border border-line bg-[#0d1320] p-4 shadow-glow">
      <p className="text-sm font-semibold text-slate-100">{title}</p>
      <p className="mt-1 whitespace-pre-line font-mono text-xs text-slate-400">{subtitle}</p>
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
        <Node title="Browser App Shell" subtitle="localhost:5173" />
        <Node title="HTTP API" subtitle="localhost:8000/v1" />
        <Node title="Backend Runtime" subtitle="npu_wrapper / external backend\nCPU / GPU / NPU" />
        <Node title="Terminal CLI" subtitle="npu_cli.ps1" />
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

        <text x="185" y="44" fill="#8fa4bd" fontSize="13">Browser UI -&gt; API Layer</text>
        <text x="515" y="44" fill="#8fa4bd" fontSize="13">API Layer -&gt; Runtime</text>
        <text x="130" y="172" fill="#8fa4bd" fontSize="13">CLI -&gt; API</text>
        <text x="748" y="173" fill="#8fa4bd" fontSize="13">CPU | GPU | NPU</text>
      </svg>
    </section>
  );
}
