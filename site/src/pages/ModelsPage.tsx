import { ModelsSection } from "../components/ModelsSection";
import { GlossaryTerm } from "../components/GlossaryTerm";
import { DocsLayout } from "../layout/DocsLayout";

export function ModelsPage() {
  return (
    <DocsLayout title="Models and Backends" subtitle="Why this page exists: AcouLM does not ship model weights, so you need one reliable path to obtain models and one path to run them.">
      <ModelsSection showHeader={false} />
      <div className="mt-6 space-y-4 text-slate-300">
        <p>
          Quick test model source:{" "}
          <a className="text-accent underline" href="https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct" target="_blank" rel="noreferrer">
            Qwen2.5-0.5B-Instruct
          </a>
        </p>
        <div className="rounded-xl border border-line bg-black/50 p-4">
          <p className="mb-2 font-mono text-xs uppercase tracking-[0.18em] text-accent/90">OpenVINO IR export example</p>
          <pre className="overflow-x-auto font-mono text-sm text-accent">optimum-cli export openvino --model TinyLlama/TinyLlama-1.1B-Chat-v1.0 ./models/tinyllama-ov</pre>
        </div>
        <p className="text-sm">
          Optional tooling: <code className="font-mono text-accent">huggingface-cli</code> for downloading model artifacts. GGUF flow is optional and documented in README.
        </p>
        <p className="text-sm">
          Key term: <GlossaryTerm term="OpenVINO IR" title="OpenVINO Intermediate Representation">The model format used by the reference backend (typically .xml + .bin files).</GlossaryTerm>
        </p>
      </div>
    </DocsLayout>
  );
}
