#!/usr/bin/env python3
"""SOLIS key vault: a local admin page for vendor keys.

Keys are typed into a page served on 127.0.0.1 only. On Save:
  1. They are written to  <solis_mobile>/secrets/keys.local.json  and
     <backend>/.dev.vars  (owner-only permissions; both paths are git-ignored).
  2. Each changed value is pushed to the production Cloudflare Worker with
     `npx wrangler secret put NAME`, the value sent on stdin, never on the command line.
  3. The page only ever sees the last 4 characters of a stored value.

Usage:
    python tool/keyvault/keyvault.py [--dry-run] [--port N] [--no-browser]
                                     [--backend-dir DIR] [--keys-file PATH] [--dev-vars-file PATH]

    --dry-run        do everything except calling wrangler (nothing reaches Cloudflare)
    --port           port on 127.0.0.1 (default 8765; a free port is used if it is taken)
    --no-browser     do not open the browser automatically
    --backend-dir    Worker project (default: ../cloudflare-healthcare-rcm-agentic-cloud next to solis_mobile,
                     or the SOLIS_BACKEND_DIR environment variable)
    --keys-file      override the local JSON store (testing)
    --dev-vars-file  override the .dev.vars path (testing)

Security model:
  * Bound to 127.0.0.1. Requests whose Host header is not 127.0.0.1/localhost are refused (DNS rebinding).
  * A random one-time session token is printed in the terminal. Every API call must send it in the
    X-Session-Token header, with Content-Type application/json, so other local web pages cannot post here.
  * Request bodies and values are never logged.

Python standard library only.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hmac
import http.server
import json
import os
import re
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import webbrowser
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent  # solis_mobile
DEFAULT_BACKEND = Path(os.environ.get("SOLIS_BACKEND_DIR") or (REPO.parent / "cloudflare-healthcare-rcm-agentic-cloud"))

# name -> (kind, pushed_to_worker)
#   kind "secret": masked in the UI, no whitespace allowed
#   kind "config": non-secret configuration, shown in full
FIELDS: dict[str, tuple[str, bool]] = {
    "SOLIS_APP_TOKEN": ("secret", True),
    "ANTHROPIC_API_KEY": ("secret", True),
    "ANTHROPIC_WORKSPACE_ID": ("config", True),
    "DEEPGRAM_API_KEY": ("secret", True),
    "STEDI_API_KEY": ("secret", True),
    "STEDI_MODE": ("config", True),
    "AWS_ACCESS_KEY_ID": ("secret", True),
    "AWS_SECRET_ACCESS_KEY": ("secret", True),
    "AWS_REGION": ("config", True),
    "SOLIS_SUBMITTER_ORG_NAME": ("config", True),
    "SOLIS_SUBMITTER_ID": ("config", True),
    "SOLIS_SUBMITTER_CONTACT_NAME": ("config", True),
    "SOLIS_SUBMITTER_PHONE": ("config", True),
    "SOLIS_SUBMITTER_EMAIL": ("config", True),
    "SOLIS_RECEIVER_ORG_NAME": ("config", True),
}

MAX_VALUE_LEN = 4096
MAX_BODY = 64 * 1024
BAD_CHARS = re.compile(r'["\\\x00-\x1f\x7f]')


# ---------------------------------------------------------------- helpers

def last4(v: str) -> str:
    return v[-4:] if len(v) >= 8 else ""


def validate(name: str, value: str) -> str | None:
    if name not in FIELDS:
        return "unknown field"
    if len(value) > MAX_VALUE_LEN:
        return "value is too long"
    if BAD_CHARS.search(value):
        return "value contains quotes, backslashes or control characters"
    kind, _ = FIELDS[name]
    if kind == "secret" and re.search(r"\s", value):
        return "value contains whitespace (check for a stray space when pasting)"
    if name == "STEDI_MODE" and value not in ("test", "production"):
        return "must be test or production"
    if name == "SOLIS_APP_TOKEN" and len(value) < 32:
        return "must be at least 32 characters (use Generate)"
    return None


def restrict_permissions(path: Path, is_dir: bool = False) -> str:
    """Owner-only access. Returns a short description of what was applied."""
    if os.name == "nt":
        user = os.environ.get("USERNAME") or ""
        domain = os.environ.get("USERDOMAIN") or ""
        principal = f"{domain}\\{user}" if domain and user else user
        if not principal:
            return "icacls skipped (no USERNAME)"
        grant = f"{principal}:(OI)(CI)F" if is_dir else f"{principal}:F"
        r = subprocess.run(
            ["icacls", str(path), "/inheritance:r", "/grant:r", grant],
            capture_output=True, text=True,
        )
        return "owner-only ACL (icacls)" if r.returncode == 0 else f"icacls failed: {r.stderr.strip() or r.stdout.strip()}"
    os.chmod(path, 0o700 if is_dir else 0o600)
    return "chmod " + ("700" if is_dir else "600")


def atomic_write(path: Path, data: str) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=str(path.parent))
    os.close(fd)
    tmp_path = Path(tmp)
    try:
        perm = restrict_permissions(tmp_path)  # lock down before any secret is written
        with open(tmp_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
        return perm
    finally:
        if tmp_path.exists():
            tmp_path.unlink()


def load_store(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    vals = raw.get("values", raw) if isinstance(raw, dict) else {}
    return {k: str(v) for k, v in vals.items() if k in FIELDS and isinstance(v, str) and v}


def render_dev_vars(values: dict[str, str]) -> str:
    lines = [
        "# Local Worker secrets for `wrangler dev`. Written by solis_mobile/tool/keyvault. Do not commit.",
    ]
    for name in FIELDS:
        if values.get(name):
            lines.append(f'{name}="{values[name]}"')
    return "\n".join(lines) + "\n"


def find_npx() -> str | None:
    if os.name == "nt":
        return shutil.which("npx.cmd") or shutil.which("npx")
    return shutil.which("npx")


def scrub(text: str, values: list[str]) -> str:
    for v in sorted((v for v in values if v and len(v) >= 4), key=len, reverse=True):
        text = text.replace(v, "[redacted]")
    return text


def wrangler_put(backend: Path, name: str, value: str, all_values: list[str]) -> tuple[bool, str]:
    npx = find_npx()
    if not npx:
        return False, "npx was not found on PATH (install Node.js)"
    try:
        r = subprocess.run(
            [npx, "--yes", "wrangler", "secret", "put", name],
            cwd=str(backend),
            input=value,  # stdin only, never on the command line
            capture_output=True,
            text=True,
            timeout=180,
            env={**os.environ, "WRANGLER_SEND_METRICS": "false", "NO_COLOR": "1"},
        )
    except subprocess.TimeoutExpired:
        return False, "wrangler timed out after 180 s"
    except OSError as e:
        return False, f"could not start wrangler: {e}"
    out = scrub(((r.stdout or "") + "\n" + (r.stderr or "")).strip(), all_values)
    out = "\n".join(l for l in out.splitlines() if l.strip())[-1500:]
    if r.returncode == 0:
        tail = [l for l in out.splitlines() if "Success" in l or "uploaded" in l.lower()]
        return True, (tail[-1] if tail else "uploaded")
    return False, out or f"wrangler exited with code {r.returncode}"


# ---------------------------------------------------------------- server

class Vault:
    def __init__(self, args):
        self.dry_run: bool = args.dry_run
        self.backend = Path(args.backend_dir).resolve()
        self.keys_file = Path(args.keys_file).resolve() if args.keys_file else REPO / "secrets" / "keys.local.json"
        self.dev_vars = Path(args.dev_vars_file).resolve() if args.dev_vars_file else self.backend / ".dev.vars"
        self.token = secrets.token_urlsafe(32)
        self.lock = threading.Lock()
        self.port = 0

    def status(self) -> dict:
        vals = load_store(self.keys_file)
        fields = {}
        for name, (kind, _) in FIELDS.items():
            v = vals.get(name, "")
            if kind == "secret":
                fields[name] = {"kind": kind, "set": bool(v), "last4": last4(v)}
            else:
                fields[name] = {"kind": kind, "set": bool(v), "value": v}
        return {
            "dryRun": self.dry_run,
            "keysFile": str(self.keys_file),
            "devVarsFile": str(self.dev_vars),
            "backendDir": str(self.backend),
            "backendFound": (self.backend / "wrangler.jsonc").exists() or (self.backend / "wrangler.toml").exists(),
            "fields": fields,
        }

    def save(self, incoming: dict, push_all: bool) -> dict:
        errors = {}
        changes: dict[str, str] = {}
        for name, value in incoming.items():
            if not isinstance(value, str):
                errors[name] = "must be text"
                continue
            value = value.strip()
            if value == "":
                continue  # blank means keep the stored value
            err = validate(name, value)
            if err:
                errors[name] = err
            else:
                changes[name] = value
        if errors:
            return {"ok": False, "errors": errors}

        with self.lock:
            stored = load_store(self.keys_file)
            merged = {**stored, **changes}
            doc = {
                "_comment": "SOLIS vendor keys. Local only. Never commit, never ship in the app.",
                "updatedAt": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
                "values": {k: merged[k] for k in FIELDS if merged.get(k)},
            }
            self.keys_file.parent.mkdir(parents=True, exist_ok=True)
            if self.keys_file.parent.name == "secrets":
                restrict_permissions(self.keys_file.parent, is_dir=True)
            perm_json = atomic_write(self.keys_file, json.dumps(doc, indent=2) + "\n")
            files = [{"path": str(self.keys_file), "permissions": perm_json}]
            if self.dev_vars.parent.exists():
                perm_dev = atomic_write(self.dev_vars, render_dev_vars(merged))
                files.append({"path": str(self.dev_vars), "permissions": perm_dev})
            else:
                files.append({"path": str(self.dev_vars), "permissions": "skipped: backend folder not found"})

            to_push = {k: merged[k] for k in FIELDS if merged.get(k) and FIELDS[k][1] and (push_all or k in changes)}
            results = []
            all_vals = list(merged.values())
            for name, value in to_push.items():
                if self.dry_run:
                    results.append({"name": name, "ok": True, "dryRun": True,
                                    "message": f"dry run: would run `npx wrangler secret put {name}` (value on stdin)",
                                    "last4": last4(value) if FIELDS[name][0] == "secret" else value})
                    continue
                ok, msg = wrangler_put(self.backend, name, value, all_vals)
                results.append({"name": name, "ok": ok, "message": msg,
                                "last4": last4(value) if FIELDS[name][0] == "secret" else value})
            return {"ok": all(r["ok"] for r in results), "files": files, "pushed": results, "status": self.status()}


def make_handler(vault: Vault):
    page = (HERE / "keys.html").read_text(encoding="utf-8")

    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "SOLISKeyVault"
        sys_version = ""

        def log_message(self, fmt, *args):  # method and path only, never bodies or query strings
            sys.stderr.write(f"  {self.command} {self.path.split('?')[0].split('#')[0]} -> {args[1] if len(args) > 1 else ''}\n")

        def _host_ok(self) -> bool:
            host = (self.headers.get("Host") or "").lower()
            return host in (f"127.0.0.1:{vault.port}", f"localhost:{vault.port}")

        def _origin_ok(self) -> bool:
            origin = self.headers.get("Origin")
            return origin is None or origin in (f"http://127.0.0.1:{vault.port}", f"http://localhost:{vault.port}")

        def _token_ok(self) -> bool:
            given = self.headers.get("X-Session-Token") or ""
            return hmac.compare_digest(given.encode(), vault.token.encode())

        def _send(self, code: int, body: bytes, ctype: str, extra: dict | None = None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Referrer-Policy", "no-referrer")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def _json(self, code: int, obj):
            self._send(code, json.dumps(obj).encode(), "application/json; charset=utf-8")

        def _guard(self, need_token: bool) -> bool:
            if not self._host_ok():
                self._json(403, {"error": "bad host"})
                return False
            if not self._origin_ok():
                self._json(403, {"error": "cross-origin request refused"})
                return False
            if need_token and not self._token_ok():
                self._json(401, {"error": "missing or wrong session token (see the terminal)"})
                return False
            return True

        def do_GET(self):
            path = self.path.split("?")[0]
            if path in ("/", "/keys.html"):
                if not self._guard(False):
                    return
                nonce = secrets.token_urlsafe(16)
                html = page.replace("{{NONCE}}", nonce).encode()
                csp = (f"default-src 'none'; script-src 'nonce-{nonce}'; style-src 'nonce-{nonce}'; "
                       "connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
                self._send(200, html, "text/html; charset=utf-8", {"Content-Security-Policy": csp})
            elif path == "/api/status":
                if self._guard(True):
                    self._json(200, vault.status())
            else:
                self._json(404, {"error": "not found"})

        def do_POST(self):
            path = self.path.split("?")[0]
            if path != "/api/save":
                self._json(404, {"error": "not found"})
                return
            if not self._guard(True):
                return
            if not (self.headers.get("Content-Type") or "").lower().startswith("application/json"):
                self._json(415, {"error": "Content-Type must be application/json"})
                return
            try:
                n = int(self.headers.get("Content-Length") or "0")
            except ValueError:
                n = 0
            if n <= 0 or n > MAX_BODY:
                self._json(413, {"error": "bad body size"})
                return
            try:
                body = json.loads(self.rfile.read(n).decode("utf-8"))
                values = body.get("values") or {}
                if not isinstance(values, dict):
                    raise ValueError
            except (ValueError, AttributeError, UnicodeDecodeError):
                self._json(400, {"error": "invalid JSON"})
                return
            try:
                result = vault.save(values, bool(body.get("pushAll")))
            except Exception as e:  # never include values in the message
                self._json(500, {"ok": False, "error": f"save failed: {type(e).__name__}"})
                return
            self._json(200 if result.get("ok") or "pushed" in result else 400, result)

        def do_PUT(self):
            self._json(405, {"error": "method not allowed"})

        do_DELETE = do_PUT
        do_PATCH = do_PUT

    return Handler


def pick_port(preferred: int) -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        try:
            s.bind(("127.0.0.1", preferred))
        except OSError:
            s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="SOLIS local key vault")
    ap.add_argument("--dry-run", action="store_true", help="do everything except calling wrangler")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-browser", action="store_true")
    ap.add_argument("--backend-dir", default=str(DEFAULT_BACKEND))
    ap.add_argument("--keys-file")
    ap.add_argument("--dev-vars-file")
    args = ap.parse_args(argv)

    vault = Vault(args)
    vault.port = pick_port(args.port)
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", vault.port), make_handler(vault))
    url = f"http://127.0.0.1:{vault.port}/"

    print("")
    print("  SOLIS key vault" + ("  [DRY RUN: nothing is sent to Cloudflare]" if vault.dry_run else ""))
    print(f"  Page:           {url}")
    print(f"  Session token:  {vault.token}")
    print(f"  Local store:    {vault.keys_file}")
    print(f"  Worker project: {vault.backend}" + ("" if vault.status()["backendFound"] else "  (NOT FOUND)"))
    print("  Press Ctrl+C to stop. The token is valid until then.")
    print("")
    if not args.no_browser:
        # The token travels in the URL fragment, which browsers never send to the server.
        webbrowser.open(f"{url}#token={vault.token}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
