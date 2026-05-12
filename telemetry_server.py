#!/usr/bin/env python3
"""
AcouLM privacy-first telemetry receiver.

- POST /telemetry        ingest one event
- GET  /telemetry/health quick health check
- GET  /telemetry/summary?days=30  rolling window (1–3650 days)
- GET  /telemetry/summary?all=1   all rows in DB (all-time)

Design goals:
- no external dependencies
- no prompt/content storage
- store only anonymized install/session ids (SHA-256 with optional salt)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def to_iso_day(iso_or_empty: str) -> str:
    try:
        dt = datetime.fromisoformat(iso_or_empty.replace("Z", "+00:00"))
    except Exception:
        dt = datetime.now(timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%d")


def anonymize(raw: str, salt: str) -> str:
    value = (raw or "").strip()
    if not value:
        return ""
    material = f"{salt}:{value}" if salt else value
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def init_db(db_path: Path) -> None:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(db_path)
    try:
        con.execute(
            """
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                received_at TEXT NOT NULL,
                event_time TEXT NOT NULL,
                event_day TEXT NOT NULL,
                event_type TEXT NOT NULL,
                app TEXT,
                app_surface TEXT,
                install_hash TEXT,
                session_hash TEXT,
                active_device TEXT,
                policy TEXT,
                model TEXT,
                input_tokens_estimated INTEGER,
                output_tokens_estimated INTEGER,
                error_kind TEXT
            )
            """
        )
        con.execute("CREATE INDEX IF NOT EXISTS idx_events_day ON events(event_day)")
        con.execute("CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type)")
        con.execute("CREATE INDEX IF NOT EXISTS idx_events_install ON events(install_hash)")
        con.commit()
    finally:
        con.close()


class TelemetryHandler(BaseHTTPRequestHandler):
    db_path: Path = Path("telemetry/usage.sqlite")
    salt: str = ""

    def _json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(body)

    def _html(self, status: int, body: str) -> None:
        raw = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path in ("/", "/telemetry/dashboard"):
            self._html(200, dashboard_html())
            return
        if parsed.path == "/telemetry/health":
            self._json(200, {"ok": True, "service": "acoulm-telemetry", "time_utc": utc_now_iso()})
            return
        if parsed.path == "/telemetry/summary":
            query = parse_qs(parsed.query)
            all_flag = (query.get("all") or ["0"])[0].lower() in ("1", "true", "yes")
            days_raw = (query.get("days") or ["30"])[0]
            try:
                days_int = int(days_raw)
            except Exception:
                days_int = 30
            # days=0 or all=1 → entire DB (all-time)
            if all_flag or days_int <= 0:
                self._json(200, summarize(self.db_path, since_day=None, window_days=None))
            else:
                days = max(1, min(3650, days_int))
                since_day = (datetime.now(timezone.utc) - timedelta(days=days - 1)).strftime("%Y-%m-%d")
                self._json(200, summarize(self.db_path, since_day=since_day, window_days=days))
            return
        self._json(404, {"ok": False, "error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/telemetry":
            self._json(404, {"ok": False, "error": "not_found"})
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            self._json(400, {"ok": False, "error": "empty_body"})
            return
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except Exception:
            self._json(400, {"ok": False, "error": "invalid_json"})
            return

        event_type = str(payload.get("event_type") or "").strip()
        event_time = str(payload.get("event_time") or utc_now_iso())
        if not event_type:
            self._json(400, {"ok": False, "error": "missing_event_type"})
            return

        install_hash = anonymize(str(payload.get("install_id") or ""), self.salt)
        session_hash = anonymize(str(payload.get("session_id") or ""), self.salt)

        row = {
            "received_at": utc_now_iso(),
            "event_time": event_time,
            "event_day": to_iso_day(event_time),
            "event_type": event_type[:80],
            "app": str(payload.get("app") or "")[:80],
            "app_surface": str(payload.get("app_surface") or "")[:80],
            "install_hash": install_hash,
            "session_hash": session_hash,
            "active_device": str(payload.get("active_device") or "")[:40],
            "policy": str(payload.get("policy") or "")[:40],
            "model": str(payload.get("model") or "")[:120],
            "input_tokens_estimated": int(payload.get("input_tokens_estimated") or 0),
            "output_tokens_estimated": int(payload.get("output_tokens_estimated") or 0),
            "error_kind": str(payload.get("error_kind") or "")[:200],
        }

        con = sqlite3.connect(self.db_path)
        try:
            con.execute(
                """
                INSERT INTO events(
                  received_at,event_time,event_day,event_type,app,app_surface,install_hash,session_hash,
                  active_device,policy,model,input_tokens_estimated,output_tokens_estimated,error_kind
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    row["received_at"],
                    row["event_time"],
                    row["event_day"],
                    row["event_type"],
                    row["app"],
                    row["app_surface"],
                    row["install_hash"],
                    row["session_hash"],
                    row["active_device"],
                    row["policy"],
                    row["model"],
                    row["input_tokens_estimated"],
                    row["output_tokens_estimated"],
                    row["error_kind"],
                ),
            )
            con.commit()
        finally:
            con.close()

        self._json(200, {"ok": True})

    def log_message(self, fmt: str, *args) -> None:
        # Keep terminal output concise.
        return


