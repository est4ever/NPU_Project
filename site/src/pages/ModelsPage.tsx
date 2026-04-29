import { ModelsSection } from "../components/ModelsSection";
import { DocsLayout } from "../layout/DocsLayout";

export function ModelsPage() {
  return (
    <DocsLayout title="Models and Backends" subtitle="Register local model paths, use built-in runtime formats, or attach external inference backends.">
      <ModelsSection showHeader={false} />
    </DocsLayout>
  );
}
