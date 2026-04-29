import { Copy } from "lucide-react";
import { cliCommands } from "../data/site";

export function CliSection({ showHeader = true }: { showHeader?: boolean }) {
  const copy = async (value: string) => navigator.clipboard.writeText(value);

  return (
    <section id={showHeader ? "cli" : undefined} className={showHeader ? "section-wrap" : ""}>
      {showHeader && <h2 className="section-title">CLI</h2>}
      <div className="mt-6 rounded-xl border border-line bg-black/50 p-4 shadow-glow">
        <div className="mb-4 flex items-center gap-2">
          <span className="h-2.5 w-2.5 rounded-full bg-red-400/80" />
          <span className="h-2.5 w-2.5 rounded-full bg-amber-300/80" />
          <span className="h-2.5 w-2.5 rounded-full bg-emerald-400/80" />
          <span className="ml-2 font-mono text-xs text-slate-400">PowerShell / npu_cli.ps1</span>
        </div>
        <div className="space-y-3">
        {cliCommands.map((cmd) => (
          <div key={cmd} className="flex items-center justify-between gap-3 rounded-lg border border-line bg-panel/60 px-4 py-3">
            <code className="overflow-x-auto font-mono text-xs text-accent sm:text-sm">{cmd}</code>
            <button onClick={() => copy(cmd)} className="shrink-0 rounded border border-line p-2 text-slate-300 hover:border-accent hover:text-accent focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent" aria-label="Copy CLI command">
              <Copy size={14} />
            </button>
          </div>
        ))}
        </div>
      </div>
    </section>
  );
}
