import { Navbar } from "./components/Navbar";
import { Hero } from "./components/Hero";
import { ArchitectureDiagram } from "./components/ArchitectureDiagram";
import { QuickStart } from "./components/QuickStart";
import { FeatureGrid } from "./components/FeatureGrid";
import { ApiSection } from "./components/ApiSection";
import { ModelsSection } from "./components/ModelsSection";
import { CliSection } from "./components/CliSection";
import { DeploymentSection } from "./components/DeploymentSection";
import { Faq } from "./components/Faq";
import { Footer } from "./components/Footer";

export default function App() {
  return (
    <div className="min-h-screen bg-page text-slate-100">
      <Navbar />
      <main className="mx-auto max-w-6xl px-4 pb-16 pt-24 sm:px-6 lg:px-8">
        <Hero />
        <QuickStart />
        <ArchitectureDiagram />
        <FeatureGrid />
        <ModelsSection />
        <ApiSection />
        <CliSection />
        <DeploymentSection />
        <Faq />
      </main>
      <Footer />
    </div>
  );
}
