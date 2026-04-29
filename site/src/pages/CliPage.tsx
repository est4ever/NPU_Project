import { CliSection } from "../components/CliSection";
import { DocsLayout } from "../layout/DocsLayout";

export function CliPage() {
  return (
    <DocsLayout title="CLI Commands" subtitle="Terminal-first runtime control for status, device switching, policies, and diagnostics.">
      <CliSection showHeader={false} />
    </DocsLayout>
  );
}
