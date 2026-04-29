import { ApiSection } from "../components/ApiSection";
import { DocsLayout } from "../layout/DocsLayout";

export function ApiPage() {
  return (
    <DocsLayout title="API Reference" subtitle="OpenAI-style chat endpoint and runtime control endpoints exposed on localhost:8000/v1.">
      <ApiSection showHeader={false} />
    </DocsLayout>
  );
}
