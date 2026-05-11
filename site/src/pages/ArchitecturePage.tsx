import { ArchitectureDiagram } from "../components/ArchitectureDiagram";
import { GlossaryTerm } from "../components/GlossaryTerm";
import { DocsLayout } from "../layout/DocsLayout";

export function ArchitecturePage() {
  return (
    <DocsLayout title="Architecture" subtitle="System map for app shell, terminal CLI, API surface, and runtime backends.">
      <ArchitectureDiagram compact />
      <p className="mt-6 text-sm text-slate-300">
        Browser app shell provides control and visibility, while terminal CLI handles chat, runtime, and policy operations through the same API surface.
        {" "}Key terms:{" "}
        <GlossaryTerm term="app shell" title="Browser control surface">The local browser UI served at localhost:5173.</GlossaryTerm>
        {", "}
        <GlossaryTerm term="backend" title="Inference runtime">The process that executes model inference behind AcouLM API endpoints.</GlossaryTerm>.
      </p>
    </DocsLayout>
  );
}
