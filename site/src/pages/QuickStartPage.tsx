import { Link } from "react-router-dom";
import { QuickStart } from "../components/QuickStart";
import { DocsLayout } from "../layout/DocsLayout";

export function QuickStartPage() {
  return (
    <DocsLayout title="Quick Start" subtitle="Get from fresh clone to a live UI and healthy backend with the shortest runnable sequence.">
      <p className="mb-6 text-sm text-slate-400">
        After the stack is up, you can compare AcouLM feature toggles against a baseline using <code className="font-mono text-slate-200">.\benchmark_acoulm_toggle.ps1</code> or the app shell Control panel.{" "}
        <Link to="/#sample-benchmark" className="text-accent underline hover:brightness-110">
          Illustrative numbers from one sample run
        </Link>{" "}
        are on the home page.
      </p>
      <QuickStart showHeader={false} />
      <div className="mt-6 space-y-4">
        <div className="rounded-xl border border-line bg-black/50 p-4">
          <p className="mb-2 font-mono text-xs uppercase tracking-[0.18em] text-accent/90">Sanity check</p>
          <pre className="overflow-x-auto font-mono text-sm text-accent">Invoke-RestMethod http://localhost:8000/v1/health</pre>
        </div>
        <div className="rounded-xl border border-line bg-black/50 p-4">
          <p className="mb-2 font-mono text-xs uppercase tracking-[0.18em] text-accent/90">If scripts are blocked</p>
          <pre className="overflow-x-auto font-mono text-sm text-accent">Set-ExecutionPolicy -Scope CurrentUser RemoteSigned</pre>
        </div>
      </div>
    </DocsLayout>
  );
}
