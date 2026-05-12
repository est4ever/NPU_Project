#!/usr/bin/env python3
"""
AcouLM privacy-first telemetry receiver.

- POST /telemetry        ingest one event
- GET  /telemetry/health quick health check
- GET  /telemetry/summary?days=30  aggregate DAU/MAU-like counters

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

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/telemetry/health":
            self._json(200, {"ok": True, "service": "acoulm-telemetry", "time_utc": utc_now_iso()})
            return
        if parsed.path == "/telemetry/summary":
            query = parse_qs(parsed.query)
            days_raw = (query.get("days") or ["30"])[0]
            try:
                days = max(1, min(3650, int(days_raw)))
            except Exception:
                days = 30
            since_day = (datetime.now(timezone.utc) - timedelta(days=days - 1)).strftime("%Y-%m-%d")
            self._json(200, summarize(self.db_path, since_day, days))
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


def summarize(db_path: Path, since_day: str, days: int) -> dict:
    con = sqlite3.connect(db_path)
    try:
        total_events = con.execute(
            "SELECT COUNT(*) FROM events WHERE event_day >= ?", (since_day,)
        ).fetchone()[0]
        unique_installs = con.execute(
            "SELECT COUNT(DISTINCT install_hash) FROM events WHERE event_day >= ? AND install_hash <> ''",
            (since_day,),
        ).fetchone()[0]
        unique_sessions = con.execute(
            "SELECT COUNT(DISTINCT session_hash) FROM events WHERE event_day >= ? AND session_hash <> ''",
            (since_day,),
        ).fetchone()[0]
        event_types = con.execute(
            """
            SELECT event_type, COUNT(*) AS n
            FROM events
            WHERE event_day >= ?
            GROUP BY event_type
            ORDER BY n DESC
            """,
            (since_day,),
        ).fetchall()
        dau_rows = con.execute(
            """
            SELECT event_day, COUNT(DISTINCT install_hash) AS dau
            FROM events
            WHERE event_day >= ? AND install_hash <> ''
            GROUP BY event_day
            ORDER BY event_day ASC
            """,
            (since_day,),
        ).fetchall()
    finally:
        con.close()

    return {
        "ok": True,
        "window_days": days,
        "since_day_utc": since_day,
        "totals": {
            "events": total_events,
            "unique_installs": unique_installs,
            "unique_sessions": unique_sessions,
        },
        "events_by_type": [{"event_type": et, "count": n} for et, n in event_types],
        "daily_active_installs": [{"day": day, "dau": dau} for day, dau in dau_rows],
    }


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
    server.serve_forever()


if __name__ == "__main__":
    main()
