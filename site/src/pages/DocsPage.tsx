import { Link } from "react-router-dom";
import { DeploymentSection } from "../components/DeploymentSection";

const docsLinks = [
  { title: "Quick Start", to: "/quick-start", desc: "Installation, setup, and launch flow." },
  { title: "Architecture", to: "/architecture", desc: "System map and control-plane boundaries." },
  { title: "API", to: "/api", desc: "OpenAI-style and runtime endpoints." },
  { title: "CLI", to: "/cli", desc: "Terminal command interface and examples." },
  { title: "Models", to: "/models", desc: "Model registry and backend expectations." },
  { title: "FAQ", to: "/faq", desc: "Deployment and runtime clarifications." },
];

export function DocsPage() {
  return (
    <section className="section-wrap mt-0">
      <h1 className="section-title text-3xl">Documentation</h1>
      <p className="section-subtitle">Focused technical pages for setup, architecture, runtime control, and local model operations.</p>
      <div className="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {docsLinks.map((item) => (
          <Link key={item.to} to={item.to} className="rounded-xl border border-line bg-panel p-5 transition hover:shadow-glow">
            <h2 className="text-lg font-semibold text-white">{item.title}</h2>
            <p className="mt-2 text-sm text-slate-400">{item.desc}</p>
          </Link>
        ))}
      </div>
      <DeploymentSection />
    </section>
  );
}
