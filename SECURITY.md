# Security

AcouLM runs a **local HTTP API** on your machine. Treat it like admin access to your GPU, models, and files.

## Defaults (safe for most users)

| Setting | Default | Meaning |
|---------|---------|---------|
| `ACOULM_BIND_HOST` | `127.0.0.1` | API and control panel only accept connections from **this machine** |
| `ACOULM_API_TOKEN` | *(unset)* | No bearer token required on localhost |
| CORS | localhost only | Browser panel only talks to the API from `http://127.0.0.1:*` or `http://localhost:*` |

With defaults, strangers on the internet **cannot** reach your API unless you port-forward or change the bind address.

## Control panel proxy (port 5173)

The Linux stack serves the UI on **5173** and proxies `/v1/*` to the API on **8000**. Auth is enforced **on the proxy** using the real client IP (not the loopback hop to the API). If you expose `0.0.0.0`, set `ACOULM_API_TOKEN` and use the token in the panel header.

## Remote access (cluster / SSH)

Use an SSH tunnel — do **not** bind `0.0.0.0` without a token:

```bash
ssh -L 8000:127.0.0.1:8000 -L 5173:127.0.0.1:5173 user@cluster
```

On the cluster, keep `ACOULM_BIND_HOST=127.0.0.1` in `scripts/hpc/local_env.sh`.

## Exposing the API on a LAN (advanced)

Only if you understand the risk:

```bash
export ACOULM_BIND_HOST=0.0.0.0
export ACOULM_API_TOKEN=$(openssl rand -hex 32)   # Linux/macOS
# save the token — required; startup aborts if bind is non-localhost without it
```

Clients must send:

```http
Authorization: Bearer <your-token>
```

- Terminal (Linux): `export ACOULM_API_TOKEN=...` before `acoulm`
- Control panel: paste token in **API Token** in the header (stored in browser `localStorage` only on your PC)

**Never** commit `ACOULM_API_TOKEN` or put it in `local_env.sh` in git.

## What the API allows

| Route | Localhost | Remote without token | Remote with `ACOULM_API_TOKEN` |
|-------|-----------|----------------------|--------------------------------|
| `/v1/health` | yes | no | yes (with Bearer) |
| `/v1/chat/completions` | yes | no | yes (with Bearer) |
| `/v1/cli/*` (control) | yes | no | yes (with Bearer) |

Chat from the browser sends `x-acoulm-panel: true` (loopback only). Terminal chat sends `x-npu-cli: true` when required.

## Secrets checklist

- [ ] `scripts/hpc/local_env.sh` — **gitignored**; keep paths and tokens local
- [ ] `registry/*.json` — **gitignored** (machine-specific paths)
- [ ] `models/` — **gitignored**
- [ ] Hugging Face token — use `huggingface-cli login`, not env in repo
- [ ] `gh` / GitHub — your machine only; never commit `gh` tokens
- [ ] Cursor — disable commit attribution; do not commit `Co-authored-by: Cursor`

## GitHub (public repo)

- Publishing the repo does **not** grant write access to your GitHub account
- Use branch protection on `main`
- Review PRs before merge
- Repository secret scanning is enabled via `.github/workflows/secret-scan.yml`

## Social media / sharing

Safe to share the **repo URL** and demos. Do **not** share:

- Screenshots of `local_env.sh`, API tokens, or `gh auth status`
- Open ports 8000/5173 to the public internet
- Cluster hostnames + open firewall rules

## Reporting issues

Open a GitHub issue with **Security** in the title (no live tokens in the report).
