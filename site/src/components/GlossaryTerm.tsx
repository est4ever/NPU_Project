import type { ReactNode } from "react";

export function GlossaryTerm({ term, title, children }: { term: string; title: string; children: ReactNode }) {
  return (
    <span className="group relative inline-flex cursor-help items-center border-b border-dotted border-accent/60 text-accent">
      {term}
      <span className="pointer-events-none absolute left-1/2 top-full z-20 mt-2 hidden w-64 -translate-x-1/2 rounded-lg border border-line bg-panel p-3 text-left text-xs text-slate-300 shadow-glow group-hover:block group-focus-within:block">
        <strong className="block text-white">{title}</strong>
        <span className="mt-1 block">{children}</span>
      </span>
    </span>
  );
}
