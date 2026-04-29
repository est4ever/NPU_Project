import { Copy } from "lucide-react";
import { quickStartCommands } from "../data/site";

function CommandCard({ title, command }: { title: string; command: string }) {
  const copy = async () => {
    await navigator.clipboard.writeText(command);
  };

  return (
    <article className="rounded-xl border border-line bg-panel p-4">
      <div className="mb-3 flex items-center justify-between">
        <h3 className="font-semibold">{title}</h3>
        <button onClick={copy} className="inline-flex items-center gap-2 rounded border border-line px-2 py-1 text-xs text-slate-300 hover:border-accent hover:text-accent focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent" aria-label={`Copy ${title} command`}>
          <Copy size={14} /> Copy
        </button>
      </div>
      <pre className="overflow-x-auto rounded bg-black/40 p-3 font-mono text-xs text-accent">{command}</pre>
    </article>
  );
}

export function QuickStart() {
  return (
    <section id="quick-start" className="section-wrap">
      <h2 className="section-title">Quick Start</h2>
      <p className="section-subtitle">Install AcouLM, initialize local configuration, and launch browser + CLI workflows in minutes.</p>
      <div className="mt-6 grid gap-4 md:grid-cols-2">{quickStartCommands.map((item) => <CommandCard key={item.title} {...item} />)}</div>
    </section>
  );
}
