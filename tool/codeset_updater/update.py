#!/usr/bin/env python3
"""Build, validate, sign and publish the SOLIS official code sets.

    python -P tool/codeset_updater/update.py              # publish if CMS posted something new
    python -P tool/codeset_updater/update.py --dry-run    # build + gates + sign, no upload
    python -P tool/codeset_updater/update.py --force      # rebuild and publish even if nothing is pending

Steps (docs/CODESET_UPDATES.md has the full design):
 1. Ask the release monitor Worker (GET /v1/releases) which CMS releases are
    new compared with the published manifest. If the Worker is unreachable,
    the same detection runs locally (codeset_lib.check_all).
 2. Download the official files from www.cms.gov into the cache folder
    (default %TEMP%/solis_codesets, shared with the build scripts).
 3. Run tool/build_knowledge_base.py and tool/build_code_assets.py into a
    staging folder. The repository (assets/, knowledge/, lib/) is never written.
 4. Validation gates: row counts, code formats, no CPT free text, diff
    against the published (or bundled) set, guideline citation check. Any
    problem stops the run (exit 2) unless that gate is named with --allow.
 5. Write manifest.json (serial, effective dates, sha256 per file) and sign it
    with the Ed25519 key in secrets/codeset_signing_ed25519.pem (or the
    CODESET_SIGNING_KEY environment variable, PEM text).
 6. Upload new files (content addressed: files/<sha256>/<name>), then
    reports/<serial>.json, manifests/<serial>.json and finally manifest.json
    to the R2 bucket solis-codesets with wrangler, then verify the public copy.

Requires: Python 3.11+, PyMuPDF (knowledge base PDF parsing), cryptography,
and wrangler (logged in, or CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID).
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))
import codeset_lib as lib  # noqa: E402

WORKER_URL = "https://solis-codesets-worker.cbvarshini1.workers.dev"
PUBLIC_BASE = "https://pub-c522aa6f22b14c29b715aff2d857c424.r2.dev"
BUCKET = "solis-codesets"
FORMAT = "solis-codesets/1"
DEFAULT_KEY = REPO / "secrets" / "codeset_signing_ed25519.pem"
DEFAULT_WRANGLER = Path(r"C:\Users\varsh\cloudflare-healthcare-rcm-agentic-cloud\node_modules\.bin\wrangler.cmd")
ALLOWED_DOWNLOAD_HOSTS = ("www.cms.gov", "cms.gov")


def log(msg: str) -> None:
    print(msg, flush=True)


def http_get(url: str, timeout: int = 120) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": lib.USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# 1. What is new -------------------------------------------------------------

def get_releases(worker: str, local: bool) -> dict:
    if not local:
        try:
            data = json.loads(http_get(f"{worker}/v1/releases", timeout=60))
            log(f"release monitor: checked {data['checked_at']}, pending {data['pending'] or 'none'}")
            if data.get("errors"):
                log(f"  monitor page errors (previous detection kept): {data['errors']}")
            return {"releases": data["releases"], "errors": data.get("errors", {}), "via": "worker"}
        except (urllib.error.URLError, TimeoutError, KeyError, ValueError) as e:
            log(f"release monitor unreachable ({e}); detecting locally")
    res = lib.check_all(lib.fetch_page, dt.date.today())
    res["via"] = "local"
    if res["errors"]:
        log(f"  local detection errors: {res['errors']}")
    return res


def get_published() -> tuple[dict | None, dict]:
    try:
        m = json.loads(http_get(f"{PUBLIC_BASE}/manifest.json?t={int(time.time())}", timeout=60))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None, {}
        raise
    lib.verify_manifest(m, lib.load_public_keys(HERE / "public_key.txt"))
    return m, m.get("sources", {})


# 2. Downloads ---------------------------------------------------------------

def download(url: str, target: Path) -> Path:
    if target.exists() and target.stat().st_size > 0:
        return target
    host = url.split("/")[2]
    if host not in ALLOWED_DOWNLOAD_HOSTS or not url.startswith("https://"):
        raise SystemExit(f"refusing download from {url}")
    target.parent.mkdir(parents=True, exist_ok=True)
    log(f"downloading {url}")
    data = http_get(url, timeout=600)
    if data[:5] in (b"<!DOC", b"<html", b"<!doc") or b"/license/ama" in data[:4000]:
        raise SystemExit(f"{url} returned an HTML page (license page?); refusing it")
    tmp = target.with_suffix(target.suffix + ".part")
    tmp.write_bytes(data)
    tmp.replace(target)
    return target


def basename(url: str) -> str:
    return url.rsplit("/", 1)[-1]


# 3. Build -------------------------------------------------------------------

def build(releases: list[dict], cache: Path, stage: Path) -> dict:
    """Builds every asset into stage/out. Returns build info (which releases went in, pinned items)."""
    rel = {r["id"]: r for r in releases}
    info = {"used": {}, "pinned": {}, "notes": []}

    # Knowledge base (Tabular notes, guidelines, MCE, add-on edits, rule catalog).
    kb = load_module("solis_build_knowledge_base", REPO / "tool" / "build_knowledge_base.py")
    fy = kb.EDITION["icd_fy"]
    icd_kb = rel.get(f"icd10cm-{fy}")
    if icd_kb is None:
        raise SystemExit(f"knowledge base edition FY{fy} is not among the detected ICD-10-CM releases")
    kb.SOURCES["order"].update(path=f"icd/{basename(icd_kb['urls']['descriptions'])}", url=icd_kb["urls"]["descriptions"])
    kb.SOURCES["tabular"].update(path=f"icd/{basename(icd_kb['urls']['tables_index'])}", url=icd_kb["urls"]["tables_index"])

    def pin_or_use(rid: str, kb_key: str, matches: bool, subdir: str = "kb"):
        r = rel.get(rid)
        configured = lib._stem(kb.SOURCES[kb_key]["url"])
        if r and matches:
            kb.SOURCES[kb_key].update(path=f"{subdir}/{basename(r['urls'][next(iter(r['urls']))])}",
                                      url=r["urls"][next(iter(r["urls"]))])
            info["used"][rid] = r["version"]
        else:
            info["pinned"][rid] = configured
            if r and r["version"] != configured:
                info["notes"].append(
                    f"{rid}: CMS has {r['version']}, the builder is configured for {configured}; update EDITION/SOURCES "
                    f"in tool/build_knowledge_base.py (and asset names in build_code_assets.py) to adopt it")

    g = rel.get("icd10cm-guidelines")
    pin_or_use("icd10cm-guidelines", "guidelines", bool(g and g["effective_to"].startswith(str(fy))))
    m = rel.get("mce")
    pin_or_use("mce", "mce", bool(m and f"v{kb.EDITION['mce_version']}" in m["label"].split()[3]))
    n = rel.get("ncci-manual")
    pin_or_use("ncci-manual", "ncci_manual", bool(n and n["effective_from"].startswith(str(kb.EDITION["ncci_year"]))))
    a = rel.get("ncci-addon")
    if a:
        kb.SOURCES["aoc"].update(path=f"kb/{basename(a['urls']['file'])}", url=a["urls"]["file"])
        info["used"]["ncci-addon"] = a["version"]
        aoc_as_of = a["effective_from"]
        orig_aoc = kb.build_aoc
        kb.build_aoc = lambda z, o, as_of=None: orig_aoc(z, o, as_of=aoc_as_of)
    for key in ("guidelines", "tabular", "order", "mce", "aoc", "ncci_manual"):
        s = kb.SOURCES[key]
        download(s["url"], cache / s["path"])
    info["used"][f"icd10cm-{fy}"] = icd_kb["version"]

    knowledge = stage / "knowledge"
    log(f"building knowledge base (FY{fy}) ...")
    with contextlib.redirect_stdout(io.StringIO()) as buf:
        argv = sys.argv
        sys.argv = ["build_knowledge_base.py", "--downloads", str(cache), "--out", str(knowledge), "--offline"]
        try:
            kb.main()
        finally:
            sys.argv = argv
    (stage / "build_knowledge_base.log").write_text(buf.getvalue(), encoding="utf-8")
    report = json.loads((knowledge / "build_report.json").read_text(encoding="utf-8"))
    info["kb_citation_problems"] = report.get("citation_problems") or []

    # Code assets. The module is loaded with its __file__ pointing into a
    # shadow tree, so the generated lib/.../rule_citations.g.dart lands in
    # staging instead of the app sources.
    shadow = stage / "shadow"
    (shadow / "tool").mkdir(parents=True, exist_ok=True)
    (shadow / "lib" / "services" / "coding").mkdir(parents=True, exist_ok=True)
    bca = load_module("solis_build_code_assets", REPO / "tool" / "build_code_assets.py")
    bca.__file__ = str(shadow / "tool" / "build_code_assets.py")
    # build_code_assets imports build_knowledge_base from its own folder; with
    # __file__ redirected to the shadow tree, put the real tool folder on the path.
    if str(REPO / "tool") not in sys.path:
        sys.path.insert(0, str(REPO / "tool"))
    out = stage / "out"
    out.mkdir(parents=True, exist_ok=True)
    log("building code assets ...")
    with contextlib.redirect_stdout(io.StringIO()) as buf:
        for r in releases:
            if not r["id"].startswith("icd10cm-") or r["id"] == "icd10cm-guidelines":
                continue
            efy = int(r["id"].split("-")[1])
            dz = download(r["urls"]["descriptions"], cache / "icd" / basename(r["urls"]["descriptions"]))
            iz = download(r["urls"]["tables_index"], cache / "icd" / basename(r["urls"]["tables_index"]))
            known = bca.build_icd(dz, out, efy)
            bca.build_icd_index(iz, out, known, efy)
            if efy != bca.KNOWLEDGE_FY:
                # Excludes1, 7th characters and Tabular notes of this edition, so
                # a claim is checked against the notes of its date of service.
                bca.build_tabular_from_zips(dz, iz, out, efy, work=cache)
            info["used"][r["id"]] = r["version"]
        for rid, sub, fn in (("hcpcs", "hcpcs", bca.build_hcpcs), ("pfs-rvu", "rvu", bca.build_rvu),
                             ("mue-practitioner", "mue", bca.build_mue)):
            r = rel.get(rid)
            if r is None:
                raise SystemExit(f"no detected release for {rid}")
            if rid == "hcpcs":
                bca.AS_OF = r["effective_from"].replace("-", "")
            fn(download(r["urls"]["file"], cache / sub / basename(r["urls"]["file"])), out)
            info["used"][rid] = r["version"]
        addon = sorted((knowledge / "rules").glob("ncci_addon_code_edits_*.tsv"))
        if addon:
            bca.KNOWLEDGE_FILES["addon"] = addon[-1].name
        bca.build_knowledge(knowledge / "rules", out)
    (stage / "build_code_assets.log").write_text(buf.getvalue(), encoding="utf-8")
    return info


# 4. Gates -------------------------------------------------------------------

EXPECTED_KNOWLEDGE = ("icd10cm_excludes1_", "icd_7th_", "mce_v", "ncci_addon", "icd_notes_", "guidelines_fy",
                      "rule_catalog")


def baseline_for(name: str, prev_manifest: dict | None, stage: Path) -> tuple[Path | None, str | None]:
    """The file to diff against: the published copy, else the bundled asset,
    else (a new ICD edition) the previous edition."""
    base = stage / "baseline"
    base.mkdir(exist_ok=True)
    if prev_manifest:
        f = next((x for x in prev_manifest["files"] if x["name"] == name), None)
        if f:
            p = base / name
            if not p.exists():
                p.write_bytes(http_get(f"{PUBLIC_BASE}/{f['path']}", timeout=300))
            if lib.sha256_file(p) != f["sha256"]:
                raise SystemExit(f"published {name} does not match its manifest hash")
            return p, "published"
    bundled = REPO / "assets" / "codes" / name
    if bundled.exists():
        return bundled, "bundled"
    spec = lib.spec_for(name)
    if spec and spec["set"] in ("icd10cm", "icd10cm_index") and spec["edition"]:
        prev_name = name.replace(spec["edition"], str(int(spec["edition"]) - 1))
        p, kind = baseline_for(prev_name, prev_manifest, stage)
        if p is not None:
            return p, "previous-edition"
    return None, None


def run_gates(stage: Path, info: dict, prev_manifest: dict | None) -> dict:
    out = stage / "out"
    files = sorted(out.glob("*.tsv.gz"))
    reports = []
    problems: dict[str, str] = {}
    for p in files:
        b, kind = baseline_for(p.name, prev_manifest, stage)
        rep = lib.validate_file(p, b, kind)
        reports.append(rep)
        problems.update(rep["problems"])
    names = [p.name for p in files]
    for prefix in EXPECTED_KNOWLEDGE:
        if not any(n.startswith(prefix) for n in names):
            problems[f"missing:{prefix}"] = f"no {prefix}* asset was built"
    for core in ("hcpcs.tsv.gz", "pfs_rvu.tsv.gz", "mue_practitioner.tsv.gz"):
        if core not in names:
            problems[f"missing:{core}"] = "not built"
    icd = [n for n in names if lib.spec_for(n) and lib.spec_for(n)["set"] == "icd10cm"]
    if not icd:
        problems["missing:icd10cm"] = "no ICD-10-CM edition built"
    for n in icd:
        if n.replace("icd10cm_", "icd10cm_index_") not in names:
            problems[f"missing:index:{n}"] = "edition without its index"
    guide = next((p for p in files if p.name.startswith("guidelines_fy")), None)
    cat = out / "rule_catalog.tsv.gz"
    if guide and cat.exists():
        cp = lib.citation_problems(guide, cat)
        if cp:
            problems["citations"] = "; ".join(cp[:10])
    if info.get("kb_citation_problems"):
        problems["kb-citations"] = json.dumps(info["kb_citation_problems"])[:500]
    return {"files": reports, "problems": problems}


# 5. Manifest ----------------------------------------------------------------

def file_meta(name: str, releases: dict) -> dict:
    spec = lib.spec_for(name)
    s = spec["set"]
    if s in ("icd10cm", "icd10cm_index"):
        rid = f"icd10cm-{spec['edition']}"
    elif s in ("icd10cm_excludes1", "icd_7th", "icd_notes"):
        rid = f"icd10cm-{spec['edition']}"
    else:
        rid = {"hcpcs": "hcpcs", "pfs_rvu": "pfs-rvu", "mue_practitioner": "mue-practitioner",
               "ncci_addon": "ncci-addon", "mce": "mce", "guidelines": "icd10cm-guidelines",
               "rule_catalog": "icd10cm-guidelines"}[s]
    r = releases.get(rid, {})
    meta = {"set": s, "release": rid}
    if s in ("icd10cm", "icd10cm_index"):
        fy = int(spec["edition"])
        meta.update(edition=f"FY{fy}", effective_from=f"{fy - 1}-10-01", effective_to=f"{fy}-09-30",
                    select="date_of_service")
    else:
        if spec["edition"]:
            meta["edition"] = (f"v{spec['edition']}" if s == "mce" else f"FY{spec['edition']}")
        if r.get("effective_from"):
            meta["effective_from"] = r["effective_from"]
        meta["select"] = "latest"
    return meta


def next_serial(prev: dict | None, today: dt.date) -> int:
    base = int(today.strftime("%Y%m%d")) * 100 + 1
    return max(base, (prev or {}).get("serial", 0) + 1)


def make_manifest(stage: Path, releases: list[dict], info: dict, gates: dict, prev: dict | None) -> dict:
    out = stage / "out"
    rel = {r["id"]: r for r in releases}
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    serial = next_serial(prev, now.date())
    diffs = {f["name"]: f.get("diff", {}) for f in gates["files"]}
    files = []
    for p in sorted(out.glob("*.tsv.gz")):
        sha = lib.sha256_file(p)
        d = diffs.get(p.name, {})
        entry = {
            "name": p.name,
            "sha256": sha,
            "size": p.stat().st_size,
            "rows": next(f["rows"] for f in gates["files"] if f["name"] == p.name),
            "path": f"files/{sha}/{p.name}",
            **file_meta(p.name, rel),
        }
        if d.get("baseline"):
            entry["changes"] = {"added": d["added"], "removed": d["removed"], "changed": d["changed"],
                                "baseline": d["baseline"]}
        files.append(entry)
    used = {**info["used"], **info["pinned"]}
    sources = {k: used[k] for k in sorted(used)}
    published_releases = []
    for rid in sorted(sources):
        r = rel.get(rid)
        if r and r["version"] == sources[rid]:
            published_releases.append({k: r[k] for k in ("id", "version", "label", "effective_from", "effective_to",
                                                          "page", "urls") if k in r})
        else:
            published_releases.append({"id": rid, "version": sources[rid], "label": f"{rid} (pinned by the builder)"})
    manifest = {
        "format": FORMAT,
        "serial": serial,
        "generated_at": now.isoformat().replace("+00:00", "Z"),
        "previous_serial": (prev or {}).get("serial"),
        "publisher": "SOLIS code-set updater",
        "license_note": "Public-domain US government data (CMS, NCHS). No CPT descriptors.",
        "sources": sources,
        "releases": published_releases,
        "files": files,
    }
    return manifest


# 6. Upload ------------------------------------------------------------------

def wrangler_cmd() -> list[str]:
    env = os.environ.get("WRANGLER")
    if env:
        return env.split()
    if DEFAULT_WRANGLER.exists():
        return [str(DEFAULT_WRANGLER)]
    return ["npx", "--yes", "wrangler@4.149.0"]


def r2_put(key: str, path: Path, content_type: str, cache_control: str) -> None:
    cmd = wrangler_cmd() + ["r2", "object", "put", f"{BUCKET}/{key}", "--file", str(path),
                            "--content-type", content_type, "--cache-control", cache_control, "--remote"]
    for attempt in range(3):
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace",
                           shell=os.name == "nt" and cmd[0].endswith(".cmd"))
        if r.returncode == 0:
            return
        log(f"  upload of {key} failed (attempt {attempt + 1}): {(r.stderr or r.stdout)[-400:]}")
        time.sleep(3 * (attempt + 1))
    raise SystemExit(f"upload failed: {key}")


def publish(stage: Path, manifest: dict, prev: dict | None) -> None:
    have = {f["path"] for f in (prev or {}).get("files", [])}
    for f in manifest["files"]:
        if f["path"] in have:
            log(f"  unchanged {f['name']}")
            continue
        log(f"  upload {f['path']} ({f['size']:,} bytes)")
        r2_put(f["path"], stage / "out" / f["name"], "application/octet-stream",
               "public, max-age=31536000, immutable")
    serial = manifest["serial"]
    r2_put(f"reports/{serial}.json", stage / "report.json", "application/json", "public, max-age=86400")
    r2_put(f"manifests/{serial}.json", stage / "manifest.json", "application/json", "public, max-age=31536000, immutable")
    # Last: the pointer every app reads. Short cache so updates reach apps within the hour.
    r2_put("manifest.json", stage / "manifest.json", "application/json", "public, max-age=900")


def verify_public(manifest: dict) -> None:
    import verify_published

    errors = verify_published.verify(PUBLIC_BASE, HERE / "public_key.txt", expect_serial=manifest["serial"])
    if errors:
        raise SystemExit("public verification failed:\n" + "\n".join(errors))


# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--worker", default=WORKER_URL)
    ap.add_argument("--local-detect", action="store_true", help="detect releases here instead of asking the Worker")
    ap.add_argument("--cache", type=Path,
                    default=Path(os.environ.get("SOLIS_CODESETS_CACHE") or Path(tempfile.gettempdir()) / "solis_codesets"))
    ap.add_argument("--staging", type=Path, default=None)
    ap.add_argument("--key", type=Path, default=DEFAULT_KEY)
    ap.add_argument("--dry-run", action="store_true", help="build, validate and sign; do not upload")
    ap.add_argument("--force", action="store_true", help="publish even when nothing is pending")
    ap.add_argument("--allow", action="append", default=[], metavar="GATE",
                    help="accept one named gate problem (for example change:pfs_rvu.tsv.gz) after review")
    args = ap.parse_args()

    det = get_releases(args.worker, args.local_detect)
    releases = det["releases"]
    prev, published = get_published()
    pending = [r["id"] for r in releases if published.get(r["id"]) != r["version"]]
    log(f"published serial: {(prev or {}).get('serial')}; pending: {pending or 'none'}")
    if not pending and not args.force:
        log("up to date; nothing to publish")
        return 0

    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    stage = args.staging or Path(tempfile.gettempdir()) / "solis_codeset_staging" / stamp
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    log(f"staging: {stage}")
    log(f"cache: {args.cache}")

    info = build(releases, args.cache, stage)
    gates = run_gates(stage, info, prev)
    blocking = {k: v for k, v in gates["problems"].items() if k not in args.allow}
    manifest = make_manifest(stage, releases, info, gates, prev)

    # Nothing actually changed (for example only a pinned item is pending): do not republish.
    same = prev and [(f["name"], f["sha256"]) for f in prev["files"]] == [(f["name"], f["sha256"]) for f in manifest["files"]] \
        and prev.get("sources") == manifest["sources"]

    report = {
        "serial": manifest["serial"],
        "generated_at": manifest["generated_at"],
        "detected_via": det["via"],
        "detection_errors": det["errors"],
        "pending": pending,
        "used": info["used"],
        "pinned": info["pinned"],
        "notes": info["notes"],
        "gate_problems": gates["problems"],
        "allowed": [k for k in gates["problems"] if k in args.allow],
        "files": gates["files"],
    }
    (stage / "report.json").write_text(json.dumps(report, indent=1), encoding="utf-8")

    log("\nfiles:")
    for f in manifest["files"]:
        c = f.get("changes")
        ch = f"+{c['added']} -{c['removed']} ~{c['changed']} vs {c['baseline']}" if c else "no baseline"
        log(f"  {f['name']:32s} {f['rows']:>7,} rows {f['size']:>9,} B  {ch}")
    for note in info["notes"]:
        log(f"note: {note}")
    if blocking:
        log("\nREFUSING TO PUBLISH, gate problems:")
        for k, v in blocking.items():
            log(f"  [{k}] {v}")
        log(f"report: {stage / 'report.json'}")
        return 2

    key_pem = os.environ.get("CODESET_SIGNING_KEY", "").encode() or args.key.read_bytes()
    signed = lib.sign_manifest(manifest, key_pem)
    lib.verify_manifest(signed, lib.load_public_keys(HERE / "public_key.txt"))
    (stage / "manifest.json").write_text(json.dumps(signed, indent=1) + "\n", encoding="utf-8", newline="\n")
    log(f"\nmanifest serial {signed['serial']} signed by {signed['signature']['key_id']}: {stage / 'manifest.json'}")

    if same and not args.force:
        log("built files and sources equal the published manifest; not republishing")
        return 0
    if args.dry_run:
        log("dry run: not uploading")
        return 0
    log("uploading to R2 ...")
    publish(stage, signed, prev)
    verify_public(signed)
    log(f"published {PUBLIC_BASE}/manifest.json (serial {signed['serial']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
