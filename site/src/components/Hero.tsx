import { motion } from "framer-motion";
import { Link } from "react-router-dom";

const badges = ["Windows", "PowerShell", "OpenVINO", "CPU/GPU/NPU", "Local-first", "MIT"];

export function Hero() {
  return (
    <section id="top" className="py-12 sm:py-16">
      <div>
        <motion.p initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }} className="mb-4 font-mono text-sm text-accent">
          Local AI control plane for Windows
        </motion.p>
        <motion.h1 initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.05 }} className="text-balance text-4xl font-bold tracking-tight sm:text-6xl">
          Local AI, accelerated.
        </motion.h1>
        <motion.p initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.1 }} className="mt-5 max-w-3xl text-lg text-slate-300">
          AcouLM connects a browser UI, terminal CLI, and OpenAI-style API to local inference backends across CPU, GPU, and NPU.
        </motion.p>
        <div className="mt-8 flex flex-wrap gap-3">
          {badges.map((badge) => (
            <span key={badge} className="rounded-full border border-line bg-panel px-3 py-1 text-xs font-medium text-slate-200">{badge}</span>
          ))}
        </div>
        <div className="mt-8 flex flex-wrap gap-4">
          <Link to="/quick-start" className="rounded-md bg-accent px-5 py-2.5 font-semibold text-slate-900 transition hover:brightness-110">
            Quick Start
          </Link>
          <a href="https://github.com/est4ever/AcouLM" target="_blank" rel="noreferrer" className="rounded-md border border-accent/50 px-5 py-2.5 font-semibold text-accent transition hover:bg-accent/10">
            View GitHub
          </a>
        </div>
      </div>
    </section>
  );
}
