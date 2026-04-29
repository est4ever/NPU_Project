export function DeploymentSection() {
  return (
    <section className="section-wrap">
      <h2 className="section-title">Deployment</h2>
      <div className="mt-6 grid gap-4 md:grid-cols-2">
        <article className="rounded-xl border border-line bg-panel p-5">
          <h3 className="font-semibold text-accent">Option A: GitHub Pages (default)</h3>
          <p className="mt-2 text-slate-300">Deploy via GitHub Actions to <a className="underline" href="https://est4ever.github.io/AcouLM/" target="_blank" rel="noreferrer">https://est4ever.github.io/AcouLM/</a>.</p>
        </article>
        <article className="rounded-xl border border-line bg-panel p-5">
          <h3 className="font-semibold text-accent">Option B: Vercel free subdomain</h3>
          <p className="mt-2 text-slate-300">Deploy the static `site/` app to a free URL like <span className="font-mono">https://acoulm.vercel.app</span>. A `.ai` domain is paid and not required.</p>
        </article>
      </div>
    </section>
  );
}
