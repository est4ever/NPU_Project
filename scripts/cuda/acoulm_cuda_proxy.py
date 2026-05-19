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
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


def acoulm_home() -> Path:
    return Path(os.environ.get("ACOULM_HOME", Path.cwd())).resolve()


def _gguf_candidates_in_dir(directory: Path) -> list[Path]:
    ggufs = sorted(directory.glob("*.gguf"))
    if ggufs:
        return ggufs
    return sorted(directory.rglob("*.gguf"))


def _pick_gguf(ggufs: list[Path]) -> Path:
    if len(ggufs) == 1:
        return ggufs[0]
    return max(ggufs, key=lambda f: f.stat().st_size)


def _registry_gguf_paths() -> list[Path]:
    reg = acoulm_home() / "registry" / "models_registry.json"
    if not reg.is_file():
        return []
    try:
        data = json.loads(reg.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    root = acoulm_home()
    out: list[Path] = []
    sel = str(data.get("selected_model") or "")
    models = list(data.get("models") or [])
    # Selected model first, then any gguf-format entry.
    ordered = [m for m in models if str(m.get("id", "")) == sel]
    ordered += [m for m in models if m not in ordered]
    for m in ordered:
        fmt = str(m.get("format") or "").lower()
        rel = str(m.get("path") or "").strip()
        if not rel:
            continue
        p = Path(rel).expanduser()
        if not p.is_absolute():
            p = (root / rel.lstrip("./")).resolve()
        if fmt == "gguf" or p.suffix == ".gguf" or p.name.endswith(".gguf"):
            out.append(p)
        elif p.is_dir():
            found = _gguf_candidates_in_dir(p)
            if found:
                out.append(_pick_gguf(found))
    return out


def find_gguf(model_arg: str) -> Path:
    p = Path(model_arg).expanduser().resolve()
    if p.is_file() and p.suffix == ".gguf":
        return p
    if p.is_dir():
        ggufs = _gguf_candidates_in_dir(p)
        if ggufs:
            return _pick_gguf(ggufs)
        sibling = p.parent / f"{p.name}-gguf"
        if sibling.is_dir():
            ggufs = _gguf_candidates_in_dir(sibling)
            if ggufs:
                print(f"[cuda] Using GGUF from sibling folder: {sibling}", file=sys.stderr)
                return _pick_gguf(ggufs)
        if (p / "openvino_model.xml").exists() or list(p.glob("openvino*.xml")):
            sibling = p.parent / f"{p.name}-gguf"
            hint = f"\n  Set ACOULM_MODEL={sibling}/*.gguf in scripts/hpc/local_env.sh" if sibling.is_dir() else ""
            sys.exit(
                f"[cuda] {p} is OpenVINO/HF weights, not GGUF.{hint}\n"
                "  CUDA backend needs a .gguf file (see models/*-gguf/)."
            )
    for reg_path in _registry_gguf_paths():
        if reg_path.is_file() and reg_path.suffix == ".gguf":
            print(f"[cuda] Using GGUF from registry: {reg_path}", file=sys.stderr)
            return reg_path
        if reg_path.is_dir():
            ggufs = _gguf_candidates_in_dir(reg_path)
            if ggufs:
                print(f"[cuda] Using GGUF from registry path: {reg_path}", file=sys.stderr)
                return _pick_gguf(ggufs)
    sys.exit(
        f"[cuda] No .gguf found at {p}\n"
        f"  Fix: export ACOULM_MODEL={acoulm_home()}/models/<name>-gguf/<file>.gguf\n"
        "  in scripts/hpc/local_env.sh (HF/IR folders do not work on cuda-llama)."
    )


def port_is_free(host: str, port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind((host, port))
            return True
        except OSError:
            return False


def pick_llama_port(acoulm_port: int) -> int:
    if os.environ.get("LLAMA_PORT"):
        return int(os.environ["LLAMA_PORT"])
    # Avoid acoulm_port+1 (8001) — often left occupied by a stale llama-server.
    for candidate in (acoulm_port + 10000, 28081, 18081, acoulm_port + 1):
        if port_is_free("127.0.0.1", candidate):
            return candidate
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


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
        # 27B on 24GB: 4 slots x 8192 ctx often hangs OOM/swap; use 1 slot + smaller ctx.
        ctx = os.environ.get("LLAMA_CTX", "4096")
        parallel = os.environ.get("LLAMA_PARALLEL", "1")
        reasoning = os.environ.get("LLAMA_REASONING", "off")
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
            "-np",
            parallel,
            "--reasoning",
            reasoning,
            "--cache-ram",
            os.environ.get("LLAMA_CACHE_RAM", "0"),
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
                if self.proc and self.proc.poll() is not None:
                    sys.exit(
                        f"[cuda] llama-server died during startup (exit {self.proc.returncode}). "
                        "Check [llama] lines above (port in use? run: pkill -f llama-server)."
                    )
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


def load_registry(name: str) -> dict:
    path = acoulm_home() / "registry" / name
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def status_payload() -> dict:
    models_reg = load_registry("models_registry.json")
    backends_reg = load_registry("backends_registry.json")
    sel_model = str(models_reg.get("selected_model") or "")
    if not sel_model and STATE:
        sel_model = STATE.model_path.stem
    sel_backend = str(backends_reg.get("selected_backend") or "cuda-llama")
    return {
        "policy": "PERFORMANCE",
        "performance_profile": "cuda-llama",
        "performance_reason": "external CUDA backend",
        "active_device": "CUDA",
        "devices": ["CUDA"],
        "available_devices": [{"id": "CUDA", "tier": "discrete"}],
        "json_output": "OFF",
        "split_prefill": "OFF",
        "context_routing": "OFF",
        "optimize_memory": "OFF",
        "ttft_ms": 0,
        "tpot_ms": 0,
        "throughput": 0,
        "selected_model": sel_model,
        "auto_select_best_model": bool(models_reg.get("auto_select_best_model", False)),
        "selected_backend": sel_backend,
    }


def memory_payload() -> dict:
    return {
        "optimize_memory": "OFF",
        "disk_paging_enabled": False,
        "paging_directory": "",
        "ram": {"total_mb": 0, "used_mb": 0, "available_mb": 0, "usage_percent": 0},
        "vram": {"total_mb": 0, "used_mb": 0, "available_mb": 0, "usage_percent": 0},
    }


def metrics_payload(mode: str = "last") -> dict:
    return {"mode": mode, "record_count": 0}


def readiness_payload() -> dict:
    models_reg = load_registry("models_registry.json")
    sel = str(models_reg.get("selected_model") or "")
    out: dict = {
        "api_port": ACOULM_PORT,
        "selected_model_id": sel,
        "model_path": str(STATE.model_path) if STATE else "",
    }
    if STATE:
        out["model_analysis"] = {
            "exists": STATE.model_path.is_file(),
            "kind": "gguf",
            "gguf_count": 1,
            "runnable_hint": "GGUF via llama-server",
        }
    return out


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
        path = self.path.split("?", 1)[0]
        if path in ("/health", "/v1/health"):
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
        if path == "/v1/cli/status":
            self._json(200, status_payload())
            return
        if path == "/v1/cli/model/list":
            reg = load_registry("models_registry.json")
            if not reg.get("models") and STATE:
                mid = STATE.model_path.stem
                reg = {
                    "schema": 1,
                    "selected_model": mid,
                    "models": [
                        {
                            "id": mid,
                            "path": str(STATE.model_path),
                            "format": "gguf",
                            "status": "ready",
                        }
                    ],
                }
            self._json(200, reg)
            return
        if path == "/v1/cli/backend/list":
            reg = load_registry("backends_registry.json")
            if not reg.get("backends"):
                reg = {
                    "schema": 1,
                    "selected_backend": "cuda-llama",
                    "backends": [
                        {
                            "id": "cuda-llama",
                            "type": "external",
                            "entrypoint": "scripts/cuda/acoulm_cuda_proxy.py",
                            "formats": ["gguf"],
                            "status": "ready",
                        }
                    ],
                }
            self._json(200, reg)
            return
        if path == "/v1/cli/memory":
            self._json(200, memory_payload())
            return
        if path.startswith("/v1/cli/metrics"):
            mode = "last"
            if "?" in self.path:
                for part in self.path.split("?", 1)[1].split("&"):
                    if part.startswith("mode="):
                        mode = part.split("=", 1)[1]
            self._json(200, metrics_payload(mode))
            return
        if path == "/v1/cli/readiness":
            self._json(200, readiness_payload())
            return
        if path == "/v1/cli/models/discover":
            self._json(200, {"discover": []})
            return
        if path == "/v1/cli/backend/probe":
            self._json(
                200,
                {
                    "backend": "cuda-llama",
                    "healthy": bool(STATE and STATE.ready),
                    "entrypoint": "scripts/cuda/acoulm_cuda_proxy.py",
                },
            )
            return
        if path == "/v1/cli/metrics/recommendation":
            self._json(200, {"recommendation": "PERFORMANCE", "device": "CUDA"})
            return
        if path == "/v1/models":
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
    # run.sh / start_server.sh pass OpenVINO-style flags; ignore them on the CUDA backend.
    args, unknown = p.parse_known_args(argv)
    if unknown:
        print(f"[cuda] Ignoring extra args: {' '.join(unknown)}")
    return args


def main() -> None:
    global STATE, ACOULM_PORT
    args = parse_args(sys.argv[1:])
    if not args.server:
        print("[cuda] Use --server (invoked via acoulm start / run.sh)", file=sys.stderr)
        sys.exit(1)

    gguf = find_gguf(args.model)
    acoulm_port = args.port
    llama_port = pick_llama_port(acoulm_port)
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
    print("[cuda] Run acoulm in a terminal for chat + control panel.")
    server = HTTPServer(("0.0.0.0", acoulm_port), Handler)
    try:
        server.serve_forever()
    finally:
        shutdown()


if __name__ == "__main__":
    main()
