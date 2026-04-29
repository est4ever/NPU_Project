import { QuickStart } from "../components/QuickStart";

export function QuickStartPage() {
  return (
    <section className="section-wrap mt-0">
      <h1 className="section-title text-3xl">Quick Start</h1>
      <p className="section-subtitle">Install AcouLM, run first-time setup, and launch the local stack.</p>
      <div className="mt-8 rounded-xl border border-line bg-panel p-5">
        <QuickStart showHeader={false} />
      </div>
    </section>
  );
}
