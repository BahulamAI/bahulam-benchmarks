#!/usr/bin/env python3
"""Railway entrypoint: run dispatch-batch.sh once against this image's frozen
instance.json/models.json, and serve a live-tracking dashboard over the
results directory for the rest of the container's life.

Inference only, same split as the local pipeline (see run-model-on-instance.sh):
this never does Docker eval. Patches land as resolved: "pending_eval" and get
evaluated separately on VM1, same as screening does.
"""
import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

RAILWAY_DIR = Path(__file__).resolve().parent
DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
RUN_DIR = DATA_DIR / "run"
RESULTS_DIR = RUN_DIR / "results"
REPO_BARE = DATA_DIR / "repo.git"
INSTANCE_JSON = RAILWAY_DIR / "instance.json"
MODELS_JSON = RAILWAY_DIR / "models.json"
STATE_FILE = DATA_DIR / "dispatch-state.json"
SOURCE_REPO = os.environ.get("SOURCE_REPO_URL", "https://github.com/pydata/xarray.git")

CONCURRENCY = os.environ.get("CONCURRENCY", "4")
TIMEOUT_S = os.environ.get("HARNESS_TIMEOUT_S", "1700")
MAX_TURNS = os.environ.get("BAHULAM_MAX_TURNS", "999")

_state_lock = threading.Lock()
_state = {"phase": "starting", "started_at": time.time(), "dispatch_exit": None}
_dispatch_lock = threading.Lock()
ADMIN_TOKEN = os.environ.get("ADMIN_TOKEN", "")


def _save_state():
    with _state_lock:
        payload = dict(_state)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload))
    tmp.replace(STATE_FILE)


def _set_phase(phase, **extra):
    with _state_lock:
        _state["phase"] = phase
        _state.update(extra)
    _save_state()


def dispatcher_thread():
    if not _dispatch_lock.acquire(blocking=False):
        return  # a dispatch pass (initial or retry) is already running
    try:
        RUN_DIR.mkdir(parents=True, exist_ok=True)
        if not REPO_BARE.exists():
            _set_phase("cloning_repo")
            subprocess.run(["git", "clone", "--quiet", "--bare", SOURCE_REPO, str(REPO_BARE)], check=True)

        _set_phase("dispatching")
        proc = subprocess.run(
            [
                "bash", str(RAILWAY_DIR / "dispatch-batch.sh"),
                "--instance", str(INSTANCE_JSON),
                "--models", str(MODELS_JSON),
                "--repo-bare", str(REPO_BARE),
                "--run-dir", str(RUN_DIR),
                "--concurrency", CONCURRENCY,
                "--timeout-s", TIMEOUT_S,
                "--max-turns", MAX_TURNS,
            ],
            env={**os.environ, "BAHULAM_CODE_DIR": os.environ.get("BAHULAM_CODE_DIR", "/opt/bahulam-cli")},
        )
        _set_phase("done", dispatch_exit=proc.returncode, finished_at=time.time())
    finally:
        _dispatch_lock.release()


def _model_tag(slug):
    return slug.replace("/", "-").replace(":", "-")


def collect_rows():
    models = json.loads(MODELS_JSON.read_text())["models"]
    rows = []
    for m in models:
        slug = m["slug"]
        tag = _model_tag(slug)
        result_path = RESULTS_DIR / tag / "result.json"
        log_path = RESULTS_DIR / f"{tag}.log"
        if result_path.exists():
            try:
                r = json.loads(result_path.read_text())
            except Exception:
                r = {}
            ce = r.get("complete_event") or {}
            usage = ce.get("usage") or {}
            rows.append({
                "rank": m.get("rank"),
                "model": slug,
                "tag": tag,
                "state": r.get("resolved", "unknown"),
                "turns": ce.get("turns"),
                "tools": ce.get("tools"),
                "input_tokens": usage.get("input_tokens"),
                "output_tokens": usage.get("output_tokens"),
                "cost_usd": ce.get("cost_usd"),
                "wall_clock_s": r.get("wall_clock_s"),
                "error": (r.get("error_event") or {}).get("error"),
            })
        elif log_path.exists():
            rows.append(_empty_row(m, tag, "running"))
        else:
            rows.append(_empty_row(m, tag, "queued"))
    return rows


def _empty_row(m, tag, state):
    return {
        "rank": m.get("rank"), "model": m["slug"], "tag": tag, "state": state,
        "turns": None, "tools": None, "input_tokens": None, "output_tokens": None,
        "cost_usd": None, "wall_clock_s": None, "error": None,
    }


