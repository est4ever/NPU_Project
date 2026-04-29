function Node({ title, subtitle }: { title: string; subtitle: string }) {
  return (
    <div className="rounded-lg border border-line bg-panel p-4 shadow-glow">
      <p className="text-sm font-semibold text-slate-100">{title}</p>
      <p className="mt-1 font-mono text-xs text-slate-400">{subtitle}</p>
    </div>
  );
}

export function ArchitectureDiagram() {
  return (
    <section id="architecture" className="section-wrap">
      <h2 className="section-title">Architecture</h2>
      <p className="section-subtitle">Browser and terminal clients share the same local HTTP surface and route into built-in or external backends.</p>
      <div className="mt-6 grid gap-4 lg:grid-cols-3">
        <Node title="Browser App Shell" subtitle="localhost:5173" />
        <Node title="HTTP API" subtitle="localhost:8000/v1" />
        <Node title="Backend Runtime" subtitle="npu_wrapper / external backend\nCPU / GPU / NPU" />
        <Node title="Terminal CLI" subtitle="npu_cli.ps1" />
      </div>
      <svg viewBox="0 0 1000 160" className="mt-6 w-full" aria-label="AcouLM data flow diagram">
        <path d="M120 50 L420 50" stroke="#20d7ff" strokeWidth="2" fill="none" />
        <path d="M580 50 L880 50" stroke="#20d7ff" strokeWidth="2" fill="none" />
        <path d="M120 120 L420 70" stroke="#4ba3ff" strokeWidth="2" fill="none" />
        <text x="240" y="40" fill="#9ca3af" fontSize="14">Browser -&gt; API</text>
        <text x="670" y="40" fill="#9ca3af" fontSize="14">API -&gt; Runtime</text>
        <text x="220" y="130" fill="#9ca3af" fontSize="14">CLI -&gt; API</text>
      </svg>
    </section>
  );
}
