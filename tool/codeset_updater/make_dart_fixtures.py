#!/usr/bin/env python3
"""Writes the cross-language test vectors for test/codeset_update/codeset_update_client_test.dart:
a manifest signed by the Python signer (codeset_lib.sign_manifest) with a
fixed TEST key, its canonical bytes, and the small files it lists.

    python -P tool/codeset_updater/make_dart_fixtures.py

The test key is derived from a constant seed and is NOT the production key.
"""

from __future__ import annotations

import base64
import gzip
import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import codeset_lib as lib  # noqa: E402
from cryptography.hazmat.primitives import serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402

OUT = HERE.parent.parent / "test" / "codeset_update" / "fixtures"
SEED = bytes(range(1, 33))


def gz(text: str) -> bytes:
    return gzip.compress(text.encode("utf-8"), compresslevel=9, mtime=0)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "files").mkdir(exist_ok=True)
    key = Ed25519PrivateKey.from_private_bytes(SEED)
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    raw_pub = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    kid = lib.key_id_for(raw_pub)
    (OUT / "test_public_key.txt").write_text(
        f"# TEST key only (seed 01..20). Never trust this in the app.\n{kid} {base64.b64encode(raw_pub).decode()}\n",
        encoding="utf-8", newline="\n")

    contents = {
        "icd10cm_2026.tsv.gz": gz("A00\t0\tCholera\nA00.0\t1\tCholera due to Vibrio cholerae 01, biovar cholerae\n"),
        "icd10cm_2027.tsv.gz": gz("A00\t0\tCholera\nA00.0\t1\tCholera due to Vibrio cholerae 01, biovar cholerae\n"
                                  "I42.00\t1\tCardiomyopathy, unspecified type\n"),
        "hcpcs.tsv.gz": gz("A0021\tOutside state ambulance serv\tAmbulance service, outside state per mile\n"),
    }
    files = []
    meta = {
        "icd10cm_2026.tsv.gz": {"set": "icd10cm", "release": "icd10cm-2026", "edition": "FY2026",
                                "effective_from": "2025-10-01", "effective_to": "2026-09-30", "select": "date_of_service"},
        "icd10cm_2027.tsv.gz": {"set": "icd10cm", "release": "icd10cm-2027", "edition": "FY2027",
                                "effective_from": "2026-10-01", "effective_to": "2027-09-30", "select": "date_of_service"},
        "hcpcs.tsv.gz": {"set": "hcpcs", "release": "hcpcs", "effective_from": "2026-10-01", "select": "latest"},
    }
    for name, data in contents.items():
        sha = hashlib.sha256(data).hexdigest()
        (OUT / "files" / name).write_bytes(data)
        files.append({"name": name, "sha256": sha, "size": len(data), "rows": data and gzip.decompress(data).count(b"\n"),
                      "path": f"files/{sha}/{name}", **meta[name]})
    manifest = {
        "format": "solis-codesets/1",
        "serial": 2026101701,
        "generated_at": "2026-10-17T12:00:00Z",
        "previous_serial": None,
        "publisher": "SOLIS code-set updater (test vector)",
        "license_note": "Test data with \"quotes\", back\\slash and / slash.",
        "sources": {"hcpcs": "october-2026-alpha-numeric-hcpcs-file", "icd10cm-2026": "2026-04-01",
                    "icd10cm-2027": "2026-10-01"},
        "releases": [],
        "files": files,
    }
    signed = lib.sign_manifest(manifest, pem)
    lib.verify_manifest(signed, {kid: raw_pub})
    (OUT / "manifest_v1.json").write_text(json.dumps(signed, indent=1) + "\n", encoding="utf-8", newline="\n")
    body = {k: v for k, v in signed.items() if k != "signature"}
    (OUT / "manifest_v1.canonical.txt").write_bytes(lib.canonical_json(body))
    print(f"wrote fixtures to {OUT} (key {kid})")


if __name__ == "__main__":
    main()
