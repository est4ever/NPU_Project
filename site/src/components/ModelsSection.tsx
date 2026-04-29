export function ModelsSection() {
  return (
    <section id="models" className="section-wrap">
      <h2 className="section-title">Models</h2>
      <div className="mt-6 space-y-3 text-slate-300">
        <p>AcouLM does not bundle model weights. You register model IDs and local paths in `registry/models_registry.json`.</p>
        <p>The built-in backend expects OpenVINO IR and supported GGUF through OpenVINO GenAI.</p>
        <p>External backend users can bring their own runtime and model format strategy while keeping the same AcouLM API surface.</p>
      </div>
    </section>
  );
}
