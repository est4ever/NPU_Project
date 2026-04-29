import { ApiSection } from "../components/ApiSection";

export function ApiPage() {
  return (
    <section className="section-wrap mt-0">
      <h1 className="section-title text-3xl">API Reference</h1>
      <p className="section-subtitle">OpenAI-style chat endpoint and runtime control endpoints exposed on localhost:8000/v1.</p>
      <div className="mt-8 rounded-xl border border-line bg-panel p-5">
        <ApiSection showHeader={false} />
      </div>
    </section>
  );
}
