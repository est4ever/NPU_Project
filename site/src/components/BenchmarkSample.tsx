export function BenchmarkSample() {
  return (
    <section className="section-wrap rounded-xl border border-line bg-panel/80 p-7">
      <p className="font-mono text-xs uppercase tracking-[0.2em] text-accent/90">// Illustrative only</p>
      <h2 className="mt-2 section-title text-3xl">Sample feature A/B (local run)</h2>
      <p className="section-subtitle mt-2">
        One recorded run from a Windows machine with the built-in OpenVINO path and GPU policy, using the repo&apos;s{" "}
        <code className="rounded bg-slate-900/80 px-1.5 py-0.5 font-mono text-xs text-slate-200">benchmark_acoulm_toggle.ps1</code> harness
        (same prompt, <code className="font-mono text-xs">max_tokens=128</code>, four timed runs after one warmup). Your hardware, model, and drivers
        will differ; use the script or the Control panel button to measure on your PC.
      </p>
      <p className="mt-3 text-sm text-slate-400">
        In this sample, enabling <strong className="text-slate-200">split-prefill</strong> returned HTTP 409, so the &quot;AcouLM features&quot; side ran with{" "}
        <strong className="text-slate-200">context-routing</strong> and <strong className="text-slate-200">optimize-memory</strong> on (split-prefill fell back to off). The baseline turned those routing features off.
      </p>
      <div className="mt-6 overflow-x-auto rounded-lg border border-line">
        <table className="w-full min-w-[520px] text-left text-sm">
          <thead className="bg-slate-950/60 text-xs uppercase tracking-wide text-slate-400">
            <tr>
              <th className="px-4 py-3 font-semibold">Scenario</th>
              <th className="px-4 py-3 font-semibold">Avg wall (ms)</th>
              <th className="px-4 py-3 font-semibold">Avg TTFT (ms)</th>
              <th className="px-4 py-3 font-semibold">Avg TPOT (ms)</th>
              <th className="px-4 py-3 font-semibold">Avg TPS (status)</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-line text-slate-200">
            <tr className="bg-slate-900/30">
              <td className="px-4 py-3 font-medium">AcouLM features (as applied)</td>
              <td className="px-4 py-3 font-mono">20,821</td>
              <td className="px-4 py-3 font-mono">187</td>
              <td className="px-4 py-3 font-mono">162</td>
              <td className="px-4 py-3 font-mono">6.17</td>
            </tr>
            <tr>
              <td className="px-4 py-3 font-medium">Baseline single path</td>
              <td className="px-4 py-3 font-mono">21,705</td>
              <td className="px-4 py-3 font-mono">191</td>
              <td className="px-4 py-3 font-mono">169</td>
              <td className="px-4 py-3 font-mono">5.95</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p className="mt-4 text-xs text-slate-500">
        Source row: <code className="font-mono">benchmark_outputs/bench_summary_20260514-142010.json</code> in the repository. VRAM was not recorded (no NVIDIA sample path in that run).
      </p>
    </section>
  );
}
