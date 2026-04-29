export function ModelsSection({ showHeader = true }: { showHeader?: boolean }) {
  return (
    <section id={showHeader ? "models" : undefined} className={showHeader ? "section-wrap" : ""}>
      {showHeader && <h2 className="section-title">Models</h2>}
      <div className="mt-6 rounded-xl border border-line bg-panel p-5 text-slate-300">
        <ul className="space-y-3">
          <li>Models are <span className="font-semibold text-white">not included</span> in the repository.</li>
          <li>Users register local model paths in <code className="font-mono text-accent">registry/models_registry.json</code>.</li>
          <li>Built-in backend supports OpenVINO IR and supported GGUF via OpenVINO GenAI.</li>
          <li>External backends are supported through the same API contract.</li>
        </ul>
      </div>
    </section>
  );
}
