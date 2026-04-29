import { Copy } from "lucide-react";
import { cliCommands } from "../data/site";

export function CliSection() {
  const copy = async (value: string) => navigator.clipboard.writeText(value);

  return (
    <section id="cli" className="section-wrap">
      <h2 className="section-title">CLI</h2>
      <div className="mt-6 space-y-3">
        {cliCommands.map((cmd) => (
          <div key={cmd} className="flex items-center justify-between gap-3 rounded-lg border border-line bg-panel px-4 py-3">
            <code className="overflow-x-auto font-mono text-xs text-accent sm:text-sm">{cmd}</code>
            <button onClick={() => copy(cmd)} className="shrink-0 rounded border border-line p-2 text-slate-300 hover:border-accent hover:text-accent focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent" aria-label="Copy CLI command">
              <Copy size={14} />
            </button>
          </div>
        ))}
      </div>
    </section>
  );
}
