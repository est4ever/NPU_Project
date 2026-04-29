import { apiEndpoints } from "../data/site";

export function ApiSection({ showHeader = true }: { showHeader?: boolean }) {
  return (
    <section id={showHeader ? "api" : undefined} className={showHeader ? "section-wrap" : ""}>
      {showHeader && <h2 className="section-title">API</h2>}
      {showHeader && <p className="section-subtitle">Chat stays conversation-focused while runtime controls live in dedicated CLI/API endpoints.</p>}
      <div className="mt-6 grid gap-3 sm:grid-cols-2">
        {apiEndpoints.map((endpoint) => (
          <div key={endpoint} className="rounded-lg border border-line bg-panel px-4 py-3 font-mono text-sm text-accent shadow-glow">{endpoint}</div>
        ))}
      </div>
    </section>
  );
}
