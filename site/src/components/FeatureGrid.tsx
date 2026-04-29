import { Cpu, Gauge, LayoutDashboard, Link2, ListTree, MonitorCog, TerminalSquare } from "lucide-react";
import { features } from "../data/site";

const icons = [LayoutDashboard, TerminalSquare, Link2, ListTree, ListTree, Cpu, MonitorCog, Gauge, Cpu];

export function FeatureGrid() {
  return (
    <section className="section-wrap">
      <h2 className="section-title">Features</h2>
      <div className="mt-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {features.map((feature, i) => {
          const Icon = icons[i] ?? Cpu;
          return (
            <article key={feature} className="rounded-xl border border-line bg-panel p-4">
              <Icon className="mb-3 text-accent" size={18} />
              <h3 className="text-sm font-semibold text-slate-100">{feature}</h3>
            </article>
          );
        })}
      </div>
    </section>
  );
}
