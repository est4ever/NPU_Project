if (window.__NPU_APP_SHELL_LOADED__) {
  console.warn("[ui] app.js already loaded; skipping duplicate initialization");
} else {
  window.__NPU_APP_SHELL_LOADED__ = true;

  const el = (id) => document.getElementById(id);

  const HISTORY_KEY = "npu-app-shell.prompt-history.v1";
  const MAX_HISTORY_ITEMS = 20;

  let activeChatAbortController = null;
  let healthPollTimer = null;
  let perfPollTimer = null;
  let isChatBusy = false;
  let cliEventsSource = null;
  let cliEventsReconnectTimer = null;
  let cliEventsConnected = false;
  let cliThinking = false;
  let connectionState = "checking";
  let connectionDetail = "";

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
  let uiTheme = "light";
  let apiBaseSaveTimer = null;
  let stackRestartCountdown = null;
  let systemFeedbackTimer = null;
  let selectedRegistryItem = null;
  let lastInferenceStats = {
    device: "-",
    tps: 0,
    ttft_ms: null,
    tpot_ms: null,
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
    restartCliEvents();
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

  function renderConnectionBadge() {
    const badge = el("connBadge");
    if (!badge) return;

    badge.classList.remove("online", "offline", "checking", "thinking");
    badge.classList.add(connectionState);
    badge.classList.toggle("thinking", connectionState === "online" && cliThinking);

    const suffix = connectionDetail ? ` - ${connectionDetail}` : "";
    if (connectionState === "online") {
      const thinkingText = cliThinking ? " - CLI active" : "";
      badge.textContent = `API: online${suffix}${thinkingText}`;
    } else if (connectionState === "offline") {
      badge.textContent = `API: offline${suffix}`;
    } else {
      badge.textContent = "API: checking";
    }
  }

  function setConnectionState(state, detail) {
    connectionState = state;
    connectionDetail = detail || "";
    renderConnectionBadge();
  }

  function setCliThinking(thinking) {
    cliThinking = !!thinking;
    renderConnectionBadge();
  }

  function stopCliEvents() {
    if (cliEventsReconnectTimer) {
      clearTimeout(cliEventsReconnectTimer);
      cliEventsReconnectTimer = null;
    }
    if (cliEventsSource) {
      cliEventsSource.close();
      cliEventsSource = null;
    }
    cliEventsConnected = false;
  }

  function scheduleCliEventsReconnect() {
    if (cliEventsReconnectTimer) return;
    cliEventsReconnectTimer = setTimeout(() => {
      cliEventsReconnectTimer = null;
      startCliEvents();
    }, 1500);
  }

  function handleCliHeartbeat(payload) {
    if (!payload || typeof payload !== "object") return;

    statusCache = {
      ...(statusCache || {}),
      active_device: payload.active_device || statusCache?.active_device || "-",
      policy: payload.policy || statusCache?.policy || "BALANCED",
      devices: Array.isArray(payload.loaded_devices)
        ? payload.loaded_devices
        : (statusCache?.devices || []),
    };

    if (Number.isFinite(Number(payload.throughput))) {
      lastInferenceStats.tps = Number(payload.throughput);
    }
    if (Number.isFinite(Number(payload.ttft_ms)) && Number(payload.ttft_ms) > 0) {
      lastInferenceStats.ttft_ms = Number(payload.ttft_ms);
    }
    if (Number.isFinite(Number(payload.tpot_ms)) && Number(payload.tpot_ms) > 0) {
      lastInferenceStats.tpot_ms = Number(payload.tpot_ms);
    }
    if (payload.active_device) {
      lastInferenceStats.device = payload.active_device;
    }

    setCliThinking(Boolean(payload.thinking));
    cliEventsConnected = true;
    setConnectionState("online", "events");
    setRuntimeStrip();
  }

  function startCliEvents() {
    const root = baseUrl().replace(/\/$/, "");
    if (!root) return;

    stopCliEvents();

    const eventsUrl = `${root}/cli/events`;
    try {
      const source = new EventSource(eventsUrl);
      cliEventsSource = source;

      source.addEventListener("heartbeat", (event) => {
        try {
          const payload = JSON.parse(event.data || "{}");
          handleCliHeartbeat(payload);
        } catch {
          // Ignore malformed heartbeat frames.
        }
      });

      source.onopen = () => {
        cliEventsConnected = true;
        if (connectionState !== "offline") {
          setConnectionState("online", "events");
        }
      };

      source.onerror = () => {
        if (cliEventsSource === source) {
          cliEventsConnected = false;
          setCliThinking(false);
          source.close();
          cliEventsSource = null;
          if (connectionState !== "offline") {
            setConnectionState("checking", "events reconnecting");
          }
          scheduleCliEventsReconnect();
        }
      };
    } catch {
      scheduleCliEventsReconnect();
    }
  }

  function restartCliEvents() {
    stopCliEvents();
    startCliEvents();
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

  const PREFS_KEY = "acoulm" + ".ui.prefs.v1";
  function loadPrefs() {
    try {
      return JSON.parse(localStorage.getItem(PREFS_KEY) || "{}");
    } catch {
      return {};
    }
  }
  function savePrefs(partial) {
    const next = { ...loadPrefs(), ...partial };
    localStorage.setItem(PREFS_KEY, JSON.stringify(next));
  }

  function applyTheme(mode) {
    document.body.dataset.theme = mode === "dark" ? "dark" : "light";
  }

  async function requestJson(path, options = {}, allowFallback = true) {
    const currentBase = baseUrl();
    try {
      const { headers: optHeaders, ...restFetch } = options;
      const response = await fetch(`${currentBase}${path}`, {
        ...restFetch,
        headers: { "Content-Type": "application/json", ...(optHeaders || {}) },
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
        if (el("chatInput")) el("chatInput").value = item;
      });
      li.appendChild(button);
      container.appendChild(li);
    }
  }

  function clearPromptHistory() {
    localStorage.removeItem(HISTORY_KEY);
    renderPromptHistory();
    addActivity("Prompt history cleared", "ready");
  }

  function clearContextBuffer() {
    addActivity("Context cleared", "ready");
  }

  function setPrimaryView(nextView) {
    activeView = nextView;
    document.body.classList.remove("view-workspace", "view-control");
    document.body.classList.add(nextView === "control" ? "view-control" : "view-workspace");

    el("tabWorkspace")?.classList.toggle("active", nextView === "workspace");
    el("tabControl")?.classList.toggle("active", nextView === "control");
    savePrefs({ activeView: nextView });
  }

  function setRuntimeStrip() {
    const active = normalizeDevice(statusCache?.active_device || "-") || "-";
    const policy = statusCache?.policy || "-";
    const profile = statusCache?.performance_profile || "";
    const lastDevice = normalizeDevice(lastInferenceStats.device || "-") || "-";
    const lastTps = Number.isFinite(lastInferenceStats.tps) ? lastInferenceStats.tps.toFixed(1) : "-";
    const lastTtft = Number.isFinite(lastInferenceStats.ttft_ms) ? `${lastInferenceStats.ttft_ms.toFixed(0)} ms` : "-";
    const lastTpot = Number.isFinite(lastInferenceStats.tpot_ms) ? `${lastInferenceStats.tpot_ms.toFixed(1)} ms/tok` : "-";
    const loadedDevices = Array.isArray(statusCache?.devices)
      ? statusCache.devices.map((d) => normalizeDevice(d)).filter(Boolean)
      : [];
    const availableDevices = Array.isArray(statusCache?.available_devices)
      ? statusCache.available_devices.map((item) => normalizeDevice(item?.id || item)).filter(Boolean)
      : [];

    if (el("chatActiveDevice")) el("chatActiveDevice").textContent = active;
    if (el("chatPolicyValue"))  el("chatPolicyValue").textContent  = profile ? `${policy} (${profile})` : policy;
    if (el("chatLastDevice"))   el("chatLastDevice").textContent   = lastDevice;
    if (el("chatLastTps"))      el("chatLastTps").textContent      = lastTps;
    if (el("chatLastTtft"))     el("chatLastTtft").textContent     = lastTtft;
    if (el("chatLastTpot"))     el("chatLastTpot").textContent     = lastTpot;
    if (el("chatDeviceAvailability")) {
      const loadedText = loadedDevices.length
        ? `Loaded devices: ${loadedDevices.join(", ")}`
        : "Loaded devices: (none)";
      const availableText = availableDevices.length
        ? ` | Runtime also reports: ${availableDevices.join(", ")}`
        : "";
      el("chatDeviceAvailability").textContent = `${loadedText}${availableText}`;
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
    applyToSelect("wDeviceSelect");
  }

  function syncChatModelOptions(selectedHint = "") {
    const modelSelect = el("chatModel");
    if (!modelSelect) return;

    const preferred = selectedHint || statusCache?.selected_model || modelSelect.value || "local";
    const items = modelRegistryCache.length
      ? modelRegistryCache.map((m) => m.id)
      : [preferred || "local"];

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
      setChip("rSplitPrefill", "split-prefill: off", "ready");
    }

    const contextRoutingOn = normalizeOnOff(status.context_routing);
    const optimizeMemoryOn = normalizeOnOff(status.optimize_memory);
    setChip("rContextRouting", `context-routing: ${contextRoutingOn ? "on" : "off"}`, contextRoutingOn ? "ready" : "ready");
    setChip("rOptimizeMemory", `optimize-memory: ${optimizeMemoryOn ? "on" : "off"}`, optimizeMemoryOn ? "ready" : "ready");

    const proc = (memoryCache?.process && typeof memoryCache.process === "object") ? memoryCache.process : null;
    const privateMb = Number(proc?.private_mb);
    const workingSetMb = Number(proc?.working_set_mb);
    if (Number.isFinite(privateMb) && privateMb > 0) {
      const privateGb = (privateMb / 1024).toFixed(1);
      const wsGb = Number.isFinite(workingSetMb) && workingSetMb > 0 ? (workingSetMb / 1024).toFixed(1) : null;
      if (wsGb) {
        setChip("rLoomisMemory", `loomis-mem: ${privateGb} GB (ws ${wsGb} GB)`, "ready");
      } else {
        setChip("rLoomisMemory", `loomis-mem: ${privateGb} GB`, "ready");
      }
    } else {
      setChip("rLoomisMemory", "loomis-mem: -", "busy");
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
    if (el("tpsValue")) el("tpsValue").textContent = displayTps.toFixed(1);

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
      if (el("wDeviceSelect")) {
        el("wDeviceSelect").value = normalizeDevice(result.active_device) || el("wDeviceSelect").value;
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
      if (el("wPolicySelect")) {
        el("wPolicySelect").value = result.policy || el("wPolicySelect").value;
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

      const autoModelToggle = el("autoModelSelectToggle");
      if (autoModelToggle) {
        autoModelToggle.checked = Boolean(result.auto_select_best_model);
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
      if (statusCache) {
        renderReadinessBar(statusCache);
      }
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
    const renameRow =
      registryView === "models"
        ? `<div class="registry-rename-row">
        <label class="registry-rename-label">New ID <input type="text" class="registry-rename-input" placeholder="unique registry id" autocomplete="off" /></label>
        <button type="button" class="ghost registry-action-rename">Rename ID</button>
      </div>`
        : "";
    const descRaw = item.description ? String(item.description) : "";
    const descSafe = descRaw
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/"/g, "&quot;");
    const descBlock = descSafe ? `<p class="hint registry-detail-desc">${descSafe}</p>` : "";

    detailEl.innerHTML = `
      <div class="registry-detail-head">
        <span class="registry-detail-title">${item.id}</span>
        <span class="registry-chip ${state}">${stateLabel}</span>
      </div>
      <div class="registry-tags">
        ${tags.map((t) => `<span class="registry-tag">${t}</span>`).join("")}
      </div>
      ${descBlock}
      ${pathValue ? `<div class="registry-path" title="${pathValue}">&#x1F4C1; ${pathName}</div>` : ""}
      <div class="registry-detail-actions">
        <button type="button" class="ghost registry-action-select">${selectLabel}</button>
        <button type="button" class="ghost registry-action-raw">{ } Raw JSON</button>
      </div>
      ${renameRow}
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

    if (registryView === "models") {
      const renameBtn = detailEl.querySelector(".registry-action-rename");
      const renameInput = detailEl.querySelector(".registry-rename-input");
      renameBtn?.addEventListener("click", () => {
        const toId = String(renameInput?.value || "").trim();
        renameModelId(item.id, toId, renameInput, renameBtn);
      });
      renameInput?.addEventListener("keydown", (ev) => {
        if (ev.key === "Enter") {
          ev.preventDefault();
          const toId = String(renameInput?.value || "").trim();
          renameModelId(item.id, toId, renameInput, renameBtn);
        }
      });
    }

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

  function getPrimaryDeviceSelect() {
    return el("wDeviceSelect") || el("deviceSelect");
  }

  function getPrimaryPolicySelect() {
    return el("wPolicySelect") || el("policySelect");
  }

  async function switchDevice() {
    try {
      const select = getPrimaryDeviceSelect();
      const target = normalizeDevice(select?.value || "");
      if (!target) {
        throw new Error("Select a target device first");
      }
      addActivity("Checking NPU route...", "busy");
      await requestJson("/cli/device/load", {
        method: "POST",
        body: JSON.stringify({ device: target }),
      });
      const result = await requestJson("/cli/device/switch", {
        method: "POST",
        body: JSON.stringify({ device: target }),
      });
      printJson(el("devicePolicyOutput"), result);
      addActivity(`Device switched to ${result.new_active_device || target}`, "ready");
      await refreshStatus();
    } catch (err) {
      el("devicePolicyOutput").textContent = String(err.message || err);
      addActivity(`Device switch failed: ${String(err.message || err)} | Try CPU fallback while debugging accelerator drivers`, "error");
    }
  }

  async function setPolicy() {
    try {
      const select = getPrimaryPolicySelect();
      const policy = select?.value || "";
      const result = await requestJson("/cli/policy", {
        method: "POST",
        body: JSON.stringify({ policy }),
      });
      printJson(el("devicePolicyOutput"), result);
      const profileText = result.performance_profile ? ` (${result.performance_profile})` : "";
      addActivity(`Policy set to ${result.new_policy || policy}${profileText}`, "ready");
      await refreshStatus();
    } catch (err) {
      el("devicePolicyOutput").textContent = String(err.message || err);
      addActivity(`Policy change failed: ${String(err.message || err)}`, "error");
    }
  }

  async function loadDevice() {
    try {
      const target = normalizeDevice(el("loadDeviceSelect")?.value || "");
      if (!target) {
        throw new Error("Select a device to load first");
      }
      addActivity(`Loading model on ${target}...`, "busy");
      const result = await requestJson("/cli/device/load", {
        method: "POST",
        body: JSON.stringify({ device: target }),
      });
      el("loadStatus").textContent = `✓ Model loaded on ${target}`;
      el("loadStatus").className = "status-indicator success";
      addActivity(`Model loaded on ${target} (ready for switching)`, "ready");
      await refreshStatus();
    } catch (err) {
      el("loadStatus").textContent = `✗ Load failed: ${String(err.message || err)}`;
      el("loadStatus").className = "status-indicator error";
      addActivity(`Device load failed: ${String(err.message || err)}`, "error");
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

  function setFeatureConfirmation(message, type = "ready") {
    const target = el("featureConfirmation");
    if (!target) return;
    target.textContent = message;
    target.className = `feature-confirmation ${type}`;
  }

  async function handleFeatureToggleChange(toggle) {
    const output = el("featuresOutput");
    const feature = toggle.dataset.feature;
    const desiredState = toggle.checked;

    toggle.disabled = true;
    try {
      const result = await setFeatureToggle(feature, desiredState);
      const statusText = `${feature}: ${result.status}`;
      output.textContent = `${statusText}\nRefreshing runtime state...`;
      setFeatureConfirmation(`Updated ${feature} → ${result.status}. Runtime state refreshed.`);
      addActivity(`Feature ${feature} -> ${result.status}`, "ready");
    } catch (err) {
      toggle.checked = !desiredState;
      const message = friendlyFeatureError(feature, err);
      output.textContent = message;
      setFeatureConfirmation(message, "error");
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

  async function saveAutoModelSelectSetting() {
    const output = el("featuresOutput");
    const toggle = el("autoModelSelectToggle");
    if (!toggle) return;
    const enabled = !!toggle.checked;

    try {
      setButtonBusy("saveAutoModelSelect", true, "Saving...");
      const result = await requestJson("/cli/model/auto-select", {
        method: "POST",
        body: JSON.stringify({ enabled }),
      });
      printJson(output, result);
      addActivity(`Auto model select ${enabled ? "enabled" : "disabled"} (applies on next launch)`, "ready");
      setFeatureConfirmation(`Auto model select ${enabled ? "enabled" : "disabled"}. Restart via loomis/start_app to apply.`);
      await refreshStatus();
    } catch (err) {
      output.textContent = String(err.message || err);
      addActivity("Auto model select update failed", "error");
      setFeatureConfirmation(`Auto model select update failed: ${String(err.message || err)}`, "error");
    } finally {
      setButtonBusy("saveAutoModelSelect", false);
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
      if (result.warning) {
        appendText(output, `\n\n${result.warning}`);
        addActivity(String(result.warning), "busy");
      }
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

  function detectModelFormat(path) {
    const lowerPath = String(path).toLowerCase();
    if (lowerPath.endsWith(".gguf")) return "gguf";
    if (lowerPath.endsWith(".bin") || lowerPath.endsWith(".pt")) return "pytorch";
    if (lowerPath.endsWith(".xml") || lowerPath.endsWith(".onnx")) return "openvino";
    return "";
  }

  async function renameModelId(fromId, toId, inputEl, busyButton) {
    const output = el("registryOutput");
    if (!fromId || !toId) {
      if (output) output.textContent = "Rename requires the current id and a new id.";
      return;
    }
    const origLabel = busyButton?.textContent;
    try {
      if (busyButton) {
        busyButton.disabled = true;
        busyButton.textContent = "Renaming...";
      }
      const result = await requestJson("/cli/model/rename", {
        method: "POST",
        body: JSON.stringify({ from_id: fromId, to_id: toId }),
      });
      if (output) printJson(output, result);
      addActivity(`Model id renamed: ${fromId} → ${toId}`, "ready");
      await refreshModelRegistry();
      const updated = modelRegistryCache.find((m) => m.id === toId);
      if (updated && registryView === "models") {
        renderRegistryDetailCard(updated);
        if (inputEl) inputEl.value = "";
      }
      await refreshStatus();
    } catch (err) {
      if (output) output.textContent = String(err.message || err);
      addActivity(`Model rename failed: ${String(err.message || err)}`, "error");
    } finally {
      if (busyButton) {
        busyButton.disabled = false;
        busyButton.textContent = origLabel ?? "Rename ID";
      }
    }
  }

  async function importModel() {
    const output = el("registryOutput");
    const id = el("modelImportId").value.trim();
    const path = el("modelImportPath").value.trim();
    let format = el("modelImportFormat").value.trim();
    
    // Auto-detect format from path if not provided
    if (!format) {
      format = detectModelFormat(path);
    }
    
    const backend = el("backendSelect").value || "";

    if (!id || !path) {
      output.textContent = "Model import requires id and path.";
      return;
    }
    
    if (!format) {
      output.textContent = "Could not detect model format. Please specify (gguf, ir, onnx, pytorch, etc.).";
      return;
    }

    try {
      setButtonBusy("importModel", true, "Importing...");
      const result = await requestJson("/cli/model/import", {
        method: "POST",
        body: JSON.stringify({ id, path, format, backend, status: "ready" }),
      });
      printJson(output, result);
      if (result.warning) {
        appendText(output, `\n\n${result.warning}`);
        addActivity(String(result.warning), "busy");
      }
      addActivity(`Model imported: ${id}`, "ready");
      await refreshModelRegistry();
      el("modelImportId").value = "";
      el("modelImportPath").value = "";
      el("modelImportFormat").value = "";
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
      addActivity(`Backend selected: ${id} — restarting process...`, "busy");
      await refreshBackendRegistry();

      try {
        const restartResult = await requestJson("/cli/backend/restart", {
          method: "POST",
          body: JSON.stringify({}),
        });
        appendText(output, `\n\n${restartResult.note || "Restart scheduled."}`);
      } catch (restartErr) {
        const rmsg = String(restartErr.message || restartErr);
        if (/failed to fetch|network|load failed|aborted|fetch/i.test(rmsg)) {
          appendText(
            output,
            "\n\nBackend is restarting (connection dropped). Wait a few seconds, then click Refresh Status."
          );
          addActivity("Backend restart in progress — reconnect shortly.", "busy");
        } else {
          appendText(output, `\n\nRestart failed: ${rmsg}`);
          showRestartRequired(output);
          addActivity(`Backend restart failed: ${rmsg}`, "error");
        }
      }

      try {
        await refreshStatus();
      } catch (_) {
        /* expected while process exits */
      }
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
        body: JSON.stringify({ id, type, entrypoint, formats: [] }),
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
        const lowered = String(loadErr.message || loadErr).toLowerCase();
        const extraHint = lowered.includes("gpu")
          ? " | Hint: verify GPU runtime/driver for your stack and try another device if needed"
          : "";
        addActivity(
          `Could not load model on ${target}: ${String(loadErr.message || loadErr)}${extraHint}`,
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

  function buildTerminalCommand() {
    const repo = String(el("terminalModelRepo")?.value || "").trim();
    const id = String(el("terminalModelId")?.value || "").trim();
    const filename = String(el("terminalModelFilename")?.value || "").trim();
    const preview = el("terminalCommandPreview");
    if (!preview) return;
    const localId = id || (repo.split("/").pop() || "my-model");
    if (!repo) {
      preview.textContent = `.\\npu_cli.ps1 -Command model -Arguments "download","<repo>","<local-id>","[filename]"`;
    } else if (filename) {
      preview.textContent = `.\\npu_cli.ps1 -Command model -Arguments "download","${repo}","${localId}","${filename}"`;
    } else {
      preview.textContent = `.\\npu_cli.ps1 -Command model -Arguments "download","${repo}","${localId}"`;
    }
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
    if (output) {
      output.textContent = [
        "Summarize is disabled in terminal-chat mode.",
        "Use terminal chat instead:",
        ".\\npu_cli.ps1 -Command chat -Arguments \"Summarize the latest context and key decisions\"",
      ].join("\n");
    }
    addActivity("Summarize disabled: terminal-chat mode", "busy");
  }

  async function probeConnection() {
    setConnectionState("checking");
    try {
      const result = await requestJson("/health", { method: "GET" });
      if (!cliEventsConnected) {
        startCliEvents();
      }
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
      id: "readiness",
      label: "Refresh Readiness / Health",
      keywords: "readiness health path model port",
      action: () => refreshReadinessUI(),
    },
    {
      id: "restart-stack",
      label: "Restart Full Stack",
      keywords: "restart backend app shell",
      action: () => restartFullStack(),
    },
    {
      id: "validate-model",
      label: "Validate Selected Model (disk check)",
      keywords: "validate model ir gguf",
      action: () => validateSelectedModel(),
    },
    {
      id: "device-recommend",
      label: "Device Recommendation (from metrics)",
      keywords: "tps recommendation device",
      action: () => loadDeviceRecommend(),
    },
    {
      id: "export-diag",
      label: "Export Diagnostics Zip",
      keywords: "support zip logs",
      action: () => exportDiagnosticsZip(),
    },
    {
      id: "run-benchmark",
      label: "Run Benchmark Prompts",
      keywords: "bench ttft tpot",
      action: () => runBenchmarkSuite(),
    },
    {
      id: "discover-models",
      label: "Discover Unregistered models\\ Folders",
      keywords: "discover import folder",
      action: () => loadDiscoverList(),
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
    try {
      await Promise.all([
        refreshStatus(),
        refreshModelRegistry(),
        refreshBackendRegistry(),
        fetchMetrics(true, "last"),
        fetchMemoryEvidence(true),
      ]);
      addActivity("Runtime ready", "ready");
      setRuntimeStrip();
    } catch (err) {
      el("statusOutput").textContent = String(err.message || err);
      addActivity(`Bootstrap error: ${String(err.message || err)}`, "error");
    } finally {
      updateThresholdControlState();
      validateThresholdInput();
      renderCommandList();
    }
  }

  function clearStackRestartCountdown() {
    if (stackRestartCountdown) {
      clearInterval(stackRestartCountdown);
      stackRestartCountdown = null;
    }
  }

  function setSystemFeedback(message, kind = "neutral") {
    const node = el("systemFeedback");
    if (!node) {
      return;
    }
    if (systemFeedbackTimer) {
      clearTimeout(systemFeedbackTimer);
      systemFeedbackTimer = null;
    }
    const text = String(message || "").trim();
    if (!text) {
      node.textContent = "";
      node.hidden = true;
      node.removeAttribute("data-kind");
      return;
    }
    node.textContent = text;
    node.hidden = false;
    node.dataset.kind = kind;
    systemFeedbackTimer = setTimeout(() => {
      node.textContent = "";
      node.hidden = true;
      node.removeAttribute("data-kind");
      systemFeedbackTimer = null;
    }, 14000);
  }

  function formatHttpProbe(v) {
    if (v == null) {
      return "—";
    }
    if (typeof v === "string") {
      return v;
    }
    if (typeof v === "object" && typeof v.reachable === "boolean") {
      if (!v.reachable) {
        return v.status != null ? `Unreachable · HTTP ${v.status}` : "Unreachable";
      }
      return v.status != null ? `OK · HTTP ${v.status}` : "OK";
    }
    if (typeof v === "object" && v.ok != null) {
      return v.ok ? "OK" : "Failed";
    }
    try {
      return JSON.stringify(v);
    } catch {
      return String(v);
    }
  }

  function formatModelAnalysisLines(ma) {
    if (!ma || typeof ma !== "object") {
      return [];
    }
    const lines = [];
    if (ma.exists != null) {
      lines.push(ma.exists ? "Path exists on disk" : "Path missing");
    }
    if (ma.kind) {
      lines.push(`Type: ${ma.kind}`);
    }
    if (ma.openvino_ir != null) {
      lines.push(ma.openvino_ir ? "OpenVINO IR present" : "No OpenVINO IR");
    }
    if (ma.gguf_count != null) {
      const n = Number(ma.gguf_count);
      lines.push(Number.isFinite(n) && n > 0 ? `${n} GGUF file(s)` : "No GGUF files");
    }
    if (ma.has_safetensors) {
      lines.push("Safetensors present");
    }
    if (ma.runnable_hint) {
      lines.push(`Runnable: ${ma.runnable_hint}`);
    }
    return lines;
  }

  async function refreshReadinessUI() {
    const out = el("readinessOutput");
    const sum = el("readinessSummary");
    try {
      const data = await requestJson("/cli/readiness", { method: "GET" });
      printJson(out, data);
      if (sum) {
        sum.textContent = "";
        const row = (label, value) => {
          const wrap = document.createElement("div");
          wrap.className = "readiness-summary-row";
          const lb = document.createElement("span");
          lb.className = "readiness-summary-label";
          lb.textContent = label;
          const val = document.createElement("span");
          val.className = "readiness-summary-value";
          val.textContent = value;
          wrap.appendChild(lb);
          wrap.appendChild(val);
          sum.appendChild(wrap);
        };
        row("API port", data.api_port != null ? String(data.api_port) : "—");
        row("/v1/health", formatHttpProbe(data.api_health));
        row("App shell :5173", formatHttpProbe(data.app_shell_5173));
        if (data.selected_model_id) {
          row("Selected model", String(data.selected_model_id));
        }
        if (data.model_path) {
          row("Model path", String(data.model_path));
        }
        const maLines = formatModelAnalysisLines(data.model_analysis);
        if (maLines.length) {
          const block = document.createElement("div");
          block.className = "readiness-summary-block";
          const bt = document.createElement("div");
          bt.className = "readiness-summary-block-title";
          bt.textContent = "Model on disk";
          block.appendChild(bt);
          for (const line of maLines) {
            const ln = document.createElement("div");
            ln.className = "readiness-summary-block-line";
            ln.textContent = line;
            block.appendChild(ln);
          }
          sum.appendChild(block);
        }
        if (data.last_error) {
          const errPreview =
            String(data.last_error).length > 220
              ? `${String(data.last_error).slice(0, 220)}…`
              : String(data.last_error);
          row("Last error log", errPreview);
        } else {
          row("Last error log", "(none)");
        }
      }
      setSystemFeedback("Readiness refreshed.", "ok");
    } catch (err) {
      const msg = String(err.message || err);
      if (out) {
        out.textContent = msg;
      }
      if (sum) {
        sum.textContent = "";
        const wrap = document.createElement("div");
        wrap.className = "readiness-summary-row readiness-summary-error";
        wrap.textContent = `Could not load readiness: ${msg}`;
        sum.appendChild(wrap);
      }
      setSystemFeedback(`Readiness failed: ${msg}`, "error");
    }
  }

  async function restartFullStack() {
    clearStackRestartCountdown();
    const c = el("restartCountdown");
    try {
      setButtonBusy("btnRestartStack", true, "Restarting…");
      await requestJson("/cli/stack/restart", { method: "POST", body: "{}" });
      addActivity("Full stack restart scheduled (backend + app shell)", "ready");
      setSystemFeedback("Full stack restart scheduled. This window may disconnect in a few seconds.", "ok");
      let n = 12;
      if (c) {
        c.textContent = `Reconnect: ${n}s`;
      }
      stackRestartCountdown = setInterval(() => {
        n -= 1;
        if (c) {
          c.textContent = n > 0 ? `Reconnect: ${n}s` : "Reload the page or click Refresh status";
        }
        if (n <= 0) {
          clearStackRestartCountdown();
        }
      }, 1000);
    } catch (err) {
      const m = String(err.message || err);
      addActivity(`Stack restart request failed: ${m}`, "error");
      setSystemFeedback(`Restart request failed: ${m}`, "error");
    } finally {
      setButtonBusy("btnRestartStack", false);
    }
  }

  async function probeLocalBackendHealth() {
    try {
      setButtonBusy("btnStackProbe", true);
      const d = await requestJson("/cli/backend/probe", { method: "GET" });
      printJson(el("readinessOutput"), d);
      addActivity("Local API probe complete", "ready");
      const h = d && d.v1_health_check;
      setSystemFeedback(
        h && typeof h.reachable === "boolean"
          ? h.reachable
            ? "Probe: API /v1/health reachable."
            : "Probe: API not reachable."
          : "Probe finished — see Readiness JSON.",
        "ok"
      );
    } catch (err) {
      const m = String(err.message || err);
      addActivity(`Probe failed: ${m}`, "error");
      setSystemFeedback(`Probe failed: ${m}`, "error");
    } finally {
      setButtonBusy("btnStackProbe", false);
    }
  }

  async function validateSelectedModel() {
    const id = (el("modelSelect") && el("modelSelect").value) || "";
    try {
      setButtonBusy("btnModelValidate", true);
      const data = await requestJson("/cli/model/validate", {
        method: "POST",
        body: JSON.stringify({ id }),
      });
      addActivity(`Validated: ${data.id || id}`, "ready");
      printJson(el("readinessOutput"), data);
      const hints = formatModelAnalysisLines(data.analysis);
      setSystemFeedback(
        hints.length
          ? `Validate OK · ${data.id || id} — ${hints[0]}`
          : `Validate OK · ${data.id || id}`,
        "ok"
      );
    } catch (err) {
      const m = String(err.message || err);
      addActivity(`Validate failed: ${m}`, "error");
      setSystemFeedback(`Validate failed: ${m}`, "error");
    } finally {
      setButtonBusy("btnModelValidate", false);
    }
  }

  async function loadDeviceRecommend() {
    try {
      setButtonBusy("btnDeviceRecommend", true);
      const d = await requestJson("/cli/metrics/recommendation", { method: "GET" });
      printJson(el("readinessOutput"), d);
      const best = d.suggested_device;
      if (best) {
        addActivity(
          `By recent metrics, ${best} had best average TPS (${(d.avg_throughput || 0).toFixed(1)} tok/s). See JSON for detail.`,
          "ready"
        );
        setSystemFeedback(
          `Recommendation: try device ${best} (~${(d.avg_throughput || 0).toFixed(1)} tok/s avg). Details in Readiness JSON.`,
          "ok"
        );
      } else {
        addActivity("No TPS history yet for device recommendations.", "busy");
        setSystemFeedback("No throughput history yet — run a few chats or benchmarks first.", "neutral");
      }
    } catch (err) {
      const m = String(err.message || err);
      addActivity(`Recommendation failed: ${m}`, "error");
      setSystemFeedback(`Recommendation failed: ${m}`, "error");
    } finally {
      setButtonBusy("btnDeviceRecommend", false);
    }
  }

  async function exportDiagnosticsZip() {
    try {
      setButtonBusy("btnExportDiag", true);
      const d = await requestJson("/cli/diagnostics/export", { method: "POST", body: "{}" });
      addActivity(
        d.zip_path
          ? `Diagnostics zip: ${d.zip_path}`
          : "Export finished — see readiness JSON for path.",
        "ready"
      );
      printJson(el("readinessOutput"), d);
      if (d.zip_path) {
        setSystemFeedback(`Diagnostics zip: ${d.zip_path}`, "ok");
      } else {
        setSystemFeedback("Export reported success — check Readiness JSON for path.", "ok");
      }
    } catch (err) {
      const m = String(err.message || err);
      addActivity(`Export failed: ${m}`, "error");
      setSystemFeedback(`Export failed: ${m}`, "error");
    } finally {
      setButtonBusy("btnExportDiag", false);
    }
  }

  const BENCH_PROMPTS = [
    "Reply with the single word: bench-1",
    "Reply with the single word: bench-2",
    "In one short phrase, name a color.",
  ];

  function renderBenchmarkTable(rows) {
    const wrap = el("benchmarkTableWrap");
    if (!wrap) {
      return;
    }
    wrap.textContent = "";
    const table = document.createElement("table");
    table.className = "bench-table";
    const thead = document.createElement("thead");
    const hr = document.createElement("tr");
    for (const h of ["#", "Wall ms", "TTFT ms", "TPOT", "TPS", "Device", "Note"]) {
      const th = document.createElement("th");
      th.textContent = h;
      hr.appendChild(th);
    }
    thead.appendChild(hr);
    table.appendChild(thead);
    const tb = document.createElement("tbody");
    for (const r of rows) {
      const tr = document.createElement("tr");
      for (const key of [
        "i",
        "wall",
        "ttft",
        "tpot",
        "tps",
        "device",
        "note",
      ]) {
        const td = document.createElement("td");
        td.textContent = r[key] != null ? String(r[key]) : "—";
        tr.appendChild(td);
      }
      tb.appendChild(tr);
    }
    table.appendChild(tb);
    wrap.appendChild(table);
  }

  async function runBenchmarkSuite() {
    setButtonBusy("btnBenchmarkRun", true);
    const rows = [];
    try {
      let modelId = "openvino";
      if (statusCache && statusCache.selected_model) {
        modelId = statusCache.selected_model;
      } else {
        try {
          const s = await requestJson("/cli/status", { method: "GET" });
          if (s && s.selected_model) {
            modelId = s.selected_model;
          }
        } catch {
          // use default
        }
      }
      for (let i = 0; i < BENCH_PROMPTS.length; i += 1) {
        const prompt = BENCH_PROMPTS[i];
        const t0 = performance.now();
        let note = "";
        try {
          await requestJson("/chat/completions", {
            method: "POST",
            headers: { "x-npu-cli": "true" },
            body: JSON.stringify({
              model: modelId,
              messages: [{ role: "user", content: prompt }],
              stream: false,
              temperature: 0.2,
              max_tokens: 64,
            }),
          });
        } catch (err) {
          note = String(err.message || err);
          rows.push({
            i: String(i + 1),
            wall: (performance.now() - t0).toFixed(0),
            ttft: "—",
            tpot: "—",
            tps: "—",
            device: "—",
            note,
          });
          continue;
        }
        const wall = (performance.now() - t0).toFixed(0);
        let m = {};
        try {
          m = await requestJson("/cli/metrics?mode=last", { method: "GET" });
        } catch {
          m = {};
        }
        rows.push({
          i: String(i + 1),
          wall,
          ttft: m.ttft_ms != null ? String(Number(m.ttft_ms).toFixed(1)) : "—",
          tpot: m.tpot_ms != null ? String(Number(m.tpot_ms).toFixed(2)) : "—",
          tps: m.throughput_tok_s != null ? String(Number(m.throughput_tok_s).toFixed(2)) : "—",
          device: m.device != null && m.device !== "" ? String(m.device) : (statusCache?.active_device || "—"),
          note: "ok",
        });
      }
      renderBenchmarkTable(rows);
      addActivity("Benchmark prompts finished (see table)", "ready");
      const failed = rows.filter((r) => r.note && r.note !== "ok");
      if (failed.length) {
        setSystemFeedback(
          `Benchmark finished with ${failed.length} failing prompt(s). Check the Note column.`,
          "error"
        );
      } else {
        setSystemFeedback("Benchmark finished — see the table below.", "ok");
      }
      try {
        await fetchMetrics(true, "last");
      } catch {
        // ignore
      }
    } catch (err) {
      setSystemFeedback(`Benchmark error: ${String(err.message || err)}`, "error");
    } finally {
      setButtonBusy("btnBenchmarkRun", false);
    }
  }

  async function loadDiscoverList() {
    const host = el("discoverModelsHost");
    if (!host) {
      return;
    }
    try {
      const d = await requestJson("/cli/models/discover", { method: "GET" });
      const un = d.unregistered || [];
      host.textContent = "";
      if (!un.length) {
        host.textContent = "No unregistered subfolders under models\\.";
        return;
      }
      for (const item of un) {
        const row = document.createElement("div");
        row.className = "discover-row";
        const label = document.createElement("span");
        label.className = "discover-name";
        label.textContent = item.folder || item.path;
        const b = document.createElement("button");
        b.type = "button";
        b.textContent = "Fill import";
        b.addEventListener("click", () => {
          if (el("modelImportId")) {
            el("modelImportId").value = item.folder || "";
          }
          if (el("modelImportPath")) {
            el("modelImportPath").value = item.path || `./models/${item.folder}`;
          }
          if (el("modelImportFormat")) {
            const det = detectModelFormat(item.path || "") || "openvino";
            el("modelImportFormat").value = det;
          }
          addActivity(`Import fields: ${item.folder}`, "ready");
        });
        row.appendChild(label);
        row.appendChild(b);
        host.appendChild(row);
      }
    } catch (err) {
      host.textContent = String(err.message || err);
    }
  }

  async function pasteImportFromClipboard() {
    try {
      const t = (await navigator.clipboard.readText()).trim();
      if (!t) {
        addActivity("Clipboard empty", "busy");
        return;
      }
      const isPath =
        t.includes("\\") ||
        /^\./.test(t) ||
        /^[a-zA-Z]:[\\/]/.test(t) ||
        t.includes("/models/") ||
        /\.(gguf|xml|onnx|bin|safetensors|json)(\s|$)/i.test(t);
      if (isPath) {
        if (el("modelImportPath")) {
          el("modelImportPath").value = t;
        }
        if (el("modelImportFormat")) {
          const det = detectModelFormat(t);
          if (det) {
            el("modelImportFormat").value = det;
          }
        }
        const base = t.replace(/[/\\]+/g, "/").split("/").filter(Boolean).pop() || "model";
        const idGuess = base.replace(/\.[^.]+$/, "");
        if (el("modelImportId") && !el("modelImportId").value) {
          el("modelImportId").value = idGuess;
        }
      } else if (t.includes("/")) {
        if (el("terminalModelRepo")) {
          el("terminalModelRepo").value = t;
        }
        const parts = t.split("/").filter(Boolean);
        const last = (parts.pop() || "model").toLowerCase();
        const localId = last.replace(/[^a-z0-9-]+/g, "-");
        if (el("terminalModelId")) {
          el("terminalModelId").value = localId;
        }
        if (el("modelImportId")) {
          el("modelImportId").value = localId;
        }
        if (el("modelImportPath")) {
          el("modelImportPath").value = `./models/${localId}`;
        }
        if (el("modelImportFormat")) {
          el("modelImportFormat").value = "gguf";
        }
        buildTerminalCommand();
      } else {
        addActivity("Could not parse clipboard (use a path or org/model-id)", "busy");
        return;
      }
      addActivity("Pasted into import (and terminal fields if repo)", "ready");
    } catch (err) {
      addActivity(`Clipboard read failed: ${String(err.message || err)}`, "error");
    }
  }

  function initializeApp() {
    const pf = loadPrefs();
    if (typeof pf.apiBase === "string" && pf.apiBase.trim()) {
      setApiBase(pf.apiBase.trim());
    }
    uiTheme = pf.theme === "dark" ? "dark" : "light";
    applyTheme(uiTheme);
    const themeSelect = el("themeSelect");
    if (themeSelect) {
      themeSelect.value = uiTheme === "dark" ? "dark" : "light";
    }
    setPrimaryView(pf.activeView === "control" ? "control" : "workspace");

    on("switchDevice", "click", switchDevice);
    on("wSwitchDevice", "click", () => {
      if (el("deviceSelect") && el("wDeviceSelect")) el("deviceSelect").value = el("wDeviceSelect").value;
      switchDevice();
    });
    on("setPolicy", "click", setPolicy);
    on("wSetPolicy", "click", () => {
      if (el("policySelect") && el("wPolicySelect")) el("policySelect").value = el("wPolicySelect").value;
      setPolicy();
    });
    on("loadDevice", "click", loadDevice);
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

    // Auto-detect format when path is entered
    if (el("modelImportPath")) {
      el("modelImportPath").addEventListener("input", () => {
        const path = el("modelImportPath").value.trim();
        if (path && !el("modelImportFormat").value) {
          const detected = detectModelFormat(path);
          if (detected) {
            el("modelImportFormat").value = detected;
          }
        }
      });
    }

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

    on("thresholdInput", "input", validateThresholdInput);
    on("saveAutoModelSelect", "click", saveAutoModelSelectSetting);
    on("buildTerminalCommand", "click", buildTerminalCommand);
    on("copyTerminalCommand", "click", copyTerminalCommand);
    on("terminalModelRepo", "input", buildTerminalCommand);
    on("terminalModelId", "input", buildTerminalCommand);
    on("terminalModelFilename", "input", buildTerminalCommand);

    for (const preset of document.querySelectorAll(".model-preset")) {
      preset.addEventListener("click", () => applyModelPreset(preset));
    }
    for (const pack of document.querySelectorAll(".model-preset-pack")) {
      pack.addEventListener("click", () => {
        if (el("modelImportId")) {
          el("modelImportId").value = pack.dataset.id || "";
        }
        if (el("modelImportPath")) {
          el("modelImportPath").value = pack.dataset.path || "";
        }
        if (el("modelImportFormat")) {
          el("modelImportFormat").value = pack.dataset.format || "openvino";
        }
        addActivity(`Preset: ${pack.dataset.id || "model"} (adjust paths as needed)`, "ready");
      });
    }

    on("themeSelect", "change", () => {
      const v = (el("themeSelect") && el("themeSelect").value) || "light";
      uiTheme = v === "dark" ? "dark" : "light";
      applyTheme(uiTheme);
      savePrefs({ theme: uiTheme });
    });
    on("apiBase", "input", () => {
      const node = el("apiBase");
      if (!node) {
        return;
      }
      clearTimeout(apiBaseSaveTimer);
      apiBaseSaveTimer = setTimeout(() => {
        savePrefs({ apiBase: node.value || defaultApiBase() });
      }, 400);
    });

    on("refreshReadiness", "click", () => {
      void refreshReadinessUI();
    });
    on("btnRestartStack", "click", () => {
      void restartFullStack();
    });
    on("btnStackProbe", "click", () => {
      void probeLocalBackendHealth();
    });
    on("btnModelValidate", "click", () => {
      void validateSelectedModel();
    });
    on("btnDeviceRecommend", "click", () => {
      void loadDeviceRecommend();
    });
    on("btnExportDiag", "click", () => {
      void exportDiagnosticsZip();
    });
    on("btnBenchmarkRun", "click", () => {
      void runBenchmarkSuite();
    });
    on("btnPasteImport", "click", () => {
      void pasteImportFromClipboard();
    });

    setRuntimeStrip();
    bindGlobalShortcuts();
    startConnectionPolling();
    startCliEvents();
    startPerformancePolling();
    bootstrap()
      .then(() =>
        Promise.all([loadDiscoverList(), refreshReadinessUI()]).catch(() => {
          // Best-effort; main panels already show bootstrap errors.
        })
      )
      .catch(() => {
        // bootstrap() already reported errors
      });
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
