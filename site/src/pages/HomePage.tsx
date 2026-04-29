import { Link } from "react-router-dom";
import { Hero } from "../components/Hero";
import { ArchitectureDiagram } from "../components/ArchitectureDiagram";
import { FeatureGrid } from "../components/FeatureGrid";
import { QuickStart } from "../components/QuickStart";

export function HomePage() {
  return (
    <>
      <Hero />
      <section className="section-wrap">
        <h2 className="section-title">Architecture Preview</h2>
        <p className="section-subtitle">Core local control-plane flow across app shell, API layer, and runtime backends.</p>
        <div className="mt-6 rounded-xl border border-line bg-panel/70 p-4">
          <ArchitectureDiagram compact />
        </div>
      </section>
      <section className="section-wrap">
        <h2 className="section-title">Quick Start Preview</h2>
        <p className="section-subtitle">Install and launch fast, then open full setup details in documentation.</p>
        <QuickStart limit={3} showHeader={false} />
      </section>
      <FeatureGrid />
      <section className="section-wrap rounded-xl border border-line bg-panel p-6">
        <h2 className="section-title">Read the Documentation</h2>
        <p className="section-subtitle">Use focused pages for installation, architecture details, API reference, CLI usage, and model/backend setup.</p>
        <div className="mt-6">
          <Link to="/docs" className="rounded-md bg-accent px-5 py-2.5 font-semibold text-slate-900 transition hover:brightness-110">
            Open Docs
          </Link>
        </div>
      </section>
    </>
  );
}