def render_html(rows, state):
    done = sum(1 for r in rows if r["state"] not in ("queued", "running"))
    running = sum(1 for r in rows if r["state"] == "running")
    resolved = sum(1 for r in rows if r["state"] == "resolved")
    body_rows = "\n".join(
        f"<tr><td>{r['rank']}</td><td><a href='/result/{r['tag']}'>{r['model']}</a></td><td class='s-{r['state']}'>{r['state']}</td>"
        f"<td>{r['turns'] if r['turns'] is not None else '-'}</td>"
        f"<td>{r['tools'] if r['tools'] is not None else '-'}</td>"
        f"<td>{r['input_tokens'] if r['input_tokens'] is not None else '-'}</td>"
        f"<td>{r['output_tokens'] if r['output_tokens'] is not None else '-'}</td>"
        f"<td>{'$%.4f' % r['cost_usd'] if r['cost_usd'] is not None else '-'}</td>"
        f"<td>{r['wall_clock_s'] if r['wall_clock_s'] is not None else '-'}</td>"
        f"<td title='{(r['error'] or '').replace(chr(39), chr(96))}'>{(r['error'] or '-')[:40]}</td></tr>"
        for r in rows
    )
    return f"""<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="15">
<title>Model comparison — live</title>
<style>
body{{font:14px -apple-system,sans-serif;margin:24px;background:#0b0e14;color:#dfe3ea}}
table{{border-collapse:collapse;width:100%}}
td,th{{border-bottom:1px solid #222a36;padding:6px 10px;text-align:left}}
th{{color:#8b94a7;font-weight:600}}
.s-resolved{{color:#3ecf8e;font-weight:600}}
.s-unresolved{{color:#e07a5f}}
.s-pending_eval{{color:#e8c547}}
.s-running{{color:#5aa9e6}}
.s-queued{{color:#5a6473}}
.s-no_patch,.s-not_evaluated,.s-eval_error{{color:#8b94a7}}
.summary{{margin-bottom:16px;color:#8b94a7}}
</style></head><body>
<h2>Model comparison — pydata/xarray-6992</h2>
<div class="summary">phase: {state.get('phase')} · done: {done}/{len(rows)} · running: {running} · resolved: {resolved}</div>
<table><tr><th>#</th><th>model</th><th>state</th><th>turns</th><th>tools</th><th>in tok</th><th>out tok</th><th>cost</th><th>wall(s)</th><th>error</th></tr>
{body_rows}
</table>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        rows = collect_rows()
        with _state_lock:
            state = dict(_state)
        if self.path == "/status.json":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"state": state, "rows": rows}).encode())
            return
        if self.path.startswith("/result/"):
            tag = self.path[len("/result/"):]
            result_path = RESULTS_DIR / tag / "result.json"
            self.send_response(200 if result_path.exists() else 404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(result_path.read_bytes() if result_path.exists() else b"{}")
            return
        if self.path.startswith("/log/"):
            tag = self.path[len("/log/"):]
            log_path = RESULTS_DIR / f"{tag}.log"
            self.send_response(200 if log_path.exists() else 404)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(log_path.read_bytes() if log_path.exists() else b"")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(render_html(rows, state).encode())

    def do_POST(self):
        if self.path != "/admin/retry":
            self.send_response(404)
            self.end_headers()
            return
        if not ADMIN_TOKEN or self.headers.get("X-Admin-Token") != ADMIN_TOKEN:
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b"forbidden")
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            body = {}
        tags = body.get("tags") or []
        cleared = []
        for tag in tags:
            # tag is a model-derived directory name, never a path (no "/" or "..")
            if "/" in tag or ".." in tag:
                continue
            result_dir = RESULTS_DIR / tag
            log_file = RESULTS_DIR / f"{tag}.log"
            if result_dir.exists():
                import shutil
                shutil.rmtree(result_dir, ignore_errors=True)
            if log_file.exists():
                log_file.unlink()
            cleared.append(tag)
        if _dispatch_lock.locked():
            self.send_response(409)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"cleared": cleared, "dispatch": "already_running"}).encode())
            return
        threading.Thread(target=dispatcher_thread, daemon=True).start()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"cleared": cleared, "dispatch": "started"}).encode())


def main():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    threading.Thread(target=dispatcher_thread, daemon=True).start()
    port = int(os.environ.get("PORT", "8000"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
