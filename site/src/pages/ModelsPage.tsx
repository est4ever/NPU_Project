import { ModelsSection } from "../components/ModelsSection";

export function ModelsPage() {
  return (
    <section className="section-wrap mt-0">
      <h1 className="section-title text-3xl">Models and Backends</h1>
      <p className="section-subtitle">Register local model paths, use built-in runtime formats, or attach external inference backends.</p>
      <div className="mt-8 rounded-xl border border-line bg-panel p-5">
        <ModelsSection showHeader={false} />
      </div>
    </section>
  );
}
