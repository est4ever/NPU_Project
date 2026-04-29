import { Link } from "react-router-dom";
import { Hero } from "../components/Hero";
import { FeatureGrid } from "../components/FeatureGrid";
import { PathTracks } from "../components/PathTracks";
import { QuickStart } from "../components/QuickStart";
import { RunningPieces } from "../components/RunningPieces";

export function HomePage() {
  return (
    <>
      <Hero />
      <RunningPieces />
      <PathTracks />
      <section className="section-wrap">
        <p className="font-mono text-xs uppercase tracking-[0.2em] text-accent/90">// Zero to health-check</p>
        <h2 className="mt-2 section-title text-4xl">Smallest possible start</h2>
        <p className="section-subtitle">Why this exists: this is the minimum path from zero to "health OK" without long setup noise.</p>
        <QuickStart limit={3} showHeader={false} />
      </section>
      <FeatureGrid />
      <section className="section-wrap rounded-xl border border-line bg-panel/80 p-7">
        <p className="font-mono text-xs uppercase tracking-[0.2em] text-accent/90">// Documentation</p>
        <h2 className="mt-2 section-title">Move from quick setup to full control</h2>
        <p className="section-subtitle">Installation paths, architecture details, API reference, CLI commands, models, and FAQ are organized in dedicated pages.</p>
        <div className="mt-6">
          <Link to="/docs" className="rounded-md bg-accent px-5 py-2.5 font-semibold text-slate-900 transition hover:brightness-110">
            Full documentation
          </Link>
        </div>
      </section>
    </>
  );
}
