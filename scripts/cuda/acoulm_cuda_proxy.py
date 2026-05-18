#!/usr/bin/env python3
"""
AcouLM external CUDA backend: spawns llama.cpp llama-server (NVIDIA) and exposes the
AcouLM-compatible HTTP API on --port (default 8000).

Requires a GGUF model (.gguf file or directory containing one).
OpenVINO IR folders are not supported on this backend — use registry backend openvino.

Env:
  LLAMA_SERVER   path to llama-server (default: search PATH and ~/llama.cpp/build/bin)
  ACOULM_CUDA_DEVICES  CUDA_VISIBLE_DEVICES (e.g. 0 or 0,1)
  LLAMA_NGL        GPU layers to offload (default: 999 = all)
  LLAMA_CTX        context size (default: 8192)
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


def find_gguf(model_arg: str) -> Path:
    p = Path(model_arg).expanduser().resolve()
    if p.is_file() and p.suffix == ".gguf":
        return p
    if p.is_dir():
        ggufs = sorted(p.glob("*.gguf"))
        if len(ggufs) == 1:
            return ggufs[0]
        if len(ggufs) > 1:
            # prefer largest (often main weights)
            return max(ggufs, key=lambda f: f.stat().st_size)
        if (p / "openvino_model.xml").exists() or list(p.glob("openvino*.xml")):
            sys.exit(
                f"[cuda] {p} is OpenVINO IR. CUDA backend needs GGUF.\n"
                "  Convert HF→GGUF (llama.cpp quantize) or set selected_backend=openvino.\n"
                "  Example: huggingface-cli download ... *.gguf"
            )
    sys.exit(f"[cuda] No .gguf found at {p}")


def find_llama_server() -> str:
    if os.environ.get("LLAMA_SERVER"):
        return os.environ["LLAMA_SERVER"]
    home = Path.home() / "llama.cpp" / "build" / "bin" / "llama-server"
    if home.is_file():
        return str(home)
    import shutil

    hit = shutil.which("llama-server")
    if hit:
        return hit
    sys.exit(
        "[cuda] llama-server not found. Run: bash scripts/hpc/install_llama_cuda.sh\n"
        "  Or set LLAMA_SERVER=/path/to/llama-server"
    )


class ProxyState:
    def __init__(self, llama_base: str, model_path: Path, devices: str) -> None:
        self.llama_base = llama_base.rstrip("/")
        self.model_path = model_path
        self.devices = devices
        self.proc: subprocess.Popen | None = None
        self.ready = False

    def start_llama(self, port: int) -> None:
        exe = find_llama_server()
        ngl = os.environ.get("LLAMA_NGL", "999")
        ctx = os.environ.get("LLAMA_CTX", "8192")
        env = os.environ.copy()
        if self.devices:
            env["CUDA_VISIBLE_DEVICES"] = self.devices
        cmd = [
            exe,
            "-m",
            str(self.model_path),
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "-ngl",
            ngl,
            "-c",
            ctx,
        ]
        print(f"[cuda] Starting llama-server (CUDA_VISIBLE_DEVICES={self.devices or 'all'})")
        print(f"[cuda]   {' '.join(cmd)}")
        self.proc = subprocess.Popen(
            cmd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )

        def pump() -> None:
            assert self.proc and self.proc.stdout
            for line in self.proc.stdout:
                print(f"[llama] {line.rstrip()}")

        threading.Thread(target=pump, daemon=True).start()
        self._wait_ready()

    def _wait_ready(self, timeout: float = 600.0) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc and self.proc.poll() is not None:
                sys.exit(f"[cuda] llama-server exited with code {self.proc.returncode}")
            try:
                urllib.request.urlopen(f"{self.llama_base}/health", timeout=2)
                self.ready = True
                print("[cuda] llama-server is ready")
                return
            except Exception:
                time.sleep(1.0)
        print("[cuda] WARN: llama health check timed out; API may still work")

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()


STATE: ProxyState | None = None
ACOULM_PORT = 8000


def llama_request(method: str, path: str, body: bytes | None, headers: dict) -> tuple[int, bytes, str]:
    assert STATE is not None
    url = f"{STATE.llama_base}{path}"
    req = urllib.request.Request(url, data=body, method=method)
    for k, v in headers.items():
        if k.lower() in ("host", "content-length"):
            continue
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=3600) as resp:
            return resp.status, resp.read(), resp.headers.get_content_type()
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers.get_content_type() if e.headers else "application/json"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        print(f"[api] {self.address_string()} {fmt % args}")

    def _send(self, code: int, body: bytes, ctype: str = "application/json") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, x-npu-cli")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, obj: object) -> None:
        self._send(code, json.dumps(obj).encode(), "application/json")

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, x-npu-cli")
        self.end_headers()

    def do_GET(self) -> None:
        if self.path in ("/health", "/v1/health"):
            ready = STATE.ready if STATE else False
            self._json(
                200,
                {
                    "status": "healthy" if ready else "loading",
                    "chat_ready": ready,
                    "backend": "cuda-llama",
                    "model": str(STATE.model_path) if STATE else None,
                },
            )
            return
        if self.path == "/v1/cli/status":
            self._json(
                200,
                {
                    "active_device": "CUDA",
                    "devices": ["CUDA"],
                    "selected_backend": "cuda-llama",
                    "selected_model": str(STATE.model_path.name) if STATE else "",
                    "policy": "PERFORMANCE",
                    "performance_profile": "cuda-llama",
                },
            )
            return
        if self.path == "/v1/models":
            self._json(200, {"object": "list", "data": [{"id": "cuda-llama", "object": "model"}]})
            return
        self._json(404, {"error": {"message": "not found", "code": "not_found"}})

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        if self.path == "/v1/chat/completions":
            fwd_headers = {"Content-Type": "application/json"}
            code, resp, ctype = llama_request("POST", "/v1/chat/completions", body, fwd_headers)
            self._send(code, resp, ctype)
            return
        self._json(404, {"error": {"message": "not found", "code": "not_found"}})


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("model", help="Path to .gguf or folder containing one")
    p.add_argument("--server", action="store_true")
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--device", default="GPU", help="Maps to CUDA (ACOULM_CUDA_DEVICES)")
    return p.parse_args(argv)


def main() -> None:
    global STATE, ACOULM_PORT
    args = parse_args(sys.argv[1:])
    if not args.server:
        print("[cuda] Use --server (invoked via acoulm start / run.sh)", file=sys.stderr)
        sys.exit(1)

    gguf = find_gguf(args.model)
    acoulm_port = args.port
    llama_port = int(os.environ.get("LLAMA_PORT", str(acoulm_port + 1)))
    ACOULM_PORT = acoulm_port

    devices = os.environ.get("ACOULM_CUDA_DEVICES", "")
    if not devices and args.device.upper() in ("GPU", "CUDA"):
        devices = os.environ.get("CUDA_VISIBLE_DEVICES", "0")

    STATE = ProxyState(f"http://127.0.0.1:{llama_port}", gguf, devices)
    STATE.start_llama(llama_port)

    def shutdown(_sig=None, _frame=None) -> None:
        print("[cuda] Shutting down...")
        if STATE:
            STATE.stop()
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    print(f"[cuda] AcouLM API http://0.0.0.0:{acoulm_port}  →  llama-server :{llama_port}")
    server = HTTPServer(("0.0.0.0", acoulm_port), Handler)
    try:
        server.serve_forever()
    finally:
        shutdown()


if __name__ == "__main__":
    main()
