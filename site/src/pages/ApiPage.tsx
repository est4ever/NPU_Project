import { ApiSection } from "../components/ApiSection";
import { DocsLayout } from "../layout/DocsLayout";

export function ApiPage() {
  return (
    <DocsLayout title="API Reference" subtitle="Why this page exists: define the contract your backend or tooling must follow so runtime control stays predictable.">
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
