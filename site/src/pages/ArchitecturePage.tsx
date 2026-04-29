import { ArchitectureDiagram } from "../components/ArchitectureDiagram";
import { GlossaryTerm } from "../components/GlossaryTerm";
import { DocsLayout } from "../layout/DocsLayout";

export function ArchitecturePage() {
  return (
    <DocsLayout title="Architecture" subtitle="Why this page exists: show exactly where chat happens and where runtime/device commands happen so users do not get lost.">
      <ArchitectureDiagram compact />
      <p className="mt-6 text-sm text-slate-300">
        Browser app shell handles chat UX, while terminal CLI handles runtime and policy operations through the same API surface.
        {" "}Key terms:{" "}
        <GlossaryTerm term="app shell" title="Browser control surface">The local browser UI served at localhost:5173.</GlossaryTerm>
        {", "}
        <GlossaryTerm term="backend" title="Inference runtime">The process that executes model inference behind AcouLM API endpoints.</GlossaryTerm>.
      </p>
    </DocsLayout>
  );
}
