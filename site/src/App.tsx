import { Navigate, Route, Routes } from "react-router-dom";
import { Footer } from "./components/Footer";
import { Navbar } from "./components/Navbar";
import { ApiPage } from "./pages/ApiPage";
import { ArchitecturePage } from "./pages/ArchitecturePage";
import { CliPage } from "./pages/CliPage";
import { DocsPage } from "./pages/DocsPage";
import { FaqPage } from "./pages/FaqPage";
import { HomePage } from "./pages/HomePage";
import { ModelsPage } from "./pages/ModelsPage";
import { QuickStartPage } from "./pages/QuickStartPage";

export default function App() {
  return (
    <div className="min-h-screen bg-page text-slate-100">
      <Navbar />
      <main className="mx-auto max-w-6xl px-4 pb-20 pt-24 sm:px-6 lg:px-8">
        <Routes>
          <Route path="/" element={<HomePage />} />
          <Route path="/docs" element={<DocsPage />} />
          <Route path="/quick-start" element={<QuickStartPage />} />
          <Route path="/architecture" element={<ArchitecturePage />} />
          <Route path="/api" element={<ApiPage />} />
          <Route path="/cli" element={<CliPage />} />
          <Route path="/models" element={<ModelsPage />} />
          <Route path="/faq" element={<FaqPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>
      <Footer />
    </div>
  );
}
