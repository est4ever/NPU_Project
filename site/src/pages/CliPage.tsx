import { CliSection } from "../components/CliSection";

export function CliPage() {
  return (
    <section className="section-wrap mt-0">
      <h1 className="section-title text-3xl">CLI Commands</h1>
      <p className="section-subtitle">Terminal-first runtime control for status, device switching, policies, and diagnostics.</p>
      <div className="mt-8 rounded-xl border border-line bg-panel p-5">
        <CliSection showHeader={false} />
      </div>
    </section>
  );
}
