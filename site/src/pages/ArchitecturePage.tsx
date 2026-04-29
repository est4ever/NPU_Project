import { ArchitectureDiagram } from "../components/ArchitectureDiagram";
import { DocsLayout } from "../layout/DocsLayout";

export function ArchitecturePage() {
  return (
    <DocsLayout title="Architecture" subtitle="AcouLM links browser UI and terminal CLI through a shared local API into built-in and external runtimes.">
      <ArchitectureDiagram compact />
    </DocsLayout>
  );
}
