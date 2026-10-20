#!/usr/bin/env python3
"""Checks the published code sets the way the app will: downloads
manifest.json from the public R2 URL, verifies its Ed25519 signature with the
bundled public key, then downloads every file and checks its size and sha256.

    python -P tool/codeset_updater/verify_published.py [--base URL] [--serial N]

Exit code 0 when everything verifies, 1 otherwise.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import codeset_lib as lib  # noqa: E402

DEFAULT_BASE = "https://pub-c522aa6f22b14c29b715aff2d857c424.r2.dev"


def _get(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "SOLIS-codeset-verify/1.0", "Cache-Control": "no-cache"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return r.read()


def verify(base: str, public_key_file: Path, expect_serial: int | None = None, quiet: bool = False) -> list[str]:
    errors: list[str] = []
    raw = _get(f"{base}/manifest.json?verify={int(time.time())}")
    manifest = json.loads(raw)
    try:
        lib.verify_manifest(manifest, lib.load_public_keys(public_key_file))
    except ValueError as e:
        return [f"manifest: {e}"]
    if manifest.get("format") != "solis-codesets/1":
        errors.append(f"manifest: unknown format {manifest.get('format')}")
    if expect_serial is not None and manifest.get("serial") != expect_serial:
        errors.append(f"manifest: serial {manifest.get('serial')}, expected {expect_serial} (CDN cache?)")
    if not quiet:
        print(f"manifest serial {manifest['serial']} signature OK ({manifest['signature']['key_id']}), "
              f"{len(manifest['files'])} files")
    total = 0
    for f in manifest["files"]:
        data = _get(f"{base}/{f['path']}")
        sha = hashlib.sha256(data).hexdigest()
        ok = sha == f["sha256"] and len(data) == f["size"]
        total += len(data)
        if not ok:
            errors.append(f"{f['name']}: sha256/size mismatch")
        if not quiet:
            print(f"  {'OK ' if ok else 'BAD'} {f['name']:32s} {len(data):>9,} B  {sha[:16]}")
    if not quiet:
        print(f"total {total:,} bytes; {'all verified' if not errors else 'ERRORS'}")
    return errors


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=DEFAULT_BASE)
    ap.add_argument("--key", type=Path, default=HERE / "public_key.txt")
    ap.add_argument("--serial", type=int, default=None)
    args = ap.parse_args()
    errors = verify(args.base, args.key, args.serial)
    for e in errors:
        print(e, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
