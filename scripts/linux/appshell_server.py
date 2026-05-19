#!/usr/bin/env python3
"""
Serve app_shell and proxy /v1/* to the AcouLM API on one port (5173).
Use when the browser cannot reach 127.0.0.1:8000 directly (SSH tunnel one port).
"""
from __future__ import annotations

import argparse
import os
import sys
import urllib.error
import urllib.request
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


UPSTREAM = os.environ.get("ACOULM_API_UPSTREAM", "http://127.0.0.1:8000").rstrip("/")
APP_ROOT = Path(os.environ.get("ACOULM_HOME", Path(__file__).resolve().parents[2])) / "app_shell"


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        if self.path.startswith("/v1/"):
            print(f"[appshell] proxy {self.command} {self.path} -> {UPSTREAM}{self.path}")
        else:
            super().log_message(fmt, *args)

    def _cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header(
            "Access-Control-Allow-Headers",
            "Content-Type, Authorization, x-npu-cli",
        )

    def do_OPTIONS(self) -> None:
        if self.path.startswith("/v1/"):
            self.send_response(204)
            self._cors()
            self.end_headers()
            return
        super().do_OPTIONS()

    def _proxy(self) -> None:
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else None
        url = f"{UPSTREAM}{self.path}"
        if self.path.startswith("/v1/") and "?" in self.path:
            url = f"{UPSTREAM}{self.path}"
        req = urllib.request.Request(url, data=body, method=self.command)
        for key, val in self.headers.items():
            lk = key.lower()
            if lk in ("host", "content-length", "connection"):
                continue
            req.add_header(key, val)
        if body and not req.has_header("Content-Type"):
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=3600) as resp:
                data = resp.read()
                self.send_response(resp.status)
                ctype = resp.headers.get("Content-Type", "application/json")
                self.send_header("Content-Type", ctype)
                self._cors()
                self.end_headers()
                self.wfile.write(data)
        except urllib.error.HTTPError as e:
            data = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", e.headers.get("Content-Type", "application/json"))
            self._cors()
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            msg = f'{{"error":{{"message":"{e}","code":"proxy_error"}}}}'.encode()
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self._cors()
            self.end_headers()
            self.wfile.write(msg)

    def do_GET(self) -> None:
        if self.path.startswith("/v1/"):
            self._proxy()
            return
        super().do_GET()

    def do_POST(self) -> None:
        if self.path.startswith("/v1/"):
            self._proxy()
            return
        self.send_error(405)

    def end_headers(self) -> None:
        if not self.path.startswith("/v1/"):
            self.send_header("Cache-Control", "no-cache")
        super().end_headers()


def main() -> None:
    global UPSTREAM
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=int(os.environ.get("ACOULM_APP_PORT", "5173")))
    p.add_argument("--upstream", default=UPSTREAM)
    args = p.parse_args()
    UPSTREAM = args.upstream.rstrip("/")
    if not APP_ROOT.is_dir():
        sys.exit(f"[appshell] Missing app_shell at {APP_ROOT}")
    handler = partial(Handler, directory=str(APP_ROOT))
    server = ThreadingHTTPServer(("0.0.0.0", args.port), handler)
    print(f"[appshell] UI http://0.0.0.0:{args.port}/  (API proxy -> {UPSTREAM}/v1/...)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("[appshell] Stopped")


if __name__ == "__main__":
    main()
