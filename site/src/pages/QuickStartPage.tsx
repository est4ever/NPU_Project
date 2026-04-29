import { QuickStart } from "../components/QuickStart";
import { DocsLayout } from "../layout/DocsLayout";

export function QuickStartPage() {
  return (
    <DocsLayout title="Quick Start" subtitle="Why this page exists: get you from fresh clone to a live UI and healthy backend with the shortest runnable sequence.">
      <QuickStart showHeader={false} />
      <div className="mt-6 space-y-4">
        <div className="rounded-xl border border-line bg-black/50 p-4">
          <p className="mb-2 font-mono text-xs uppercase tracking-[0.18em] text-accent/90">Sanity check</p>
          <pre className="overflow-x-auto font-mono text-sm text-accent">Invoke-RestMethod http://localhost:8000/health</pre>
        </div>
        <div className="rounded-xl border border-line bg-black/50 p-4">
          <p className="mb-2 font-mono text-xs uppercase tracking-[0.18em] text-accent/90">If scripts are blocked</p>
          <pre className="overflow-x-auto font-mono text-sm text-accent">Set-ExecutionPolicy -Scope CurrentUser RemoteSigned</pre>
        </div>
      </div>
    </DocsLayout>
  );
}
