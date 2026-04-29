import { Faq } from "../components/Faq";

export function FaqPage() {
  return (
    <section className="section-wrap mt-0">
      <h1 className="section-title text-3xl">FAQ</h1>
      <p className="section-subtitle">Common setup, deployment, and runtime questions for local-first operation.</p>
      <div className="mt-8 rounded-xl border border-line bg-panel p-5">
        <Faq showHeader={false} />
      </div>
    </section>
  );
}