def summarize(db_path: Path, since_day: str | None, window_days: int | None) -> dict:
    con = sqlite3.connect(db_path)
    try:
        if since_day is None:
            day_clause = "1=1"
            day_params: tuple = ()
            first_day_row = con.execute("SELECT MIN(event_day) FROM events").fetchone()
            first_day_utc = first_day_row[0] if first_day_row and first_day_row[0] else None
            last_day_row = con.execute("SELECT MAX(event_day) FROM events").fetchone()
            last_day_utc = last_day_row[0] if last_day_row and last_day_row[0] else None
        else:
            day_clause = "event_day >= ?"
            day_params = (since_day,)
            first_day_utc = since_day
            last_day_utc = None

        total_events = con.execute(
            f"SELECT COUNT(*) FROM events WHERE {day_clause}", day_params
        ).fetchone()[0]
        unique_installs = con.execute(
            f"SELECT COUNT(DISTINCT install_hash) FROM events WHERE {day_clause} AND install_hash <> ''",
            day_params,
        ).fetchone()[0]
        unique_sessions = con.execute(
            f"SELECT COUNT(DISTINCT session_hash) FROM events WHERE {day_clause} AND session_hash <> ''",
            day_params,
        ).fetchone()[0]
        event_types = con.execute(
            f"""
            SELECT event_type, COUNT(*) AS n
            FROM events
            WHERE {day_clause}
            GROUP BY event_type
            ORDER BY n DESC
            """,
            day_params,
        ).fetchall()
        dau_rows = con.execute(
            f"""
            SELECT event_day, COUNT(DISTINCT install_hash) AS dau
            FROM events
            WHERE {day_clause} AND install_hash <> ''
            GROUP BY event_day
            ORDER BY event_day ASC
            """,
            day_params,
        ).fetchall()
    finally:
        con.close()

    return {
        "ok": True,
        "window_mode": "all_time" if since_day is None else "rolling",
        "window_days": window_days,
        "since_day_utc": since_day,
        "first_day_utc": first_day_utc,
        "last_day_utc": last_day_utc if since_day is None else None,
        "totals": {
            "events": total_events,
            "unique_installs": unique_installs,
            "unique_sessions": unique_sessions,
        },
        "events_by_type": [{"event_type": et, "count": n} for et, n in event_types],
        "daily_active_installs": [{"day": day, "dau": dau} for day, dau in dau_rows],
    }


