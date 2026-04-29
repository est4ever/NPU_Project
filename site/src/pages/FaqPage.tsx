import { Faq } from "../components/Faq";
import { DocsLayout } from "../layout/DocsLayout";

export function FaqPage() {
  return (
    <DocsLayout title="FAQ" subtitle="Common setup, deployment, and runtime questions for local-first operation.">
      <Faq showHeader={false} />
    </DocsLayout>
  );
}
