import { QuickStart } from "../components/QuickStart";
import { DocsLayout } from "../layout/DocsLayout";

export function QuickStartPage() {
  return (
    <DocsLayout title="Quick Start" subtitle="Install AcouLM, run first-time setup, and launch the local stack.">
      <QuickStart showHeader={false} />
    </DocsLayout>
  );
}