def dashboard_html() -> str:
    return """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>AcouLM Telemetry Dashboard</title>
  <style>
    :root { color-scheme: dark; }
    body { margin: 0; font-family: Inter, Segoe UI, Arial, sans-serif; background: #0b1020; color: #e8ecff; }
    .wrap { max-width: 1100px; margin: 0 auto; padding: 20px; }
    .header { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 12px; align-items: center; }
    .title { font-size: 24px; font-weight: 700; margin: 0; }
    .muted { color: #9fb0e0; font-size: 13px; }
    .controls { display: flex; gap: 8px; align-items: center; }
    select, button { background: #151d36; border: 1px solid #2b3865; color: #e8ecff; padding: 8px 10px; border-radius: 10px; }
    .cards { display: grid; grid-template-columns: repeat(4, minmax(160px, 1fr)); gap: 12px; margin-top: 16px; }
    .card { background: #121933; border: 1px solid #243057; border-radius: 14px; padding: 12px; }
    .k { color: #95a9df; font-size: 12px; text-transform: uppercase; letter-spacing: .06em; }
    .v { font-size: 28px; font-weight: 700; margin-top: 6px; }
    .grid { display: grid; grid-template-columns: 2fr 1fr; gap: 12px; margin-top: 12px; }
    .panel { background: #121933; border: 1px solid #243057; border-radius: 14px; padding: 12px; }
    canvas { width: 100%; height: 280px; background: #0d1430; border-radius: 10px; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th, td { border-bottom: 1px solid #243057; padding: 8px 6px; text-align: left; }
    th { color: #9fb0e0; font-weight: 600; }
    .status { margin-top: 10px; color: #a8b7e6; font-size: 12px; }
    @media (max-width: 900px) {
      .cards { grid-template-columns: repeat(2, minmax(160px, 1fr)); }
      .grid { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="header">
      <div>
        <h1 class="title">AcouLM Telemetry Dashboard</h1>
        <div class="muted">Anonymous usage analytics (DAU/MAU, sessions, events)</div>
      </div>
      <div class="controls">
        <label class="muted" for="days">Window</label>
        <select id="days">
          <option value="7">7d</option>
          <option value="30" selected>30d</option>
          <option value="90">90d</option>
          <option value="365">365d</option>
          <option value="0">All time</option>
        </select>
        <button id="refresh">Refresh</button>
      </div>
    </div>

    <div class="cards">
      <div class="card"><div class="k">Unique Installs (MAU-like)</div><div class="v" id="mau">-</div></div>
      <div class="card"><div class="k">Unique Sessions</div><div class="v" id="sessions">-</div></div>
      <div class="card"><div class="k">Total Events</div><div class="v" id="events">-</div></div>
      <div class="card"><div class="k">Latest DAU</div><div class="v" id="latestDau">-</div></div>
    </div>

    <div class="grid">
      <div class="panel">
        <div class="k">Daily Active Installs</div>
        <canvas id="dauChart" width="800" height="280"></canvas>
      </div>
      <div class="panel">
        <div class="k">Event Type Mix</div>
        <canvas id="eventChart" width="360" height="280"></canvas>
      </div>
    </div>

    <div class="panel" style="margin-top:12px">
      <div class="k">Events by Type</div>
      <table>
        <thead><tr><th>Event</th><th>Count</th></tr></thead>
        <tbody id="eventRows"></tbody>
      </table>
      <div class="status" id="status">Loading...</div>
    </div>
  </div>

  <script>
    const $ = (id) => document.getElementById(id);
    function fmt(n){ return Number(n || 0).toLocaleString(); }

    function drawLine(canvas, labels, values) {
      const ctx = canvas.getContext("2d");
      const w = canvas.width, h = canvas.height;
      ctx.clearRect(0,0,w,h);
      ctx.fillStyle = "#0d1430"; ctx.fillRect(0,0,w,h);
      const pad = {l:44, r:12, t:12, b:26};
      const innerW = w - pad.l - pad.r;
      const innerH = h - pad.t - pad.b;
      const maxV = Math.max(1, ...values);
      ctx.strokeStyle = "#2a3a6a";
      ctx.lineWidth = 1;
      for (let i=0;i<=4;i++){
        const y = pad.t + (innerH * i/4);
        ctx.beginPath(); ctx.moveTo(pad.l, y); ctx.lineTo(w-pad.r, y); ctx.stroke();
      }
      if (!values.length) return;
      ctx.strokeStyle = "#60a5fa";
      ctx.lineWidth = 2;
      ctx.beginPath();
      values.forEach((v, i) => {
        const x = pad.l + (innerW * (values.length===1 ? 0 : i/(values.length-1)));
        const y = pad.t + innerH - (v/maxV)*innerH;
        if (i===0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
      });
      ctx.stroke();
      ctx.fillStyle = "#93c5fd";
      values.forEach((v, i) => {
        const x = pad.l + (innerW * (values.length===1 ? 0 : i/(values.length-1)));
        const y = pad.t + innerH - (v/maxV)*innerH;
        ctx.beginPath(); ctx.arc(x,y,2.5,0,Math.PI*2); ctx.fill();
      });
      ctx.fillStyle = "#9fb0e0";
      ctx.font = "11px sans-serif";
      const step = Math.max(1, Math.floor(labels.length/6));
      labels.forEach((d, i) => {
        if (i % step !== 0 && i !== labels.length - 1) return;
        const x = pad.l + (innerW * (labels.length===1 ? 0 : i/(labels.length-1)));
        ctx.fillText(d.slice(5), x-14, h-8);
      });
    }

    function drawBars(canvas, rows) {
      const ctx = canvas.getContext("2d");
      const w = canvas.width, h = canvas.height;
      ctx.clearRect(0,0,w,h);
      ctx.fillStyle = "#0d1430"; ctx.fillRect(0,0,w,h);
      const pad = {l:8, r:8, t:12, b:22};
      const innerW = w - pad.l - pad.r;
      const innerH = h - pad.t - pad.b;
      const top = rows.slice(0,6);
      const maxV = Math.max(1, ...top.map(r => r.count || 0));
      const barW = innerW / Math.max(1, top.length) * 0.75;
      top.forEach((r, i) => {
        const x = pad.l + i * (innerW / Math.max(1, top.length)) + 8;
        const bh = ((r.count || 0) / maxV) * (innerH - 16);
        const y = pad.t + innerH - bh;
        ctx.fillStyle = "#7c3aed";
        ctx.fillRect(x, y, barW, bh);
        ctx.fillStyle = "#c4b5fd";
        ctx.font = "11px sans-serif";
        ctx.fillText(String(r.event_type || "-").slice(0,8), x, h-8);
      });
    }

    async function loadSummary() {
      const days = Number($("days").value);
      const started = Date.now();
      const url = days === 0 ? "/telemetry/summary?all=1" : `/telemetry/summary?days=${days || 30}`;
      const res = await fetch(url);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();

      $("mau").textContent = fmt(data?.totals?.unique_installs);
      $("sessions").textContent = fmt(data?.totals?.unique_sessions);
      $("events").textContent = fmt(data?.totals?.events);
      const daily = data?.daily_active_installs || [];
      $("latestDau").textContent = fmt(daily.length ? daily[daily.length-1].dau : 0);

      drawLine(
        $("dauChart"),
        daily.map(d => d.day),
        daily.map(d => Number(d.dau || 0))
      );
      const eventRows = data?.events_by_type || [];
      drawBars($("eventChart"), eventRows);

      const rowsHtml = eventRows.map(r => `<tr><td>${r.event_type}</td><td>${fmt(r.count)}</td></tr>`).join("");
      $("eventRows").innerHTML = rowsHtml || "<tr><td colspan='2'>No events yet</td></tr>";
      const mode = data?.window_mode === "all_time" ? "all-time" : `${data?.window_days || "?"}d`;
      $("status").textContent = `Window: ${mode} · updated ${new Date().toLocaleTimeString()} · ${Date.now()-started}ms`;
    }

    async function refresh() {
      $("status").textContent = "Loading...";
      try { await loadSummary(); }
      catch (e) { $("status").textContent = `Failed: ${e.message || e}`; }
    }

    $("refresh").addEventListener("click", refresh);
    $("days").addEventListener("change", refresh);
    refresh();
    setInterval(refresh, 60000);
  </script>
</body>
</html>
"""


def main() -> None:
    parser = argparse.ArgumentParser(description="AcouLM telemetry receiver")
    parser.add_argument("--host", default="127.0.0.1", help="Listen host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8800, help="Listen port (default: 8800)")
    parser.add_argument(
        "--db",
        default="telemetry/usage.sqlite",
        help="SQLite path (default: telemetry/usage.sqlite)",
    )
    parser.add_argument(
        "--salt",
        default=os.environ.get("ACOULM_TELEMETRY_SALT", ""),
        help="Optional anonymization salt (or env ACOULM_TELEMETRY_SALT)",
    )
    args = parser.parse_args()

    db_path = Path(args.db)
    init_db(db_path)
    TelemetryHandler.db_path = db_path
    TelemetryHandler.salt = args.salt

    server = ThreadingHTTPServer((args.host, args.port), TelemetryHandler)
    print(f"[telemetry] listening on http://{args.host}:{args.port}")
    print("[telemetry] endpoints:")
    print("  POST /telemetry")
    print("  GET  /telemetry/health")
    print("  GET  /telemetry/summary?days=30")
    print("  GET  /telemetry/summary?all=1")
    server.serve_forever()


if __name__ == "__main__":
    main()
