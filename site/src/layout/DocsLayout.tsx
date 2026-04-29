import { Link, NavLink } from "react-router-dom";
import type { ReactNode } from "react";

const docsLinks = [
  { label: "Overview", to: "/docs" },
  { label: "Quick Start", to: "/quick-start" },
  { label: "Architecture", to: "/architecture" },
  { label: "API Reference", to: "/api" },
  { label: "CLI", to: "/cli" },
  { label: "Models", to: "/models" },
  { label: "FAQ", to: "/faq" },
];

export function DocsLayout({ title, subtitle, children }: { title: string; subtitle: string; children: ReactNode }) {
  return (
    <section className="section-wrap mt-0">
      <div className="grid gap-8 lg:grid-cols-[250px_minmax(0,1fr)]">
        <aside className="lg:sticky lg:top-24 lg:h-fit">
          <div className="rounded-xl border border-line bg-panel/70 p-4">
            <p className="mb-3 font-mono text-xs uppercase tracking-[0.16em] text-accent">// Docs</p>
            <nav className="space-y-1" aria-label="Documentation navigation">
              {docsLinks.map((item) => (
                <NavLink
                  key={item.to}
                  to={item.to}
                  end={item.to === "/docs"}
                  className={({ isActive }) =>
                    isActive
                      ? "block rounded-md bg-accent/10 px-3 py-2 text-sm font-medium text-accent"
                      : "block rounded-md px-3 py-2 text-sm text-slate-300 transition hover:bg-white/5 hover:text-white"
                  }
                >
                  {item.label}
                </NavLink>
              ))}
            </nav>
            <div className="mt-4 border-t border-line pt-4 text-xs text-slate-400">
              <a href="https://github.com/est4ever/AcouLM" target="_blank" rel="noreferrer" className="text-accent underline">
                GitHub
              </a>
              <span className="mx-2">|</span>
              <Link to="/" className="text-accent underline">
                Home
              </Link>
            </div>
          </div>
        </aside>

        <div>
          <h1 className="section-title text-3xl sm:text-4xl">{title}</h1>
          <p className="section-subtitle">{subtitle}</p>
          <div className="mt-8 rounded-xl border border-line bg-panel/80 p-6">{children}</div>
        </div>
      </div>
    </section>
  );
}
