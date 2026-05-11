import { ApiSection } from "../components/ApiSection";
import { DocsLayout } from "../layout/DocsLayout";

export function ApiPage() {
  return (
    <DocsLayout title="API Reference" subtitle="Contract your backend or tooling must follow for predictable runtime control.">
      <ApiSection showHeader={false} />
      <p className="mt-6 text-sm text-slate-300">
        External backend note: your backend must implement the AcouLM API contract. See{" "}
        <a className="text-accent underline" href="https://github.com/est4ever/AcouLM/blob/main/API_CONTRACT_V1.md" target="_blank" rel="noreferrer">
          API_CONTRACT_V1.md
        </a>.
      </p>
    </DocsLayout>
  );
}
