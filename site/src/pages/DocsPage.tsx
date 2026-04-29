import { Link } from "react-router-dom";
import { DeploymentSection } from "../components/DeploymentSection";
import { DocsLayout } from "../layout/DocsLayout";

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
    <DocsLayout
      title="Documentation"
      subtitle="Focused technical pages for setup, architecture, runtime control, and local model operations."
    >
      <div className="grid gap-4 sm:grid-cols-2">
        {docsLinks.map((item) => (
          <Link key={item.to} to={item.to} className="rounded-xl border border-line bg-[#0d1320] p-5 transition hover:shadow-glow">
            <h2 className="text-lg font-semibold text-white">{item.title}</h2>
            <p className="mt-2 text-sm text-slate-400">{item.desc}</p>
          </Link>
        ))}
      </div>
      <DeploymentSection />
    </DocsLayout>
  );
}
