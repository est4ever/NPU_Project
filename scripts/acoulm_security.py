"""Shared localhost bind + optional bearer token for AcouLM HTTP servers."""
from __future__ import annotations

import os
import sys
from http.server import BaseHTTPRequestHandler
from typing import Optional
from urllib.parse import urlparse


def bind_host() -> str:
    return (os.environ.get("ACOULM_BIND_HOST") or "127.0.0.1").strip() or "127.0.0.1"


def api_token() -> str:
    return (os.environ.get("ACOULM_API_TOKEN") or "").strip()


def is_exposed_bind() -> bool:
    return bind_host() not in ("127.0.0.1", "localhost", "::1")


def warn_if_insecure_startup() -> None:
    if is_exposed_bind() and not api_token():
        print(
            "[Security] ERROR: ACOULM_BIND_HOST is not localhost but ACOULM_API_TOKEN is unset.",
            file=sys.stderr,
        )
        print(
            "[Security] Set ACOULM_API_TOKEN or bind 127.0.0.1 and use SSH tunnel.",
            file=sys.stderr,
        )
        sys.exit(1)
    if is_exposed_bind():
        print(
            f"[Security] WARNING: listening on {bind_host()} with token auth — do not expose to the internet.",
            file=sys.stderr,
        )
    else:
        print(f"[Security] Listening on {bind_host()} (localhost).", file=sys.stderr)


def _loopback_peer(handler: BaseHTTPRequestHandler) -> bool:
    host = (handler.client_address[0] if handler.client_address else "") or ""
    return host in ("127.0.0.1", "::1", "localhost", "")


def _bearer_ok(handler: BaseHTTPRequestHandler) -> bool:
    expected = api_token()
    if not expected:
        return True
    auth = handler.headers.get("Authorization", "")
    prefix = "Bearer "
    if not auth.startswith(prefix):
        return False
    return auth[len(prefix) :].strip() == expected


def _cors_origin_allowed(origin: str) -> bool:
    if os.environ.get("ACOULM_INSECURE_CORS", "").strip().lower() in ("1", "true", "yes"):
        return True
    if not origin:
        return False
    try:
        u = urlparse(origin)
    except Exception:
        return False
    return u.hostname in ("127.0.0.1", "localhost")


def send_cors(handler: BaseHTTPRequestHandler) -> None:
    origin = handler.headers.get("Origin", "")
    if _cors_origin_allowed(origin):
        handler.send_header("Access-Control-Allow-Origin", origin)
        handler.send_header("Vary", "Origin")
    elif os.environ.get("ACOULM_INSECURE_CORS", "").strip().lower() in ("1", "true", "yes"):
        handler.send_header("Access-Control-Allow-Origin", "*")
    handler.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    handler.send_header(
        "Access-Control-Allow-Headers",
        "Content-Type, Authorization, x-npu-cli, x-acoulm-panel",
    )


def check_request(handler: BaseHTTPRequestHandler, path: str) -> Optional[tuple[int, dict]]:
    """Return (status, error_body) to reject, or None to allow."""
    if handler.command == "OPTIONS":
        return (204, {})

    if not _bearer_ok(handler):
        return (
            401,
            {
                "error": {
                    "code": "unauthorized",
                    "message": "Missing or invalid Authorization Bearer token.",
                }
            },
        )

    if path in ("/health", "/v1/health"):
        return None

    if path == "/v1/chat/completions":
        if _loopback_peer(handler):
            return None
        if handler.headers.get("x-npu-cli", "").lower() == "true":
            return None
        if handler.headers.get("x-acoulm-panel", "").lower() == "true":
            return None
        if api_token():
            return None
        return (
            403,
            {
                "error": {
                    "code": "forbidden",
                    "message": "Chat allowed from localhost or with ACOULM_API_TOKEN.",
                }
            },
        )

    if path.startswith("/v1/cli/"):
        if _loopback_peer(handler) or api_token():
            return None
        return (
            403,
            {
                "error": {
                    "code": "forbidden",
                    "message": "Control API is localhost-only unless ACOULM_API_TOKEN is set.",
                }
            },
        )

    return None
