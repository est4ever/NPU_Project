import { apiEndpoints } from "../data/site";

export function ApiSection() {
  return (
    <section id="api" className="section-wrap">
      <h2 className="section-title">API</h2>
      <p className="section-subtitle">Chat and runtime controls are intentionally separated: conversation endpoints remain focused while configuration lives in CLI/runtime endpoints.</p>
      <div className="mt-6 grid gap-3 sm:grid-cols-2">
        {apiEndpoints.map((endpoint) => (
          <div key={endpoint} className="rounded-lg border border-line bg-panel px-4 py-3 font-mono text-sm text-accent">{endpoint}</div>
        ))}
      </div>
    </section>
  );
}
