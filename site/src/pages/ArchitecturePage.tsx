import { ArchitectureDiagram } from "../components/ArchitectureDiagram";

export function ArchitecturePage() {
  return (
    <section className="section-wrap mt-0">
      <h1 className="section-title text-3xl">Architecture</h1>
      <p className="section-subtitle">AcouLM links browser UI and terminal CLI through a shared local API into built-in and external runtimes.</p>
      <div className="mt-8 rounded-xl border border-line bg-panel p-5">
        <ArchitectureDiagram compact />
      </div>
    </section>
  );
}
