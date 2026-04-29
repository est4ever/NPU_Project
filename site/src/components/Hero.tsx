import { motion } from "framer-motion";
import { Link } from "react-router-dom";
import { ArchitectureDiagram } from "./ArchitectureDiagram";

const badges = ["v1.0", "Windows", "PowerShell", "CPU/GPU/NPU", "Local-first", "MIT"];

export function Hero() {
  return (
    <section id="top" className="py-10 sm:py-14">
      <div className="grid items-start gap-10 lg:grid-cols-[1.1fr_1fr]">
        <div>
          <motion.p initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} className="mb-5 font-mono text-xs uppercase tracking-[0.22em] text-accent/90">
            // Local AI control plane
          </motion.p>
          <motion.h1 initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.05 }} className="text-balance text-5xl font-black tracking-[-0.035em] sm:text-6xl lg:text-7xl">
            Local AI,
            <br />
            <span className="text-accent">orchestrated.</span>
          </motion.h1>
          <motion.p initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.1 }} className="mt-6 max-w-2xl text-xl leading-8 text-slate-300">
            AcouLM connects a browser UI, terminal CLI, and OpenAI-style API to local inference backends across CPU, GPU, and NPU.
          </motion.p>

          <div className="mt-8 flex flex-wrap gap-3">
            <Link to="/quick-start" className="rounded-md bg-accent px-5 py-2.5 font-semibold text-slate-900 transition hover:brightness-110">
              Quick Start
            </Link>
            <a href="https://github.com/est4ever/AcouLM" target="_blank" rel="noreferrer" className="rounded-md border border-accent/50 px-5 py-2.5 font-semibold text-accent transition hover:bg-accent/10">
              GitHub
            </a>
          </div>

          <div className="mt-8 flex flex-wrap gap-2">
            {badges.map((badge) => (
              <span key={badge} className="rounded-full border border-line bg-panel/80 px-3 py-1 text-[11px] font-medium uppercase tracking-wide text-slate-200">
                {badge}
              </span>
            ))}
          </div>
        </div>

        <div className="rounded-2xl border border-line bg-panel/80 p-5 shadow-glow">
          <p className="mb-4 font-mono text-xs uppercase tracking-[0.18em] text-accent/90">// System Architecture</p>
          <ArchitectureDiagram compact />
        </div>
      </div>
    </section>
  );
}
