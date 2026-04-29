import { faqs } from "../data/site";

export function Faq() {
  return (
    <section id="faq" className="section-wrap">
      <h2 className="section-title">FAQ</h2>
      <div className="mt-6 space-y-3">
        {faqs.map((item) => (
          <details key={item.q} className="rounded-lg border border-line bg-panel p-4">
            <summary className="cursor-pointer font-semibold text-slate-100">{item.q}</summary>
            <p className="mt-2 text-sm text-slate-300">{item.a}</p>
          </details>
        ))}
      </div>
    </section>
  );
}
