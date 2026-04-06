if (window.__NPU_APP_SHELL_LOADED__) {
  console.warn("[ui] app.js already loaded; skipping duplicate initialization");
} else {
  window.__NPU_APP_SHELL_LOADED__ = true;

  const el = (id) => document.getElementById(id);

  const HISTORY_KEY = "npu-app-shell.prompt-history.v1";
  const MAX_HISTORY_ITEMS = 20;

  const isTauri = () => typeof window.__TAURI__ !== "undefined";

  let activeChatAbortController = null;
  let healthPollTimer = null;
  let perfPollTimer = null;
  let isChatBusy = false;

  let modelRegistryCache = [];
  let backendRegistryCache = [];
  let registryView = "models";

  let statusCache = null;
  let metricsCache = null;
  let memoryCache = null;
  let memoryLiveTimer = null;
  let memoryLiveStopTimer = null;

  let lastDerivedMetrics = {
    ttft_ms: null,
    tpot_ms: null,
    throughput_tok_s: null,
    total_ms: null,
    completion_tokens: null,
    device: null,
  };

  let sparkPoints = [];
  let sparkMeta = [];    // parallel to sparkPoints: {ts, ramUsed, ramTotal}
  let sparkHoverIdx = -1;
  let sparkScaleMax = 20;
  let lastSparkSampleAt = 0;
  const SPARK_MAX = 48;

  let commandState = {
    open: false,
    selectedIndex: 0,
    filtered: [],
  };

  let activeView = "workspace";
  let selectedRegistryItem = null;
  let lastInferenceStats = {
    device: "-",
    tps: 0,
  };

  function nowStamp() {
    return new Date().toLocaleTimeString([], { hour12: false });
  }

  function setButtonBusy(id, busy, busyText = "Working...") {
    const button = el(id);
    if (!button) return;

    if (!button.dataset.originalText) {
      button.dataset.originalText = button.textContent;
    }

    button.disabled = busy;
    button.textContent = busy ? busyText : button.dataset.originalText;
  }

  function baseUrl() {
    return el("apiBase").value.replace(/\/$/, "");
  }

  function setApiBase(url) {
    const input = el("apiBase");
    if (!input) return;
    input.value = String(url || "").replace(/\/$/, "");
  }

  function defaultApiBase() {
    return "http://localhost:8000/v1";
  }

  function printJson(target, value) {
    if (!target) return;
    target.textContent = JSON.stringify(value, null, 2);
  }

  function appendText(target, value) {
    if (!target) return;
    target.textContent += value;
  }

  function normalizeOnOff(value) {
    return String(value || "").trim().toUpperCase() === "ON";
  }

  function normalizeDevice(value) {
    return String(value || "").trim().toUpperCase();
  }

  function estimateTokens(text) {
    const raw = String(text || "");
    const trimmed = raw.trim();
    if (!trimmed) return 0;
    const words = trimmed.split(/\s+/).filter(Boolean).length;
    if (words > 0) return Math.max(1, Math.ceil(words * 1.35));
    // Fallback for punctuation-heavy or fragment chunks.
    return Math.max(1, Math.ceil(raw.length / 4));
  }

  function setConnectionState(state, detail) {
    const badge = el("connBadge");
    if (!badge) return;

    badge.classList.remove("online", "offline", "checking");
    badge.classList.add(state);

    const suffix = detail ? ` - ${detail}` : "";
    if (state === "online") {
      badge.textContent = `API: online${suffix}`;
    } else if (state === "offline") {
      badge.textContent = `API: offline${suffix}`;
    } else {
      badge.textContent = "API: checking";
    }
  }

  function setChatBusy(nextBusy) {
    isChatBusy = nextBusy;
    const send = el("sendChat");
    const cancel = el("cancelChat");

    if (send) send.disabled = nextBusy;
    if (cancel) cancel.disabled = !nextBusy;
  }

  function addActivity(message, state = "ready") {
    const feed = el("activityFeed");
    if (!feed) return;

    const row = document.createElement("li");
    row.className = "activity-row";

    const nowMs = new Date();
    const time = document.createElement("span");
    time.className = "activity-time";
    time.textContent =
      nowMs.toLocaleTimeString([], { hour12: false }) +
      "." + String(nowMs.getMilliseconds()).padStart(3, "0");

    const dot = document.createElement("span");
    dot.className = `activity-state ${state}`;

    const text = document.createElement("span");
    text.className = "activity-text";
    text.textContent = message;

    row.appendChild(time);
    row.appendChild(dot);
    row.appendChild(text);

    // Memory chip — snapshot current RAM from last known poll
    const ramUsed  = memoryCache?.ram?.used_mb  ?? memoryCache?.used_mb;
    const ramTotal = memoryCache?.ram?.total_mb ?? memoryCache?.total_mb;
    if (ramUsed != null && ramUsed > 0) {
      const mem = document.createElement("span");
      mem.className = "activity-mem";
      mem.textContent = ramTotal
        ? `${Math.round(ramUsed)} / ${Math.round(ramTotal)} MB`
        : `${Math.round(ramUsed)} MB`;
      row.appendChild(mem);
    }

    feed.prepend(row);
    while (feed.children.length > 80) {
      feed.removeChild(feed.lastChild);
    }
  }

  async function tauriStartBackend() {
    if (!isTauri()) return;
    try {
      const status = await window.__TAURI__.core.invoke("start_backend");
      return status;
    } catch (err) {
      console.warn("[tauri] start_backend invoke failed:", err);
      throw err;
    }
  }

  async function waitForApiReady(maxMs = 30000) {
    const started = Date.now();
    while (Date.now() - started < maxMs) {
      try {
        await requestJson("/health", { method: "GET" });
        return true;
      } catch {
        // Keep retrying while backend warms up.
      }
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
    return false;
  }

  async function requestJson(path, options = {}, allowFallback = true) {
    const currentBase = baseUrl();
    try {
      const response = await fetch(`${currentBase}${path}`, {
        headers: { "Content-Type": "application/json" },
        ...options,
      });

      const payload = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new Error(payload?.error?.message || `HTTP ${response.status}`);
      }

      setConnectionState("online");
      return payload;
    } catch (err) {
      // If the configured API base is wrong, auto-heal to localhost backend once.
      const fallbackBase = defaultApiBase();
      if (allowFallback && currentBase !== fallbackBase) {
        setApiBase(fallbackBase);
        addActivity(`API base reset to ${fallbackBase}`, "busy");
        return requestJson(path, options, false);
      }
      setConnectionState("offline", "request failed");
      throw err;
    }
  }

  function featureSummary(status) {
    const labels = [
      `json=${status.json_output || "?"}`,
      `split-prefill=${status.split_prefill || "?"}`,
      `context-routing=${status.context_routing || "?"}`,
      `optimize-memory=${status.optimize_memory || "?"}`,
    ];
    return labels.join(" | ");
  }

  function realPositive(value) {
    const n = Number(value);
    return Number.isFinite(n) && n > 0 ? n : null;
  }

  function mergeMetricsWithDerived(payload) {
    const base = payload && typeof payload === "object" ? { ...payload } : {};
    if (base.record_count !== undefined) return base;

    const merged = { ...base };
    if (realPositive(merged.ttft_ms) === null) merged.ttft_ms = realPositive(lastDerivedMetrics.ttft_ms);
    if (realPositive(merged.tpot_ms) === null) merged.tpot_ms = realPositive(lastDerivedMetrics.tpot_ms);
    if (realPositive(merged.throughput_tok_s) === null) merged.throughput_tok_s = realPositive(lastDerivedMetrics.throughput_tok_s);
    if (realPositive(merged.total_ms) === null) merged.total_ms = realPositive(lastDerivedMetrics.total_ms);
    if (realPositive(merged.completion_tokens) === null) merged.completion_tokens = realPositive(lastDerivedMetrics.completion_tokens);
    if (!merged.device || merged.device === "-") merged.device = lastDerivedMetrics.device || statusCache?.active_device || "-";
    return merged;
  }

  function startMemoryLiveWindow(durationMs = 20000, intervalMs = 1000) {
    if (memoryLiveTimer) {
      clearInterval(memoryLiveTimer);
      memoryLiveTimer = null;
    }
    if (memoryLiveStopTimer) {
      clearTimeout(memoryLiveStopTimer);
      memoryLiveStopTimer = null;
    }

    memoryLiveTimer = setInterval(() => {
      fetchMemoryEvidence(true).catch(() => {
        // Ignore background memory polling errors.
      });
    }, intervalMs);

    memoryLiveStopTimer = setTimeout(() => {
      if (memoryLiveTimer) {
        clearInterval(memoryLiveTimer);
        memoryLiveTimer = null;
      }
      memoryLiveStopTimer = null;
    }, durationMs);
  }

  function splitPrefillEnabled() {
    const checkbox = document.querySelector(".feature-toggle[data-feature='split-prefill']");
    return checkbox ? checkbox.checked : false;
  }

  function updateThresholdControlState() {
    const enabled = splitPrefillEnabled();
    const thresholdInput = el("thresholdInput");
    if (thresholdInput) thresholdInput.disabled = !enabled;

    for (const button of document.querySelectorAll(".threshold-preset")) {
      button.disabled = !enabled;
    }
  }

  function validateThresholdInput() {
    const input = el("thresholdInput");
    const hint = el("thresholdHint");
    if (!input || !hint) return false;

    const raw = input.value.trim();
    const value = Number(raw);
    const splitEnabled = splitPrefillEnabled();

    if (!splitEnabled) {
      el("setThreshold").disabled = true;
      hint.textContent = "Enable split-prefill to edit threshold controls.";
      return false;
    }

    if (!raw || !Number.isInteger(value) || value <= 0) {
      el("setThreshold").disabled = true;
      hint.textContent = "Threshold must be a positive integer.";
      return false;
    }

    el("setThreshold").disabled = false;
    hint.textContent = `Low threshold auto-set to ${Math.max(1, Math.floor(value * 0.8))}.`;
    return true;
  }

  function applyThresholdPreset(value) {
    const input = el("thresholdInput");
    if (!input) return;
    input.value = String(value);
    validateThresholdInput();
  }

  function loadPromptHistory() {
    try {
      const raw = localStorage.getItem(HISTORY_KEY);
      if (!raw) return [];
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  }

  function savePromptHistory(items) {
    localStorage.setItem(HISTORY_KEY, JSON.stringify(items.slice(0, MAX_HISTORY_ITEMS)));
  }

  function renderPromptHistory() {
    const container = el("promptHistory");
    if (!container) return;

    const items = loadPromptHistory();
    if (!items.length) {
      container.innerHTML = "<li>No prompts yet.</li>";
      return;
    }

    container.innerHTML = "";
    for (const item of items) {
      const li = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.className = "ghost";
      button.textContent = item;
      button.addEventListener("click", () => {
        el("chatInput").value = item;
        el("chatInput").focus();
        updateContextEstimate();
      });
      li.appendChild(button);
      container.appendChild(li);
    }
  }

  function addPromptToHistory(prompt) {
    const normalized = String(prompt || "").trim();
    if (!normalized) return;

    const items = loadPromptHistory().filter((entry) => entry !== normalized);
    items.unshift(normalized);
    savePromptHistory(items);
    renderPromptHistory();
  }

  function clearPromptHistory() {
    localStorage.removeItem(HISTORY_KEY);
    renderPromptHistory();
    addActivity("Prompt history cleared", "ready");
  }

  function clearContextBuffer() {
    if (activeChatAbortController) {
      activeChatAbortController.abort();
    }
    const chatOut = el("chatOutput");
    const chatIn = el("chatInput");
    if (chatOut) chatOut.textContent = "";
    if (chatIn) chatIn.value = "";
    el("tpsValue").textContent = "0.0";
    updateContextEstimate();
    addActivity("Local chat buffer cleared", "ready");
  }

  function updateContextEstimate() {
    const input = el("chatInput");
    const slider = el("contextWindow");
    const fill = el("contextFill");
    const label = el("contextLabel");
    if (!input || !slider || !fill || !label) return;

    const minBudget = Number(slider.min || 0);
    const maxBudget = Number(slider.max || 8192);
    const rawBudget = Number(slider.value || 2048);
    const budget = Math.max(minBudget, Math.min(maxBudget, rawBudget));
    if (Number(slider.value) !== budget) {
      slider.value = String(budget);
    }
    const used = estimateTokens(input.value);
    const pct = Math.max(0, Math.min(100, (used / Math.max(1, budget)) * 100));
    const sliderPct = Math.max(0, Math.min(100, (budget / Math.max(1, maxBudget)) * 100));

    fill.style.width = `${sliderPct}%`;
    label.textContent = `${used} / ${budget} tokens`;

    const usageHint = el("contextUsageHint");
    if (usageHint) {
      usageHint.textContent = `Usage ${pct.toFixed(1)}% of budget. Slider now at ${budget} tokens.`;
    }

    if (sliderPct > 85) {
      fill.style.background = "linear-gradient(90deg, #d64553, #b22635)";
    } else if (sliderPct > 55) {
      fill.style.background = "linear-gradient(90deg, #e6a63f, #cc7f16)";
    } else {
      fill.style.background = "linear-gradient(90deg, #62b0ff, #2478e6)";
    }

    updateContextPresetState(budget);
  }

  function updateContextPresetState(budget) {
    for (const presetButton of document.querySelectorAll(".context-preset")) {
      const presetValue = Number(presetButton.dataset.value);
      presetButton.classList.toggle("active", Number.isFinite(presetValue) && presetValue === budget);
    }
  }

  function applyContextPreset(value) {
    const slider = el("contextWindow");
    if (!slider) return;
    slider.value = String(value);
    updateContextEstimate();
  }

  function setPrimaryView(nextView) {
    activeView = nextView;
    document.body.classList.remove("view-workspace", "view-control");
    document.body.classList.add(nextView === "control" ? "view-control" : "view-workspace");

    el("tabWorkspace")?.classList.toggle("active", nextView === "workspace");
    el("tabControl")?.classList.toggle("active", nextView === "control");
  }

  function setRuntimeStrip() {
    const requested = normalizeDevice(el("chatDeviceTarget")?.value || "AUTO") || "AUTO";
    const active = normalizeDevice(statusCache?.active_device || "-") || "-";
    const lastDevice = normalizeDevice(lastInferenceStats.device || "-") || "-";
    const lastTps = Number.isFinite(lastInferenceStats.tps) ? lastInferenceStats.tps.toFixed(1) : "0.0";
    const loadedDevices = Array.isArray(statusCache?.devices)
      ? statusCache.devices.map((d) => normalizeDevice(d)).filter(Boolean)
      : [];

    if (el("chatRequestedDevice")) el("chatRequestedDevice").textContent = requested;
    if (el("chatActiveDevice")) el("chatActiveDevice").textContent = active;
    if (el("chatLastDevice")) el("chatLastDevice").textContent = lastDevice;
    if (el("chatLastTps")) el("chatLastTps").textContent = lastTps;
    if (el("chatDeviceAvailability")) {
      el("chatDeviceAvailability").textContent = loadedDevices.length
        ? `Loaded devices: ${loadedDevices.join(", ")}`
        : "Loaded devices: (none)";
    }
  }

  // syncDeviceOptionsFromStatus: chatDeviceTarget never disables options —
  // any unloaded device will be auto-loaded on demand when selected.
  function syncDeviceOptionsFromStatus(status) {
    const loaded = Array.isArray(status?.devices)
      ? [...new Set(status.devices.map((d) => normalizeDevice(d)).filter(Boolean))]
      : [];

    const extras = loaded.filter((d) => !STANDARD_DEVICES.includes(d));
    const fullList = [...STANDARD_DEVICES, ...extras];

    function applyToSelect(selectId) {
      const node = el(selectId);
      if (!node) return;

      const previous = normalizeDevice(node.value || "");
      const next = (previous === "AUTO" || fullList.includes(previous)) ? previous : "AUTO";

      node.innerHTML = "";
      for (const item of fullList) {
        const option = document.createElement("option");
        option.value = item;
        const isLoaded = item === "AUTO" || loaded.includes(item);
        option.textContent = item;
        option.title = isLoaded ? `${item} (loaded)` : `${item} — will be loaded on first use`;
        node.appendChild(option);
      }

      node.value = next;
    }

    applyToSelect("chatDeviceTarget");
    applyToSelect("deviceSelect");
  }

  function syncChatModelOptions(selectedHint = "") {
    const modelSelect = el("chatModel");
    if (!modelSelect) return;

    const preferred = selectedHint || statusCache?.selected_model || modelSelect.value || "openvino";
    const items = modelRegistryCache.length
      ? modelRegistryCache.map((m) => m.id)
      : [preferred || "openvino"];

    const deduped = [...new Set(items.filter(Boolean))];
    modelSelect.innerHTML = "";

    for (const id of deduped) {
      const option = document.createElement("option");
      option.value = id;
      option.textContent = id;
      modelSelect.appendChild(option);
    }

    if (!deduped.includes(preferred)) {
      const fallback = document.createElement("option");
      fallback.value = preferred;
      fallback.textContent = preferred;
      modelSelect.appendChild(fallback);
    }

    modelSelect.value = preferred;
  }

  function badgeStateFromStatus(value, fallback = "ready") {
    const text = String(value || "").toLowerCase();
    if (!text) return fallback;
    if (text.includes("error") || text.includes("fail") || text.includes("offline")) return "error";
    if (text.includes("loading") || text.includes("busy") || text.includes("warm")) return "busy";
    return "ready";
  }

  function renderReadinessBar(status) {
    function setChip(id, text, level) {
      const chip = el(id);
      if (!chip) return;
      chip.textContent = text;
      chip.classList.remove("ok", "warn", "bad");
      if (level === "ready") chip.classList.add("ok");
      if (level === "busy") chip.classList.add("warn");
      if (level === "error") chip.classList.add("bad");
    }

    const devices = Array.isArray(status.devices) ? status.devices : [];
    const deviceCount = devices.length;
    const splitOn = normalizeOnOff(status.split_prefill);

    setChip("rDevice", `device: ${status.active_device || "?"}`, "ready");
    setChip("rPolicy", `policy: ${status.policy || "?"}`, "ready");
    setChip("rModel", `model: ${status.selected_model || "?"}`, status.selected_model ? "ready" : "busy");
    setChip("rBackend", `backend: ${status.selected_backend || "?"}`, status.selected_backend ? "ready" : "busy");
    setChip("rDevices", `loaded: ${deviceCount}`, deviceCount >= 1 ? "ready" : "error");

    if (splitOn) {
      setChip("rSplitPrefill", "split-prefill: on", deviceCount >= 2 ? "ready" : "busy");
    } else {
      setChip("rSplitPrefill", "split-prefill: off", "busy");
    }
  }

  function renderStatusCards(status) {
    const root = el("statusCards");
    if (!root) return;

    const cards = [
      {
        title: "Model",
        value: status?.selected_model || "(none)",
        state: status?.selected_model ? (isChatBusy ? "busy" : "ready") : "error",
      },
      {
        title: "Backend",
        value: status?.selected_backend || "(none)",
        state: status?.selected_backend ? (isChatBusy ? "busy" : "ready") : "error",
      },
      {
        title: "Device",
        value: status?.active_device || "(unknown)",
        state: status?.active_device ? (isChatBusy ? "busy" : "ready") : "error",
      },
      {
        title: "Policy",
        value: status?.policy || "(unknown)",
        state: status?.policy ? "ready" : "busy",
      },
    ];

    root.innerHTML = "";
    for (const card of cards) {
      const node = document.createElement("div");
      node.className = "status-card";
      node.innerHTML = `
        <div class="status-card-head">
          <span class="status-card-title">${card.title}</span>
          <span class="status-badge ${card.state}">${card.state}</span>
        </div>
        <div class="status-card-value">${card.value}</div>
      `;
      root.appendChild(node);
    }
  }

  function sampleToSpark(value, options = {}) {
    const now = Date.now();
    const force = !!options.force;
    if (!force && now - lastSparkSampleAt < 180) return;
    lastSparkSampleAt = now;

    const raw = Number.isFinite(value) ? Math.max(0, value) : 0;
    if (raw > sparkScaleMax * 0.95) {
      sparkScaleMax = Math.max(raw * 1.15, sparkScaleMax);
    } else {
      sparkScaleMax = Math.max(10, sparkScaleMax * 0.995);
    }

    const normalized = Math.max(0, Math.min(100, (raw / Math.max(1, sparkScaleMax)) * 100));
    const prev = sparkPoints.length ? sparkPoints[sparkPoints.length - 1] : normalized;
    const bounded = prev * 0.72 + normalized * 0.28;

    sparkPoints.push(bounded);
    const ram = (memoryCache?.ram && typeof memoryCache.ram === "object") ? memoryCache.ram : memoryCache || {};
    sparkMeta.push({
      ts: new Date(),
      ramUsed:  ram.used_mb  ?? memoryCache?.used_mb  ?? null,
      ramTotal: ram.total_mb ?? memoryCache?.total_mb ?? null,
      tps: raw,
    });
    while (sparkPoints.length > SPARK_MAX) sparkPoints.shift();
    while (sparkMeta.length   > SPARK_MAX) sparkMeta.shift();
    drawSparkline();
  }

  function _sparkRoundRect(ctx, x, y, rw, rh, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + rw - r, y);
    ctx.quadraticCurveTo(x + rw, y, x + rw, y + r);
    ctx.lineTo(x + rw, y + rh - r);
    ctx.quadraticCurveTo(x + rw, y + rh, x + rw - r, y + rh);
    ctx.lineTo(x + r, y + rh);
    ctx.quadraticCurveTo(x, y + rh, x, y + rh - r);
    ctx.lineTo(x, y + r);
    ctx.quadraticCurveTo(x, y, x + r, y);
    ctx.closePath();
  }

  function drawSparkline() {
    const canvas = el("npuSparkline");
    if (!canvas) return;

    const ctx = canvas.getContext("2d");
    const w = canvas.width;
    const h = canvas.height;

    ctx.clearRect(0, 0, w, h);

    // Grid lines
    ctx.strokeStyle = "rgba(36, 120, 230, 0.18)";
    ctx.lineWidth = 1;
    for (let i = 1; i < 4; i++) {
      const y = (h / 4) * i;
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(w, y);
      ctx.stroke();
    }

    if (!sparkPoints.length) return;

    // Filled area under curve
    ctx.beginPath();
    for (let i = 0; i < sparkPoints.length; i++) {
      const x = (i / Math.max(1, SPARK_MAX - 1)) * w;
      const y = h - (sparkPoints[i] / 100) * (h - 8) - 4;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    const lastX = ((sparkPoints.length - 1) / Math.max(1, SPARK_MAX - 1)) * w;
    ctx.lineTo(lastX, h);
    ctx.lineTo(0, h);
    ctx.closePath();
    ctx.fillStyle = "rgba(36, 120, 230, 0.08)";
    ctx.fill();

    // Line
    ctx.strokeStyle = "#2478e6";
    ctx.lineWidth = 2;
    ctx.beginPath();
    for (let i = 0; i < sparkPoints.length; i++) {
      const x = (i / Math.max(1, SPARK_MAX - 1)) * w;
      const y = h - (sparkPoints[i] / 100) * (h - 8) - 4;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();

    // Hover
    if (sparkHoverIdx >= 0 && sparkHoverIdx < sparkPoints.length) {
      const hi = sparkHoverIdx;
      const hx = (hi / Math.max(1, SPARK_MAX - 1)) * w;
      const hy = h - (sparkPoints[hi] / 100) * (h - 8) - 4;

      // Vertical guide
      ctx.beginPath();
      ctx.strokeStyle = "rgba(36, 120, 230, 0.3)";
      ctx.lineWidth = 1;
      ctx.setLineDash([3, 3]);
      ctx.moveTo(hx, 0);
      ctx.lineTo(hx, h);
      ctx.stroke();
      ctx.setLineDash([]);

      // Dot
      ctx.beginPath();
      ctx.arc(hx, hy, 5, 0, Math.PI * 2);
      ctx.fillStyle = "#2478e6";
      ctx.fill();
      ctx.strokeStyle = "white";
      ctx.lineWidth = 2;
      ctx.stroke();

      // Tooltip
      const meta = sparkMeta[hi] || {};
      const lines = [];
      if (meta.ts) {
        const t = meta.ts;
        lines.push(t.toLocaleTimeString([], { hour12: false }) + "." + String(t.getMilliseconds()).padStart(3, "0"));
      } else {
        lines.push("time: n/a");
      }
      if (meta.ramUsed != null && meta.ramUsed > 0) {
        lines.push(meta.ramTotal
          ? "RAM: " + Math.round(meta.ramUsed) + " / " + Math.round(meta.ramTotal) + " MB"
          : "RAM: " + Math.round(meta.ramUsed) + " MB");
      } else {
        lines.push("RAM: n/a");
      }
      if (meta.tps != null) {
        lines.push("TPS: " + Number(meta.tps).toFixed(1));
      } else {
        lines.push("TPS: 0.0");
      }
      lines.push("Activity: " + sparkPoints[hi].toFixed(0) + "%");

      const pad = 8;
      const lineH = 17;
      const tipW = 190;
      const tipH = lines.length * lineH + pad * 2;
      let tx = hx + 12;
      let ty = hy - tipH - 8;
      if (tx + tipW > w) tx = hx - tipW - 12;
      if (ty < 0) ty = hy + 10;
      tx = Math.max(2, Math.min(w - tipW - 2, tx));
      ty = Math.max(2, Math.min(h - tipH - 2, ty));

      ctx.fillStyle = "rgba(16, 24, 40, 0.92)";
      _sparkRoundRect(ctx, tx, ty, tipW, tipH, 6);
      ctx.fill();

      ctx.fillStyle = "rgba(255,255,255,0.9)";
      ctx.font = "bold 11px system-ui, sans-serif";
      ctx.textAlign = "left";
      ctx.textBaseline = "top";
      ctx.fillText(lines[0] || "", tx + pad, ty + pad);

      ctx.fillStyle = "rgba(180,200,255,0.85)";
      ctx.font = "11px system-ui, sans-serif";
      for (let li = 1; li < lines.length; li++) {
        ctx.fillText(lines[li], tx + pad, ty + pad + li * lineH);
      }
      ctx.textBaseline = "alphabetic";
      ctx.textAlign = "left";
    }
  }

  function numericOrNull(value) {
    const n = Number(value);
    return Number.isFinite(n) ? n : null;
  }

  function renderMemoryGauge(payload) {
    const fill = el("memoryBarFill");
    const text = el("memoryBarText");
    if (!fill || !text) return;

    // /cli/memory nests data under payload.ram — support both nested and any legacy flat fields.
    const ram = (payload?.ram && typeof payload.ram === "object") ? payload.ram : payload || {};

    const pctCandidate = [
      ram?.usage_percent,
      ram?.used_percent,
      payload?.memory_percent,
      payload?.ram_percent,
      payload?.used_percent,
    ]
      .map(numericOrNull)
      .find((v) => v !== null);

    const usedCandidate = [
      ram?.used_mb,
      payload?.memory_used_mb,
      payload?.ram_used_mb,
      payload?.used_mb,
      payload?.used,
    ]
      .map(numericOrNull)
      .find((v) => v !== null);

    const totalCandidate = [
      ram?.total_mb,
      payload?.memory_total_mb,
      payload?.ram_total_mb,
      payload?.total_mb,
      payload?.total,
    ]
      .map(numericOrNull)
      .find((v) => v !== null);

    let pct = pctCandidate;
    if (pct === null && usedCandidate !== null && totalCandidate !== null && totalCandidate > 0) {
      pct = (usedCandidate / totalCandidate) * 100;
    }

    if (pct === null) {
      fill.style.width = "0%";
      text.textContent = "No memory telemetry";
      return;
    }

    const bounded = Math.max(0, Math.min(100, pct));
    fill.style.width = `${bounded}%`;

    if (usedCandidate !== null && totalCandidate !== null) {
      text.textContent = `${usedCandidate.toFixed(0)} / ${totalCandidate.toFixed(0)} MB (${bounded.toFixed(1)}%)`;
    } else {
      text.textContent = `${bounded.toFixed(1)}%`;
    }

    if (bounded > 90) {
      fill.style.background = "linear-gradient(90deg, #e46b77, #c93b4c)";
    } else if (bounded > 75) {
      fill.style.background = "linear-gradient(90deg, #f0b04d, #d39218)";
    } else {
      fill.style.background = "linear-gradient(90deg, #26b87e, #1d8f63)";
    }
  }

  function renderPerfCounters() {
    const tps = numericOrNull(metricsCache?.throughput_tok_s);
    const displayTps = tps !== null && tps > 0 ? tps : 0;
    el("tpsValue").textContent = displayTps.toFixed(1);

    // Show real total_ms latency from the latest metrics record.
    const totalMs = numericOrNull(metricsCache?.total_ms);
    el("npuLoadValue").textContent =
      totalMs !== null && totalMs > 0
        ? `${totalMs.toFixed(0)} ms`
        : isChatBusy ? "…" : "-";

    // Show the actual inference device from the latest metrics or status.
    const inferDevice =
      String(metricsCache?.device || statusCache?.active_device || "-").toUpperCase();
    el("npuFreqValue").textContent = inferDevice;

    sampleToSpark(displayTps, { force: !isChatBusy });
  }

  function renderMetricsCards(payload) {
    const root = el("metricsCards");
    if (!root) return;

    // Determine whether this is a summary response (different field names).
    const isSummary = payload?.record_count !== undefined;

    // Helper: returns value only if it is a real positive measurement (not a sentinel like -1 or -1000).
    const realMs  = (v) => { const n = numericOrNull(v); return n !== null && n > 0 ? `${n.toFixed(1)} ms` : "–"; };
    const realTps = (v) => { const n = numericOrNull(v); return n !== null && n > 0 ? `${n.toFixed(1)} tok/s` : "–"; };

    const ttft       = isSummary ? payload?.avg_ttft_ms   : payload?.ttft_ms;
    const tpot       = isSummary ? payload?.avg_tpot_ms   : payload?.tpot_ms;
    const throughput = isSummary ? payload?.avg_throughput : (payload?.throughput_tok_s ?? payload?.throughput);
    const totalMs    = payload?.total_ms;
    const tokens     = numericOrNull(payload?.completion_tokens);
    const device     = String(payload?.device || "-").toUpperCase();

    const cards = [
      {
        title: "TTFT",
        value: realMs(ttft),
      },
      {
        title: "TPOT",
        value: realMs(tpot),
      },
      {
        title: isSummary ? "Avg Throughput" : "Throughput",
        value: realTps(throughput),
      },
      {
        title: "Total Latency",
        value: realMs(totalMs),
      },
      {
        title: "Device",
        value: device || "-",
      },
      {
        title: isSummary ? "Records" : "Tokens Out",
        value: isSummary
          ? String(payload?.record_count ?? "-")
          : (tokens !== null ? String(tokens) : (payload?.token_count_source || payload?.mode || "-")),
      },
    ];

    root.innerHTML = "";
    for (const card of cards) {
      const node = document.createElement("div");
      node.className = "status-card";
      node.innerHTML = `
        <div class="status-card-head">
          <span class="status-card-title">${card.title}</span>
          <span class="status-badge ready">metric</span>
        </div>
        <div class="status-card-value">${card.value}</div>
      `;
      root.appendChild(node);
    }
  }

  async function refreshStatus() {
    try {
      const result = await requestJson("/cli/status", { method: "GET" });
      statusCache = result;
      printJson(el("statusOutput"), result);
      renderReadinessBar(result);
      renderStatusCards(result);

      syncDeviceOptionsFromStatus(result);

      if (el("deviceSelect")) {
        el("deviceSelect").value = result.active_device || el("deviceSelect").value;
      }
      if (el("chatDeviceTarget")) {
        const target = normalizeDevice(el("chatDeviceTarget").value || "AUTO");
        const loadedSet = new Set((result.devices || []).map((d) => normalizeDevice(d)));
        if (target !== "AUTO" && !loadedSet.has(target)) {
          el("chatDeviceTarget").value = "AUTO";
        }
      }
      if (el("policySelect")) {
        el("policySelect").value = result.policy || el("policySelect").value;
      }

      const mappings = {
        json: "json_output",
        "split-prefill": "split_prefill",
        "context-routing": "context_routing",
        "optimize-memory": "optimize_memory",
      };

      for (const [feature, key] of Object.entries(mappings)) {
        const checkbox = document.querySelector(`.feature-toggle[data-feature='${feature}']`);
        if (!checkbox) continue;
        checkbox.checked = normalizeOnOff(result[key]);
      }

      if (typeof result.threshold === "number" && result.threshold > 0) {
        el("thresholdInput").value = result.threshold;
      }

      const featuresOutput = el("featuresOutput");
      if (featuresOutput && !featuresOutput.textContent.trim()) {
        featuresOutput.textContent = `Current feature state: ${featureSummary(result)}`;
      }

      updateThresholdControlState();
      validateThresholdInput();
      setRuntimeStrip();
    } catch (err) {
      el("statusOutput").textContent = String(err.message || err);
      renderStatusCards(statusCache || {});
      setRuntimeStrip();
    }
  }

  async function fetchMetrics(silent = false, forceMode = null) {
    try {
      const mode = forceMode || el("metricsMode").value;
      const result = await requestJson(`/cli/metrics?mode=${encodeURIComponent(mode)}`, { method: "GET" });
      metricsCache = mergeMetricsWithDerived(result);
      renderPerfCounters();
      renderMetricsCards(metricsCache);

      if (!silent) {
        printJson(el("metricsOutput"), result);
        if (result && result.mode === "live_fallback") {
          appendText(el("metricsOutput"), "\n\nNote: using live fallback metrics.");
        }
      }
      return result;
    } catch (err) {
      if (!silent) {
        el("metricsOutput").textContent = String(err.message || err);
      }
      throw err;
    }
  }

  async function fetchMemoryEvidence(silent = false) {
    try {
      const result = await requestJson("/cli/memory", { method: "GET" });
      memoryCache = result;
      renderMemoryGauge(result);
      if (!silent) {
        printJson(el("memoryOutput"), result);
      }
      return result;
    } catch (err) {
      if (!silent) {
        el("memoryOutput").textContent = String(err.message || err);
      }
      renderMemoryGauge({});
      throw err;
    }
  }

  function fillSelectOptions(selectEl, items, selectedId) {
    if (!selectEl) return;

    selectEl.innerHTML = "";
    if (!items.length) {
      const option = document.createElement("option");
      option.value = "";
      option.textContent = "(none)";
      selectEl.appendChild(option);
      return;
    }

    for (const item of items) {
      const option = document.createElement("option");
      option.value = item.id;
      const suffix = [item.format || item.type, item.status].filter(Boolean).join(" | ");
      option.textContent = suffix ? `${item.id} (${suffix})` : item.id;
      option.selected = item.id === selectedId;
      selectEl.appendChild(option);
    }
  }

  function renderModelDetails() {
    const selectedId = el("modelSelect")?.value;
    const selected = modelRegistryCache.find((item) => item.id === selectedId);
    if (!selected) {
      el("modelDetails").textContent = "No model selected.";
      return;
    }
    printJson(el("modelDetails"), selected);
  }

  function renderBackendDetails() {
    const selectedId = el("backendSelect")?.value;
    const selected = backendRegistryCache.find((item) => item.id === selectedId);
    if (!selected) {
      el("backendDetails").textContent = "No backend selected.";
      return;
    }
    printJson(el("backendDetails"), selected);
  }

  function registryRowStatus(item, view) {
    if (view === "models") {
      if ((statusCache?.selected_model || "") === item.id) return "ready";
    }
    if (view === "backends") {
      if ((statusCache?.selected_backend || "") === item.id) return "ready";
    }

    const s = String(item.status || "ready").toLowerCase();
    if (s.includes("error") || s.includes("fail")) return "error";
    if (s.includes("loading") || s.includes("busy")) return "busy";
    return "ready";
  }

  function renderRegistryExplorer() {
    const listEl = el("registryList");
    const detailEl = el("registryDetail");
    const search = String(el("registrySearch")?.value || "").toLowerCase().trim();

    if (!listEl || !detailEl) return;

    const source = registryView === "models" ? modelRegistryCache : backendRegistryCache;
    const filtered = source.filter((item) => {
      if (!search) return true;
      const blob = `${item.id} ${item.format || ""} ${item.type || ""} ${item.status || ""} ${item.path || ""} ${item.entrypoint || ""}`.toLowerCase();
      return blob.includes(search);
    });

    listEl.innerHTML = "";
    if (!filtered.length) {
      listEl.innerHTML = '<div class="registry-meta">No entries match this filter.</div>';
      detailEl.textContent = "";
      return;
    }

    for (const item of filtered) {
      const row = document.createElement("div");
      row.className = "registry-row";

      const left = document.createElement("div");
      left.innerHTML = `
        <div class="registry-name">${item.id}</div>
        <div class="registry-meta">${item.format || item.type || "-"} ${item.path || item.entrypoint || ""}</div>
      `;

      const chip = document.createElement("span");
      const state = registryRowStatus(item, registryView);
      chip.className = `registry-chip ${state}`;
      chip.textContent = state;

      row.appendChild(left);
      row.appendChild(chip);
      row.addEventListener("click", () => {
        renderRegistryDetailCard(item);
      });

      listEl.appendChild(row);
    }
  }

  function renderRegistryDetailCard(item) {
    const detailEl = el("registryDetail");
    if (!detailEl) return;

    const state = registryRowStatus(item, registryView);
    const tags = [item.format, item.type, ...(Array.isArray(item.formats) ? item.formats : [])]
      .filter((v, i, a) => v && a.indexOf(v) === i);
    const pathValue = item.path || item.entrypoint || "";
    const pathName = pathValue.replace(/\\/g, "/").split("/").filter(Boolean).pop() || pathValue;
    const selectLabel = registryView === "models" ? "Select Model" : "Select Backend";
    const stateLabel = state === "ready" ? "&#x25CF; Active" : state;

    detailEl.innerHTML = `
      <div class="registry-detail-head">
        <span class="registry-detail-title">${item.id}</span>
        <span class="registry-chip ${state}">${stateLabel}</span>
      </div>
      <div class="registry-tags">
        ${tags.map((t) => `<span class="registry-tag">${t}</span>`).join("")}
      </div>
      ${pathValue ? `<div class="registry-path" title="${pathValue}">&#x1F4C1; ${pathName}</div>` : ""}
      <div class="registry-detail-actions">
        <button type="button" class="ghost registry-action-select">${selectLabel}</button>
        <button type="button" class="ghost registry-action-raw">{ } Raw JSON</button>
      </div>
    `;

    detailEl.querySelector(".registry-action-select")?.addEventListener("click", () => {
      if (registryView === "models") {
        if (el("modelSelect")) el("modelSelect").value = item.id;
        selectModel();
      } else {
        if (el("backendSelect")) el("backendSelect").value = item.id;
        selectBackend();
      }
    });

    detailEl.querySelector(".registry-action-raw")?.addEventListener("click", () => {
      const rawEl = el("registryDetailRaw");
      if (!rawEl) return;
      const rawDetails = rawEl.closest("details");
      if (rawEl.textContent.trim()) {
        rawEl.textContent = "";
        if (rawDetails) rawDetails.removeAttribute("open");
      } else {
        printJson(rawEl, item);
        if (rawDetails) rawDetails.setAttribute("open", "");
      }
    });

    selectedRegistryItem = item;
  }

  async function refreshModelRegistry() {
    const result = await requestJson("/cli/model/list", { method: "GET" });
    const models = Array.isArray(result.models) ? result.models : [];
    modelRegistryCache = models;
    fillSelectOptions(el("modelSelect"), models, result.selected_model);
    syncChatModelOptions(result.selected_model || "");
    renderModelDetails();
    renderRegistryExplorer();
    return result;
  }

  async function refreshBackendRegistry() {
    const result = await requestJson("/cli/backend/list", { method: "GET" });
    const backends = Array.isArray(result.backends) ? result.backends : [];
    backendRegistryCache = backends;
    fillSelectOptions(el("backendSelect"), backends, result.selected_backend);
    renderBackendDetails();
    renderRegistryExplorer();
    return result;
  }

  function showRestartRequired(outputEl, note) {
    if (!outputEl) return;
    const line = note || "Applies on next stack restart (.\\start_app.ps1).";
    appendText(outputEl, `\n\n${line}`);
  }

  async function switchDevice() {
    try {
      addActivity("Checking NPU route...", "busy");
      const result = await requestJson("/cli/device/switch", {
        method: "POST",
        body: JSON.stringify({ device: el("deviceSelect").value }),
      });
      printJson(el("devicePolicyOutput"), result);
      addActivity(`Device switched to ${result.new_active_device || el("deviceSelect").value}`, "ready");
      await refreshStatus();
    } catch (err) {
      el("devicePolicyOutput").textContent = String(err.message || err);
      addActivity(`Device switch failed: ${String(err.message || err)}`, "error");
    }
  }

  async function setPolicy() {
    try {
      const result = await requestJson("/cli/policy", {
        method: "POST",
        body: JSON.stringify({ policy: el("policySelect").value }),
      });
      printJson(el("devicePolicyOutput"), result);
      addActivity(`Policy set to ${result.new_policy || el("policySelect").value}`, "ready");
      await refreshStatus();
    } catch (err) {
      el("devicePolicyOutput").textContent = String(err.message || err);
      addActivity(`Policy change failed: ${String(err.message || err)}`, "error");
    }
  }

  async function setFeatureToggle(feature, enabled, options = {}) {
    const result = await requestJson(`/cli/feature/${feature}`, {
      method: "POST",
      body: JSON.stringify({ enabled }),
    });

    if (options.outputTarget) {
      appendText(options.outputTarget, `${feature}: ${result.status}\n`);
    }

    return result;
  }

  const FEATURE_ERROR_HINTS = {
    insufficient_devices:
      "Requires >=2 loaded devices. Launch backend with --benchmark to load all available devices.",
  };

  function friendlyFeatureError(feature, err) {
    const msg = String(err.message || err);
    for (const [code, hint] of Object.entries(FEATURE_ERROR_HINTS)) {
      if (msg.toLowerCase().includes(code.replace("_", ""))) {
        return `${feature}: ${msg}\n-> ${hint}`;
      }
    }
    return `${feature}: ${msg}`;
  }

  async function handleFeatureToggleChange(toggle) {
    const output = el("featuresOutput");
    const feature = toggle.dataset.feature;
    const desiredState = toggle.checked;

    toggle.disabled = true;
    try {
      const result = await setFeatureToggle(feature, desiredState);
      output.textContent = `${feature}: ${result.status}\nRefreshing runtime state...`;
      addActivity(`Feature ${feature} -> ${result.status}`, "ready");
    } catch (err) {
      toggle.checked = !desiredState;
      output.textContent = friendlyFeatureError(feature, err);
      addActivity(`Feature toggle failed: ${feature}`, "error");
    } finally {
      toggle.disabled = false;
      updateThresholdControlState();
      validateThresholdInput();
      await refreshStatus();

      if (feature === "optimize-memory") {
        await fetchMemoryEvidence(false).catch(() => {});
        startMemoryLiveWindow(20000, 1000);
        addActivity("Live memory polling enabled for optimize-memory (20s)", "busy");
      }
    }
  }

  async function setThreshold() {
    if (!validateThresholdInput()) return;

    try {
      setButtonBusy("setThreshold", true, "Setting...");
      const result = await requestJson("/cli/threshold", {
        method: "POST",
        body: JSON.stringify({ threshold: Number(el("thresholdInput").value || 0) }),
      });
      printJson(el("featuresOutput"), result);
      addActivity(`Threshold set to ${result.new_threshold || el("thresholdInput").value}`, "ready");
      await refreshStatus();
      validateThresholdInput();
    } catch (err) {
      el("featuresOutput").textContent = String(err.message || err);
      addActivity("Threshold update failed", "error");
    } finally {
      setButtonBusy("setThreshold", false);
    }
  }

  async function selectModel() {
    const output = el("registryOutput");
    const id = el("modelSelect").value;
    if (!id) {
      output.textContent = "No model selected.";
      return;
    }

    try {
      setButtonBusy("selectModel", true, "Selecting...");
      const result = await requestJson("/cli/model/select", {
        method: "POST",
        body: JSON.stringify({ id }),
      });
      printJson(output, result);
      showRestartRequired(output);
      addActivity(`Model selected: ${id} (pending restart)`, "busy");
      await refreshModelRegistry();
      await refreshStatus();
    } catch (err) {
      output.textContent = String(err.message || err);
      addActivity("Model select failed", "error");
    } finally {
      setButtonBusy("selectModel", false);
    }
  }

  async function importModel() {
    const output = el("registryOutput");
    const id = el("modelImportId").value.trim();
    const path = el("modelImportPath").value.trim();
    const format = el("modelImportFormat").value.trim() || "openvino";
    const backend = el("backendSelect").value || "openvino";

    if (!id || !path) {
      output.textContent = "Model import requires id and path.";
      return;
    }

    try {
      setButtonBusy("importModel", true, "Importing...");
      const result = await requestJson("/cli/model/import", {
        method: "POST",
        body: JSON.stringify({ id, path, format, backend, status: "ready" }),
      });
      printJson(output, result);
      addActivity(`Model imported: ${id}`, "ready");
      await refreshModelRegistry();
      el("modelImportId").value = "";
      await refreshStatus();
    } catch (err) {
      output.textContent = String(err.message || err);
      addActivity("Model import failed", "error");
    } finally {
      setButtonBusy("importModel", false);
    }
  }

  async function selectBackend() {
    const output = el("registryOutput");
    const id = el("backendSelect").value;
    if (!id) {
      output.textContent = "No backend selected.";
      return;
    }

    try {
      setButtonBusy("selectBackend", true, "Selecting...");
      const result = await requestJson("/cli/backend/select", {
        method: "POST",
        body: JSON.stringify({ id }),
      });
      printJson(output, result);
      showRestartRequired(output);
      addActivity(`Backend selected: ${id} (pending restart)`, "busy");
      await refreshBackendRegistry();
      await refreshStatus();
    } catch (err) {
      output.textContent = String(err.message || err);
      addActivity("Backend select failed", "error");
    } finally {
      setButtonBusy("selectBackend", false);
    }
  }

  async function addBackend() {
    const output = el("registryOutput");
    const id = el("backendAddId").value.trim();
    const type = el("backendAddType").value.trim() || "external";
    const entrypoint = el("backendAddEntrypoint").value.trim();

    if (!id || !entrypoint) {
      output.textContent = "Backend add requires id and entrypoint.";
      return;
    }

    try {
      setButtonBusy("addBackend", true, "Adding...");
      const result = await requestJson("/cli/backend/add", {
        method: "POST",
        body: JSON.stringify({ id, type, entrypoint, formats: ["openvino"] }),
      });
      printJson(output, result);
      addActivity(`Backend added: ${id}`, "ready");
      await refreshBackendRegistry();
      el("backendAddId").value = "";
      await refreshStatus();
    } catch (err) {
      output.textContent = String(err.message || err);
      addActivity("Backend add failed", "error");
    } finally {
      setButtonBusy("addBackend", false);
    }
  }

  async function handleDeviceTargetChange() {
    const target = el("chatDeviceTarget")?.value;
    if (!target) return;

    setRuntimeStrip();
    if (el("deviceSelect")) el("deviceSelect").value = target;

    const loadedSet = new Set((statusCache?.devices || []).map((d) => normalizeDevice(d)));
    if (target !== "AUTO" && !loadedSet.has(target)) {
      addActivity(`Loading model on ${target} — this may take a moment...`, "busy");
      // Disable the dropdown while loading so the user doesn't double-click.
      const select = el("chatDeviceTarget");
      if (select) select.disabled = true;
      try {
        await requestJson("/cli/device/load", {
          method: "POST",
          body: JSON.stringify({ device: target }),
        });
        addActivity(`Model loaded on ${target}`, "ready");
        await refreshStatus(); // Updates loaded devices in statusCache
      } catch (loadErr) {
        addActivity(
          `Could not load model on ${target}: ${String(loadErr.message || loadErr)}`,
          "error"
        );
        if (select) select.disabled = false;
        return;
      } finally {
        if (select) select.disabled = false;
      }
    }

    try {
      await requestJson("/cli/device/switch", {
        method: "POST",
        body: JSON.stringify({ device: target }),
      });
      addActivity(`Device set to ${target}`, "ready");
      await refreshStatus();
    } catch (err) {
      addActivity(`Device switch failed: ${String(err.message || err)}`, "error");
    }
  }

  function applyModelPreset(button) {
    const repo = button?.dataset?.repo || "";
    const id = button?.dataset?.id || "";
    const format = button?.dataset?.format || "openvino";
    if (el("terminalModelRepo")) el("terminalModelRepo").value = repo;
    if (el("terminalModelId")) el("terminalModelId").value = id;
    if (el("modelImportId")) el("modelImportId").value = id;
    if (el("modelImportPath")) el("modelImportPath").value = `./models/${id}`;
    if (el("modelImportFormat")) el("modelImportFormat").value = format;
    buildTerminalCommand();
    addActivity(`Preset loaded: ${id}`, "ready");
  }

  function applyBackendPreset() {
    const backend = String(el("terminalBackendPreset")?.value || "openvino").trim();
    if (!backend) return;
    if (el("backendAddId")) el("backendAddId").value = backend;
    if (el("backendAddType")) el("backendAddType").value = "external";
    if (el("backendAddEntrypoint")) {
      el("backendAddEntrypoint").value = `./backends/${backend}/${backend}.exe`;
    }
    if (el("backendSelect")) el("backendSelect").value = backend;
    addActivity(`Backend preset loaded: ${backend}`, "ready");
  }

  function buildTerminalCommand() {
    const repo = String(el("terminalModelRepo")?.value || "").trim();
    const id = String(el("terminalModelId")?.value || "").trim();
    const preview = el("terminalCommandPreview");
    if (!preview) return;
    const localId = id || (repo.split("/").pop() || "my-model");
    preview.textContent = repo
      ? `.\\npu_cli.ps1 -Command model -Arguments "download","${repo}","${localId}"`
      : `.\\npu_cli.ps1 -Command model -Arguments "download","<repo>","<local-id>"`;
  }

  async function copyTerminalCommand() {
    const preview = el("terminalCommandPreview");
    if (!preview || !preview.textContent.trim()) return;
    try {
      await navigator.clipboard.writeText(preview.textContent.trim());
      addActivity("Terminal command copied to clipboard", "ready");
    } catch {
      addActivity("Clipboard copy failed — select and copy manually", "error");
    }
  }

  async function summarizeContext() {
    const output = el("chatOutput");
    const currentContent = output ? output.textContent.trim() : "";
    if (!currentContent || currentContent.length < 20) {
      addActivity("Not enough context to summarize", "busy");
      return;
    }
    if (isChatBusy) return;
    setChatBusy(true);
    addActivity("Summarizing context...", "busy");
    try {
      const result = await requestJson("/chat/completions", {
        method: "POST",
        body: JSON.stringify({
          model: el("chatModel").value || "openvino",
          messages: [
            {
              role: "user",
              content: `Summarize the following conversation concisely so it can serve as compressed context memory:\n\n${currentContent}`,
            },
          ],
          stream: false,
          temperature: 0.3,
          max_tokens: 300,
        }),
      });
      const summary = result?.choices?.[0]?.message?.content || "";
      if (output && summary) {
        output.textContent = `[Context Summary]\n${summary}`;
        addActivity("Context summarized and compressed", "ready");
        updateContextEstimate();
      }
    } catch (err) {
      addActivity(`Summarize failed: ${String(err.message || err)}`, "error");
    } finally {
      setChatBusy(false);
    }
  }

  async function probeConnection() {
    setConnectionState("checking");
    try {
      const result = await requestJson("/health", { method: "GET" });
      const status = el("statusOutput");
      if (status) {
        status.textContent = `API reachable. backend=${result.backend} status=${result.status}`;
      }
    } catch {
      const status = el("statusOutput");
      if (status) {
        status.textContent = "Reconnect failed: API is unreachable.";
      }
    }
  }

  function startConnectionPolling() {
    if (healthPollTimer) clearInterval(healthPollTimer);
    probeConnection();
    healthPollTimer = setInterval(probeConnection, 5000);
  }

  function startPerformancePolling() {
    if (perfPollTimer) clearInterval(perfPollTimer);
    perfPollTimer = setInterval(async () => {
      try {
        await Promise.allSettled([
          refreshStatus(),
          fetchMetrics(true, "last"),
          fetchMemoryEvidence(true),
        ]);
      } catch {
        // Ignore background polling errors.
      }
    }, 6000);
  }

  async function handleChatSend() {
    if (isChatBusy) return;

    const input = el("chatInput");
    const prompt = input.value.trim();
    const output = el("chatOutput");

    if (!prompt) {
      output.textContent = "Type a prompt before sending.";
      return;
    }

    output.textContent = "";

    if (activeChatAbortController) {
      activeChatAbortController.abort();
    }
    activeChatAbortController = new AbortController();

    setChatBusy(true);
    renderStatusCards(statusCache || {});

    const body = {
      model: el("chatModel")?.value || statusCache?.selected_model || "openvino",
      messages: [{ role: "user", content: prompt }],
      stream: el("chatStream").checked,
      temperature: Number(el("chatTemperature").value || 0.7),
      max_tokens: Number(el("chatMaxTokens").value || 128),
    };

    const startedAt = Date.now();
    let generatedTokenEstimate = 0;
    let generatedCharCount = 0;
    let clientFirstTokenAt = null;
    let clientTtftMs = null;
    let clientTpotMs = null;

    const targetDevice = el("chatDeviceTarget")?.value || "";
    const loadedSet = new Set((statusCache?.devices || []).map((d) => normalizeDevice(d)));

    if (targetDevice !== "AUTO" && targetDevice && !loadedSet.has(targetDevice)) {
      addActivity(`Loading model on ${targetDevice} — please wait...`, "busy");
      try {
        await requestJson("/cli/device/load", {
          method: "POST",
          body: JSON.stringify({ device: targetDevice }),
        });
        addActivity(`Model loaded on ${targetDevice}`, "ready");
        await refreshStatus();
      } catch (loadErr) {
        addActivity(`Could not load model on ${targetDevice}: ${String(loadErr.message || loadErr)}`, "error");
        output.textContent = `Chat blocked: could not load model on ${targetDevice}.`;
        activeChatAbortController = null;
        setChatBusy(false);
        return;
      }
    }

    if (targetDevice && targetDevice !== normalizeDevice(statusCache?.active_device || "")) {
      addActivity(`Switching device to ${targetDevice}...`, "busy");
      try {
        await requestJson("/cli/device/switch", {
          method: "POST",
          body: JSON.stringify({ device: targetDevice }),
        });
        if (el("deviceSelect")) el("deviceSelect").value = targetDevice;
        await refreshStatus();
      } catch (switchErr) {
        addActivity(`Device pre-switch failed: ${String(switchErr.message || switchErr)}`, "error");
        output.textContent = `Chat blocked: could not switch to ${targetDevice}.`;
        activeChatAbortController = null;
        setChatBusy(false);
        return;
      }
    }

    addActivity("Checking NPU...", "busy");
    addActivity(`Loading model: ${body.model}...`, "busy");

    try {
      addPromptToHistory(prompt);
      addActivity("Inferencing...", "busy");

      if (!body.stream) {
        const payload = await requestJson("/chat/completions", {
          method: "POST",
          body: JSON.stringify(body),
          signal: activeChatAbortController.signal,
        });
        const content = payload?.choices?.[0]?.message?.content || "";
        output.textContent = content;
        generatedTokenEstimate = estimateTokens(content);
        generatedCharCount = content.length;
        // Non-streaming: TTFT ≈ full round-trip (first token not isolable)
        clientTtftMs = Date.now() - startedAt;
        clientTpotMs = generatedTokenEstimate > 1
          ? clientTtftMs / generatedTokenEstimate
          : clientTtftMs;

        const provisional = {
          ...(metricsCache || {}),
          ttft_ms: clientTtftMs,
          tpot_ms: clientTpotMs,
          throughput_tok_s: generatedTokenEstimate / Math.max(0.001, (Date.now() - startedAt) / 1000),
          total_ms: Date.now() - startedAt,
          completion_tokens: generatedTokenEstimate,
          device: String(statusCache?.active_device || targetDevice || metricsCache?.device || "-").toUpperCase(),
        };
        lastDerivedMetrics = {
          ttft_ms: provisional.ttft_ms,
          tpot_ms: provisional.tpot_ms,
          throughput_tok_s: provisional.throughput_tok_s,
          total_ms: provisional.total_ms,
          completion_tokens: provisional.completion_tokens,
          device: provisional.device,
        };
        metricsCache = provisional;
        renderPerfCounters();
        renderMetricsCards(provisional);
      } else {
        const response = await fetch(`${baseUrl()}/chat/completions`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
          signal: activeChatAbortController.signal,
        });

        if (!response.ok || !response.body) {
          const errPayload = await response.json().catch(() => ({}));
          throw new Error(errPayload?.error?.message || `HTTP ${response.status}`);
        }

        setConnectionState("online");

        const reader = response.body.getReader();
        const decoder = new TextDecoder("utf-8");
        let buffer = "";

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split("\n");
          buffer = lines.pop() || "";

          for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed.startsWith("data:")) continue;

            const data = trimmed.slice(5).trim();
            if (data === "[DONE]") {
              appendText(output, "\n\n[DONE]");
              continue;
            }

            try {
              const parsed = JSON.parse(data);
              const chunk = parsed?.choices?.[0]?.delta?.content;
              if (!chunk) continue;
              if (clientFirstTokenAt === null) clientFirstTokenAt = Date.now();
              appendText(output, chunk);
              generatedCharCount += chunk.length;
              generatedTokenEstimate = Math.max(1, Math.round(generatedCharCount / 4));

              const elapsedSec = Math.max(0.001, (Date.now() - startedAt) / 1000);
              const liveTps = generatedTokenEstimate / elapsedSec;
              const liveTtftMs = clientFirstTokenAt !== null ? (clientFirstTokenAt - startedAt) : null;
              const liveTpotMs = (liveTtftMs !== null && generatedTokenEstimate > 1)
                ? ((elapsedSec * 1000 - liveTtftMs) / (generatedTokenEstimate - 1))
                : null;

              const liveMetrics = {
                ...(metricsCache || {}),
                ttft_ms: liveTtftMs ?? metricsCache?.ttft_ms,
                tpot_ms: liveTpotMs ?? metricsCache?.tpot_ms,
                throughput_tok_s: liveTps,
                total_ms: elapsedSec * 1000,
                completion_tokens: generatedTokenEstimate,
                device: String(statusCache?.active_device || targetDevice || metricsCache?.device || "-").toUpperCase(),
              };
              lastDerivedMetrics = {
                ttft_ms: liveMetrics.ttft_ms,
                tpot_ms: liveMetrics.tpot_ms,
                throughput_tok_s: liveMetrics.throughput_tok_s,
                total_ms: liveMetrics.total_ms,
                completion_tokens: liveMetrics.completion_tokens,
                device: liveMetrics.device,
              };
              metricsCache = liveMetrics;
              el("tpsValue").textContent = liveTps.toFixed(1);
              sampleToSpark(liveTps);
              renderPerfCounters();
              renderMetricsCards(liveMetrics);
            } catch {
              // Ignore malformed partial chunks.
            }
          }
        }
      }

      // Finalize client-side TTFT/TPOT for streaming path
      const elapsedSec = Math.max(0.001, (Date.now() - startedAt) / 1000);
      if (clientFirstTokenAt !== null && clientTtftMs === null) {
        clientTtftMs = clientFirstTokenAt - startedAt;
        clientTpotMs = generatedTokenEstimate > 1
          ? (elapsedSec * 1000 - clientTtftMs) / (generatedTokenEstimate - 1)
          : clientTtftMs;
      } else if (clientTtftMs === null && generatedTokenEstimate > 0) {
        // Non-streaming fallback: full time as TTFT proxy
        clientTtftMs = elapsedSec * 1000;
        clientTpotMs = generatedTokenEstimate > 1 ? clientTtftMs / generatedTokenEstimate : clientTtftMs;
      }
      const tps = generatedTokenEstimate / elapsedSec;
      el("tpsValue").textContent = Number.isFinite(tps) ? tps.toFixed(1) : "0.0";

      lastInferenceStats.device = statusCache?.active_device || targetDevice || "AUTO";
      lastInferenceStats.tps = Number.isFinite(tps) ? tps : 0;
      setRuntimeStrip();

      addActivity("Inference complete", "ready");

      await Promise.allSettled([
        refreshStatus(),
        fetchMetrics(true, "last"),
        fetchMemoryEvidence(true),
      ]);

      // Overlay client-measured timing into metricsCache where backend returned sentinel –1 values
      if (clientTtftMs !== null && metricsCache) {
        if (!(metricsCache.ttft_ms > 0))           metricsCache.ttft_ms          = clientTtftMs;
        if (!(metricsCache.tpot_ms > 0))           metricsCache.tpot_ms          = clientTpotMs;
        if (!(metricsCache.throughput_tok_s > 0))  metricsCache.throughput_tok_s = tps;
        if (!(metricsCache.completion_tokens > 0)) metricsCache.completion_tokens = generatedTokenEstimate;
        if (!(metricsCache.total_ms > 0))          metricsCache.total_ms         = elapsedSec * 1000;
        metricsCache.device = (metricsCache.device && metricsCache.device !== "-")
          ? metricsCache.device
          : (statusCache?.active_device || targetDevice || "?");
        lastDerivedMetrics = {
          ttft_ms: metricsCache.ttft_ms,
          tpot_ms: metricsCache.tpot_ms,
          throughput_tok_s: metricsCache.throughput_tok_s,
          total_ms: metricsCache.total_ms,
          completion_tokens: metricsCache.completion_tokens,
          device: metricsCache.device,
        };
        renderPerfCounters();
        renderMetricsCards(metricsCache);
      }
    } catch (err) {
      if (err?.name === "AbortError") {
        appendText(output, "\n\n[Cancelled]");
        addActivity("Inference cancelled", "busy");
        return;
      }

      setConnectionState("offline", "chat failed");
      output.textContent = `Chat failed: ${String(err.message || err)}`;
      addActivity(`Chat failed: ${String(err.message || err)}`, "error");
    } finally {
      activeChatAbortController = null;
      setChatBusy(false);
      renderStatusCards(statusCache || {});
    }
  }

  function cancelChat() {
    if (!activeChatAbortController) return;
    activeChatAbortController.abort();
  }

  function on(id, event, handler) {
    const node = el(id);
    if (!node) {
      console.warn(`[ui] missing element: #${id}`);
      return;
    }
    node.addEventListener(event, handler);
  }

  function showBackendWizard() {
    const dlg = el("backendWizard");
    if (!dlg || typeof dlg.showModal !== "function") return;
    dlg.showModal();
  }

  function closeBackendWizard() {
    const dlg = el("backendWizard");
    if (!dlg) return;
    if (dlg.open) dlg.close();
  }

  async function saveBackendFromWizard() {
    const id = el("wizardBackendId").value.trim();
    const type = el("wizardBackendType").value.trim() || "external";
    const entrypoint = el("wizardBackendEntrypoint").value.trim();

    el("backendAddId").value = id;
    el("backendAddType").value = type;
    el("backendAddEntrypoint").value = entrypoint;

    await addBackend();
    closeBackendWizard();

    el("wizardBackendId").value = "";
    el("wizardBackendEntrypoint").value = "";
  }

  const COMMANDS = [
    {
      id: "refresh-status",
      label: "Refresh Status",
      keywords: "refresh status runtime health",
      action: () => refreshStatus(),
    },
    {
      id: "refresh-metrics",
      label: "Refresh Metrics",
      keywords: "metrics performance",
      action: () => fetchMetrics(false, "last"),
    },
    {
      id: "refresh-memory",
      label: "Refresh Memory",
      keywords: "memory refresh",
      action: () => fetchMemoryEvidence(false),
    },
    {
      id: "view-workspace",
      label: "Switch to Workspace View",
      keywords: "tab workspace",
      action: () => setPrimaryView("workspace"),
    },
    {
      id: "view-control",
      label: "Switch to Control View",
      keywords: "tab control",
      action: () => setPrimaryView("control"),
    },
    {
      id: "device-auto",
      label: "Set Device AUTO",
      keywords: "device auto",
      action: () => {
        if (el("chatDeviceTarget")) el("chatDeviceTarget").value = "AUTO";
        return handleDeviceTargetChange();
      },
    },
    {
      id: "device-cpu",
      label: "Set Device CPU",
      keywords: "device cpu",
      action: () => {
        if (el("chatDeviceTarget")) el("chatDeviceTarget").value = "CPU";
        return handleDeviceTargetChange();
      },
    },
    {
      id: "device-gpu",
      label: "Set Device GPU",
      keywords: "device gpu",
      action: () => {
        if (el("chatDeviceTarget")) el("chatDeviceTarget").value = "GPU";
        return handleDeviceTargetChange();
      },
    },
    {
      id: "device-npu",
      label: "Set Device NPU",
      keywords: "device npu",
      action: () => {
        if (el("chatDeviceTarget")) el("chatDeviceTarget").value = "NPU";
        return handleDeviceTargetChange();
      },
    },
    {
      id: "clear-history",
      label: "Clear Prompt History",
      keywords: "history clear prompts",
      action: () => clearPromptHistory(),
    },
    {
      id: "clear-memory",
      label: "Clear Local Memory Buffer",
      keywords: "clear memory context",
      action: () => clearContextBuffer(),
    },
    {
      id: "summarize-context",
      label: "Summarize Context",
      keywords: "summarize context compact",
      action: () => summarizeContext(),
    },
    {
      id: "build-terminal-command",
      label: "Build Terminal Download Command",
      keywords: "terminal command model download",
      action: () => buildTerminalCommand(),
    },
    {
      id: "copy-terminal-command",
      label: "Copy Terminal Download Command",
      keywords: "terminal command copy",
      action: () => copyTerminalCommand(),
    },
    {
      id: "switch-model",
      label: "Focus Model Selector",
      keywords: "model select",
      action: () => {
        el("chatModel")?.focus();
        addActivity("Model selector focused", "ready");
      },
    },
    {
      id: "focus-registry-model",
      label: "Focus Registry Model Selector",
      keywords: "registry model selector",
      action: () => el("modelSelect")?.focus(),
    },
    {
      id: "focus-registry-backend",
      label: "Focus Registry Backend Selector",
      keywords: "registry backend selector",
      action: () => el("backendSelect")?.focus(),
    },
    {
      id: "refresh-model-registry",
      label: "Refresh Model Registry",
      keywords: "registry model refresh",
      action: async () => {
        const result = await refreshModelRegistry();
        printJson(el("registryOutput"), result);
      },
    },
    {
      id: "refresh-backend-registry",
      label: "Refresh Backend Registry",
      keywords: "registry backend refresh",
      action: async () => {
        const result = await refreshBackendRegistry();
        printJson(el("registryOutput"), result);
      },
    },
    {
      id: "select-current-model",
      label: "Select Current Registry Model",
      keywords: "registry model select",
      action: () => selectModel(),
    },
    {
      id: "select-current-backend",
      label: "Select Current Registry Backend",
      keywords: "registry backend select",
      action: () => selectBackend(),
    },
    {
      id: "apply-backend-preset",
      label: "Apply Backend Preset",
      keywords: "backend preset terminal",
      action: () => applyBackendPreset(),
    },
  ];

  function openCommandPalette() {
    const dlg = el("commandPalette");
    const input = el("commandInput");
    if (!dlg || typeof dlg.showModal !== "function") return;

    commandState.open = true;
    commandState.selectedIndex = 0;
    input.value = "";

    renderCommandList();
    dlg.showModal();
    setTimeout(() => input.focus(), 0);
  }

  function closeCommandPalette() {
    const dlg = el("commandPalette");
    if (!dlg) return;
    commandState.open = false;
    if (dlg.open) dlg.close();
  }

  function currentCommandFilter() {
    return String(el("commandInput")?.value || "").trim().toLowerCase();
  }

  function renderCommandList() {
    const list = el("commandList");
    if (!list) return;

    const filter = currentCommandFilter();
    const filtered = COMMANDS.filter((cmd) => {
      if (!filter) return true;
      return (`${cmd.label} ${cmd.keywords}`).toLowerCase().includes(filter);
    });

    commandState.filtered = filtered;
    if (commandState.selectedIndex >= filtered.length) {
      commandState.selectedIndex = Math.max(0, filtered.length - 1);
    }

    list.innerHTML = "";
    filtered.forEach((cmd, idx) => {
      const li = document.createElement("li");
      if (idx === commandState.selectedIndex) {
        li.classList.add("active");
      }
      li.textContent = cmd.label;
      li.addEventListener("click", () => runCommand(cmd));
      list.appendChild(li);
    });

    if (!filtered.length) {
      list.innerHTML = "<li>No commands found.</li>";
    }
  }

  function runCommand(cmd) {
    closeCommandPalette();
    Promise.resolve(cmd.action()).catch((err) => {
      addActivity(`Command failed: ${String(err.message || err)}`, "error");
    });
  }

  function handleCommandInputKeydown(event) {
    if (!commandState.open) return;

    if (event.key === "ArrowDown") {
      event.preventDefault();
      if (commandState.filtered.length) {
        commandState.selectedIndex = (commandState.selectedIndex + 1) % commandState.filtered.length;
        renderCommandList();
      }
      return;
    }

    if (event.key === "ArrowUp") {
      event.preventDefault();
      if (commandState.filtered.length) {
        commandState.selectedIndex =
          (commandState.selectedIndex - 1 + commandState.filtered.length) % commandState.filtered.length;
        renderCommandList();
      }
      return;
    }

    if (event.key === "Enter") {
      event.preventDefault();
      const cmd = commandState.filtered[commandState.selectedIndex];
      if (cmd) runCommand(cmd);
      return;
    }

    if (event.key === "Escape") {
      event.preventDefault();
      closeCommandPalette();
    }
  }

  function bindGlobalShortcuts() {
    window.addEventListener("keydown", (event) => {
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        if (!commandState.open) openCommandPalette();
      }

      if (event.key === "Escape" && commandState.open) {
        closeCommandPalette();
      }
    });
  }

  function switchRegistryTab(next) {
    registryView = next;
    el("registryTabModels")?.classList.toggle("active", next === "models");
    el("registryTabBackends")?.classList.toggle("active", next === "backends");
    renderRegistryExplorer();
  }

  async function bootstrap() {
    if (isTauri()) {
      setConnectionState("checking");
      try {
        await tauriStartBackend();
      } catch (err) {
        el("statusOutput").textContent = `Tauri backend start failed: ${String(err.message || err)}`;
        addActivity("Tauri backend start failed", "error");
      }
      await waitForApiReady(30000);
    }

    try {
      await Promise.all([
        refreshStatus(),
        refreshModelRegistry(),
        refreshBackendRegistry(),
        fetchMetrics(true, "last"),
        fetchMemoryEvidence(true),
      ]);
      addActivity("Runtime ready", "ready");
      if (statusCache?.active_device && el("chatDeviceTarget")) {
        const dv = normalizeDevice(statusCache.active_device);
        const matchOpt = Array.from(el("chatDeviceTarget").options).find((o) => o.value === dv);
        if (matchOpt) el("chatDeviceTarget").value = dv;
      }
      syncChatModelOptions(statusCache?.selected_model || "");
      setRuntimeStrip();
    } catch (err) {
      el("statusOutput").textContent = String(err.message || err);
      addActivity(`Bootstrap error: ${String(err.message || err)}`, "error");
    } finally {
      updateThresholdControlState();
      validateThresholdInput();
      updateContextEstimate();
      renderCommandList();
    }
  }

  function initializeApp() {
    setPrimaryView("workspace");

    on("sendChat", "click", handleChatSend);
    on("cancelChat", "click", cancelChat);
    on("reconnectNow", "click", probeConnection);
    on("clearHistory", "click", clearPromptHistory);
    on("clearContext", "click", clearContextBuffer);
    on("summarizeContext", "click", summarizeContext);

    on("switchDevice", "click", switchDevice);
    on("setPolicy", "click", setPolicy);
    on("setThreshold", "click", setThreshold);
    on("refreshStatus", "click", refreshStatus);
    on("fetchMetrics", "click", () => fetchMetrics(false));
    on("fetchMemory", "click", () => fetchMemoryEvidence(false));

    // Sparkline hover tooltip
    const sparkCanvas = el("npuSparkline");
    if (sparkCanvas) {
      sparkCanvas.style.cursor = "crosshair";
      sparkCanvas.addEventListener("mousemove", (e) => {
        const rect = sparkCanvas.getBoundingClientRect();
        const mouseX = (e.clientX - rect.left) * (sparkCanvas.width / rect.width);
        const n = sparkPoints.length;
        if (!n) { sparkHoverIdx = -1; drawSparkline(); return; }
        let closest = 0, closestDist = Infinity;
        for (let i = 0; i < n; i++) {
          const px = (i / Math.max(1, SPARK_MAX - 1)) * sparkCanvas.width;
          const d = Math.abs(px - mouseX);
          if (d < closestDist) { closestDist = d; closest = i; }
        }
        sparkHoverIdx = closest;
        drawSparkline();
      });
      sparkCanvas.addEventListener("mouseleave", () => {
        sparkHoverIdx = -1;
        drawSparkline();
      });
    }

    on("refreshModels", "click", async () => {
      try {
        const result = await refreshModelRegistry();
        printJson(el("registryOutput"), result);
      } catch (err) {
        el("registryOutput").textContent = String(err.message || err);
      }
    });

    on("refreshBackends", "click", async () => {
      try {
        const result = await refreshBackendRegistry();
        printJson(el("registryOutput"), result);
      } catch (err) {
        el("registryOutput").textContent = String(err.message || err);
      }
    });

    on("selectModel", "click", selectModel);
    on("importModel", "click", importModel);
    on("selectBackend", "click", selectBackend);
    on("addBackend", "click", addBackend);

    on("modelSelect", "change", renderModelDetails);
    on("backendSelect", "change", renderBackendDetails);

    on("registrySearch", "input", renderRegistryExplorer);
    on("registryTabModels", "click", () => switchRegistryTab("models"));
    on("registryTabBackends", "click", () => switchRegistryTab("backends"));

    on("openBackendWizard", "click", showBackendWizard);
    on("wizardCancel", "click", closeBackendWizard);
    on("wizardSaveBackend", "click", saveBackendFromWizard);

    on("openCommandPalette", "click", openCommandPalette);
    on("tabWorkspace", "click", () => setPrimaryView("workspace"));
    on("tabControl", "click", () => setPrimaryView("control"));
    on("commandClose", "click", closeCommandPalette);
    on("commandInput", "input", renderCommandList);
    on("commandInput", "keydown", handleCommandInputKeydown);

    for (const toggle of document.querySelectorAll(".feature-toggle")) {
      toggle.addEventListener("change", () => {
        handleFeatureToggleChange(toggle);
      });
    }

    for (const presetButton of document.querySelectorAll(".threshold-preset")) {
      presetButton.addEventListener("click", () => {
        const value = Number(presetButton.dataset.value);
        applyThresholdPreset(value);
      });
    }

    for (const presetButton of document.querySelectorAll(".context-preset")) {
      presetButton.addEventListener("click", () => {
        const value = Number(presetButton.dataset.value);
        applyContextPreset(value);
      });
    }

    on("thresholdInput", "input", validateThresholdInput);
    on("chatInput", "input", updateContextEstimate);
    on("contextWindow", "input", updateContextEstimate);
    on("chatDeviceTarget", "change", handleDeviceTargetChange);
    on("buildTerminalCommand", "click", buildTerminalCommand);
    on("copyTerminalCommand", "click", copyTerminalCommand);
    on("applyBackendPreset", "click", applyBackendPreset);
    on("terminalModelRepo", "input", buildTerminalCommand);
    on("terminalModelId", "input", buildTerminalCommand);

    for (const preset of document.querySelectorAll(".model-preset")) {
      preset.addEventListener("click", () => applyModelPreset(preset));
    }

    renderPromptHistory();
    setRuntimeStrip();
    bindGlobalShortcuts();
    startConnectionPolling();
    startPerformancePolling();
    bootstrap();
  }

  window.addEventListener("error", (event) => {
    const status = el("statusOutput");
    if (status) {
      status.textContent = `UI runtime error: ${event.message}`;
    }
    addActivity(`UI error: ${event.message}`, "error");
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initializeApp, { once: true });
  } else {
    initializeApp();
  }
}
