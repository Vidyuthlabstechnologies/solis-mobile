"""Shared pieces of the SOLIS code-set updater (standard library only, except
the signing helpers, which need the `cryptography` package).

- CMS release detection: a mirror of solis-codesets-worker/src/detect.ts,
  used by update.py when the Worker cannot be reached. test_update.py checks
  that both return the same releases for the same pages.
- Canonical JSON and the Ed25519 manifest signature.
- Validation gates and the diff against the previously published set.
"""

from __future__ import annotations

import base64
import datetime as dt
import gzip
import hashlib
import json
import re
import urllib.parse
import urllib.request
from pathlib import Path

CMS_ORIGIN = "https://www.cms.gov"
USER_AGENT = "SOLIS-codeset-monitor/1.0 (daily release check)"

PAGES = {
    "icd": "https://www.cms.gov/medicare/coding-billing/icd-10-codes",
    "hcpcs": "https://www.cms.gov/medicare/coding-billing/healthcare-common-procedure-system/quarterly-update",
    "rvuIndex": "https://www.cms.gov/medicare/payment/fee-schedules/physician/pfs-relative-value-files",
    "mue": "https://www.cms.gov/medicare/coding-billing/national-correct-coding-initiative-ncci-edits/medicare-ncci-medically-unlikely-edits-mues",
    "aoc": "https://www.cms.gov/medicare/coding-billing/national-correct-coding-initiative-ncci-edits/medicare-ncci-add-code-edits",
    "mce": "https://www.cms.gov/medicare/payment/prospective-payment-systems/acute-inpatient-pps/ms-drg-classifications-and-software",
    "ncciManual": "https://www.cms.gov/medicare/coding-billing/national-correct-coding-initiative-ncci-edits/medicare-ncci-policy-manual",
}

MONTHS = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
          "october", "november", "december"]


def _iso(y: int, m: int, d: int) -> str:
    return f"{y:04d}-{m:02d}-{d:02d}"


def fiscal_year(day: dt.date) -> int:
    return day.year + 1 if day.month >= 10 else day.year


# ---------------------------------------------------------------------------
# Detection (mirror of detect.ts)
# ---------------------------------------------------------------------------

_HREF = re.compile(r"""href\s*=\s*"([^"]+)"|href\s*=\s*'([^']+)'""", re.I)


def extract_hrefs(html: str, base: str = CMS_ORIGIN) -> list[str]:
    out, seen = [], set()
    for m in _HREF.finditer(html):
        raw = (m.group(1) or m.group(2) or "").replace("&amp;", "&").strip()
        if not raw or raw.startswith(("#", "mailto:", "javascript:")):
            continue
        absu = urllib.parse.urljoin(base + "/", raw)
        if absu not in seen:
            seen.add(absu)
            out.append(absu)
    return out


def is_cms_url(u: str) -> bool:
    p = urllib.parse.urlsplit(u)
    return p.scheme == "https" and p.hostname in ("www.cms.gov", "cms.gov")


def _path(u: str) -> str:
    return urllib.parse.urlsplit(u).path


def _stem(u: str) -> str:
    return re.sub(r"\.(zip|pdf)$", "", _path(u).split("/")[-1], flags=re.I)


def _cms_links(html: str) -> list[str]:
    return [u for u in extract_hrefs(html) if is_cms_url(u)]


ICD_DESC = re.compile(r"/files/zip/(?:([a-z]+)-(\d{1,2})-)?(\d{4})-code-descriptions-tabular-order(?:-[a-z0-9-]+)?\.zip$")
ICD_INDEX = re.compile(r"/files/zip/(?:([a-z]+)-(\d{1,2})-)?(\d{4})-code-tables-tabular-(?:and-)?index(?:-[a-z0-9-]+)?\.zip$")
ICD_GUIDE = re.compile(r"/files/document/fy-?(\d{4})-icd-10-cm-(?:coding-)?guidelines(?:-[a-z0-9-]+)?\.pdf$")


def _icd_file(u: str, rx: re.Pattern):
    m = rx.search(_path(u))
    if not m:
        return None
    year = int(m.group(3))
    if not m.group(1):
        return {"fy": year, "effective": _iso(year - 1, 10, 1), "url": u}
    if m.group(1) not in MONTHS:
        return None
    month = MONTHS.index(m.group(1)) + 1
    fy = year + 1 if month >= 10 else year
    return {"fy": fy, "effective": _iso(year, month, int(m.group(2))), "url": u}


def parse_icd(html: str, today: dt.date) -> list[dict]:
    links = _cms_links(html)
    desc = [x for x in (_icd_file(u, ICD_DESC) for u in links) if x]
    index = [x for x in (_icd_file(u, ICD_INDEX) for u in links) if x]
    min_fy = fiscal_year(today) - 1
    by_fy: dict[int, tuple] = {}
    for d in desc:
        if d["fy"] < min_fy:
            continue
        i = next((x for x in index if x["fy"] == d["fy"] and x["effective"] == d["effective"]), None)
        if not i:
            continue
        cur = by_fy.get(d["fy"])
        if not cur or d["effective"] > cur[0]["effective"]:
            by_fy[d["fy"]] = (d, i)
    out = []
    for fy in sorted(by_fy):
        d, i = by_fy[fy]
        upd = d["effective"] != _iso(fy - 1, 10, 1)
        out.append({
            "id": f"icd10cm-{fy}",
            "version": d["effective"],
            "label": f"ICD-10-CM FY{fy}" + (f" (update effective {d['effective']})" if upd else ""),
            "effective_from": _iso(fy - 1, 10, 1),
            "effective_to": _iso(fy, 9, 30),
            "page": PAGES["icd"],
            "urls": {"descriptions": d["url"], "tables_index": i["url"]},
        })
    guide = None
    for u in links:
        m = ICD_GUIDE.search(_path(u))
        if m and (guide is None or int(m.group(1)) > guide[0]):
            guide = (int(m.group(1)), u)
    if guide:
        fy, u = guide
        out.append({
            "id": "icd10cm-guidelines",
            "version": _stem(u),
            "label": f"ICD-10-CM Official Guidelines FY{fy}",
            "effective_from": _iso(fy - 1, 10, 1),
            "effective_to": _iso(fy, 9, 30),
            "page": PAGES["icd"],
            "urls": {"guidelines": u},
        })
    return out


HCPCS = re.compile(r"/files/zip/(january|april|july|october)-(\d{4})-alpha-numeric-hcpcs-files?(?:-[a-z0-9-]+)?\.zip$")


def parse_hcpcs(html: str):
    best = None
    for u in _cms_links(html):
        m = HCPCS.search(_path(u))
        if not m:
            continue
        y, mo = int(m.group(2)), MONTHS.index(m.group(1)) + 1
        key = f"{y}-{mo:02d}-{len(_stem(u)):03d}-{_stem(u)}"
        if best is None or key > best[0]:
            best = (key, y, mo, u)
    if not best:
        return None
    _, y, mo, u = best
    return {
        "id": "hcpcs",
        "version": _stem(u),
        "label": f"HCPCS Level II {MONTHS[mo - 1].capitalize()} {y}",
        "effective_from": _iso(y, mo, 1),
        "page": PAGES["hcpcs"],
        "urls": {"file": u},
    }


RVU_PAGE = re.compile(r"/pfs-relative-value-files(?:-items)?/rvu(\d{2})([a-d])(r\d*|-\d+)?$")
RVU_ZIP = re.compile(r"/files/zip/(rvu(\d{2})([a-d])[a-z0-9-]*)\.zip$")


def parse_rvu_index(html: str):
    best = None
    for u in _cms_links(html):
        m = RVU_PAGE.search(_path(u))
        if not m:
            continue
        year = 2000 + int(m.group(1))
        suf = m.group(3) or ""
        rev = "1" + suf[1:].rjust(2, "0") if suf.startswith("r") else "000"
        rank = f"{year}{m.group(2)}{rev}"
        tag = f"RVU{m.group(1)}{m.group(2).upper()}{suf.upper() if suf.startswith('r') else ''}"
        if best is None or rank > best[0]:
            best = (rank, {"url": u, "year": year, "quarter": m.group(2), "tag": tag})
    return best[1] if best else None


def parse_rvu_page(html: str, page: str, tag: str):
    best = None
    for u in _cms_links(html):
        m = RVU_ZIP.search(_path(u))
        if not m:
            continue
        upd = re.search(r"updated-(\d{2})-(\d{2})-(\d{4})", m.group(1))
        rank = f"{upd.group(3)}{upd.group(1)}{upd.group(2)}" if upd else "00000000"
        if best is None or rank > best[0]:
            best = (rank, u, 2000 + int(m.group(2)), m.group(3))
    if not best:
        return None
    _, u, y, q = best
    return {
        "id": "pfs-rvu",
        "version": _stem(u),
        "label": f"Medicare PFS relative value file {tag}",
        "effective_from": _iso(y, {"a": 1, "b": 4, "c": 7, "d": 10}[q], 1),
        "page": page,
        "urls": {"file": u},
    }


MUE = re.compile(r"/files/zip/medicare-ncci-(\d{4})-q([1-4])-practitioner-services-mue-table(?:-[a-z0-9-]+)?\.zip$")


def parse_mue(html: str):
    best = None
    for u in _cms_links(html):
        m = MUE.search(_path(u))
        if not m:
            continue
        key = f"{m.group(1)}{m.group(2)}{_stem(u)}"
        if best is None or key > best[0]:
            best = (key, int(m.group(1)), int(m.group(2)), u)
    if not best:
        return None
    _, y, q, u = best
    return {
        "id": "mue-practitioner",
        "version": _stem(u),
        "label": f"NCCI MUE practitioner services {y} Q{q}",
        "effective_from": _iso(y, (q - 1) * 3 + 1, 1),
        "page": PAGES["mue"],
        "urls": {"file": u},
    }


AOC = re.compile(r"/files/zip/add-code-edits-medicare-effective-(\d{2})(\d{2})(\d{4})(?:-[a-z0-9-]+)?\.zip$")


def parse_aoc(html: str):
    best = None
    for u in _cms_links(html):
        m = AOC.search(_path(u))
        if not m:
            continue
        date = f"{m.group(3)}-{m.group(1)}-{m.group(2)}"
        if best is None or date > best[0] or (date == best[0] and u > best[1]):
            best = (date, u)
    if not best:
        return None
    date, u = best
    return {
        "id": "ncci-addon",
        "version": _stem(u),
        "label": f"NCCI add-on code edits effective {date}",
        "effective_from": date,
        "page": PAGES["aoc"],
        "urls": {"file": u},
    }


MCE_FR = re.compile(r"/files/zip/fy(\d{4})-fr-definition-mce-v(\d+)(?:-[a-z0-9-]+)?\.zip$")
MCE_MID = re.compile(r"/files/zip/definition-medicare-code-edits-v(\d+)-(\d+)(?:-[a-z0-9-]+)?\.zip$")


def parse_mce(html: str):
    best = None
    for u in _cms_links(html):
        p = _path(u)
        m = MCE_FR.search(p)
        if m:
            major, fy = int(m.group(2)), int(m.group(1))
            rank = major * 100
            if best is None or rank > best[0]:
                best = (rank, f"v{major}", fy, _iso(fy - 1, 10, 1), u)
            continue
        m = MCE_MID.search(p)
        if m:
            major, minor = int(m.group(1)), int(m.group(2))
            fy = major + 1983
            rank = major * 100 + minor
            if best is None or rank > best[0]:
                best = (rank, f"v{major}.{minor}", fy, _iso(fy, 4, 1), u)
    if not best:
        return None
    _, v, fy, eff, u = best
    return {
        "id": "mce",
        "version": _stem(u),
        "label": f"Medicare Code Editor {v} (FY{fy})",
        "effective_from": eff,
        "effective_to": _iso(fy, 9, 30),
        "page": PAGES["mce"],
        "urls": {"file": u},
    }


NCCI_MANUAL = re.compile(r"/files/document/(\d{4})-ncci-medicare-policy-manual-all-chapters(?:-[a-z0-9-]+)?\.pdf$")


def parse_ncci_manual(html: str):
    best = None
    for u in _cms_links(html):
        m = NCCI_MANUAL.search(_path(u))
        if m and (best is None or int(m.group(1)) > best[0] or (int(m.group(1)) == best[0] and u > best[1])):
            best = (int(m.group(1)), u)
    if not best:
        return None
    y, u = best
    return {
        "id": "ncci-manual",
        "version": _stem(u),
        "label": f"Medicare NCCI Policy Manual {y}",
        "effective_from": _iso(y, 1, 1),
        "page": PAGES["ncciManual"],
        "urls": {"file": u},
    }


def fetch_page(url: str, timeout: int = 60) -> str:
    if not is_cms_url(url):
        raise ValueError(f"refusing non-CMS page {url}")
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "text/html"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        text = r.read().decode("utf-8", errors="replace")
    if len(text) < 2000:
        raise ValueError(f"{url}: page too short")
    return text


def check_all(fetch, today: dt.date) -> dict:
    """Same result shape as the Worker's GET /v1/releases (releases + errors)."""
    releases, errors = [], {}

    def run(key, fn):
        try:
            r = fn()
            lst = r if isinstance(r, list) else ([r] if r else [])
            if not lst:
                errors[key] = "no release link found (page layout changed?)"
            releases.extend(lst)
        except Exception as e:  # noqa: BLE001 - recorded per page
            errors[key] = str(e)

    def rvu():
        idx = parse_rvu_index(fetch(PAGES["rvuIndex"]))
        return parse_rvu_page(fetch(idx["url"]), idx["url"], idx["tag"]) if idx else None

    run("icd", lambda: parse_icd(fetch(PAGES["icd"]), today))
    run("hcpcs", lambda: parse_hcpcs(fetch(PAGES["hcpcs"])))
    run("rvu", rvu)
    run("mue", lambda: parse_mue(fetch(PAGES["mue"])))
    run("aoc", lambda: parse_aoc(fetch(PAGES["aoc"])))
    run("mce", lambda: parse_mce(fetch(PAGES["mce"])))
    run("ncciManual", lambda: parse_ncci_manual(fetch(PAGES["ncciManual"])))
    releases.sort(key=lambda r: r["id"])
    return {"releases": releases, "errors": errors}


# ---------------------------------------------------------------------------
# Canonical JSON and signatures
# ---------------------------------------------------------------------------

def _check_canonical(obj, where="$"):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if not isinstance(k, str):
                raise ValueError(f"{where}: non-string key")
            _check_canonical(k, f"{where}.{k}(key)")
            _check_canonical(v, f"{where}.{k}")
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            _check_canonical(v, f"{where}[{i}]")
    elif isinstance(obj, str):
        if any(not (0x20 <= ord(c) <= 0x7E) for c in obj):
            raise ValueError(f"{where}: manifest strings must be printable ASCII")
    elif isinstance(obj, bool) or obj is None:
        pass
    elif isinstance(obj, int):
        if abs(obj) > 2**53:
            raise ValueError(f"{where}: integer out of the safe range")
    else:
        raise ValueError(f"{where}: unsupported type {type(obj).__name__} (no floats)")


def canonical_json(obj) -> bytes:
    """Sorted keys, no whitespace, printable ASCII only, integers only.

    The Dart client (codeset_update_client.dart, canonicalJson) produces the
    same bytes for the same parsed JSON. Signatures cover these bytes.
    """
    _check_canonical(obj)
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def load_public_keys(path: Path) -> dict[str, bytes]:
    keys = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        kid, b64 = line.split()
        raw = base64.b64decode(b64)
        if len(raw) != 32:
            raise ValueError(f"{kid}: Ed25519 public key must be 32 bytes")
        keys[kid] = raw
    return keys


def key_id_for(raw_public: bytes) -> str:
    return "solis-codesets-" + hashlib.sha256(raw_public).hexdigest()[:8]


def sign_manifest(manifest: dict, private_pem: bytes) -> dict:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    key = serialization.load_pem_private_key(private_pem, password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError("signing key is not Ed25519")
    raw_pub = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    body = {k: v for k, v in manifest.items() if k != "signature"}
    sig = key.sign(canonical_json(body))
    return {**body, "signature": {"alg": "Ed25519", "key_id": key_id_for(raw_pub),
                                  "value": base64.b64encode(sig).decode("ascii")}}


def verify_manifest(manifest: dict, keys: dict[str, bytes]) -> None:
    """Raises ValueError unless the manifest is signed by one of `keys`."""
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    sig = manifest.get("signature") or {}
    if sig.get("alg") != "Ed25519":
        raise ValueError("unsupported signature algorithm")
    raw = keys.get(sig.get("key_id", ""))
    if raw is None:
        raise ValueError(f"unknown signing key {sig.get('key_id')!r}")
    body = {k: v for k, v in manifest.items() if k != "signature"}
    try:
        Ed25519PublicKey.from_public_bytes(raw).verify(base64.b64decode(sig["value"]), canonical_json(body))
    except InvalidSignature as e:
        raise ValueError("bad manifest signature") from e


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Asset catalog, validation gates and diffs
# ---------------------------------------------------------------------------

# The second character may be a letter (QA0.0101, added in FY2026).
ICD = r"[A-Z][0-9A-Z][0-9A-Z](?:\.[0-9A-Z]{1,4})?"
ICD_RX = re.compile(rf"^{ICD}$")
ICD_REF_RX = re.compile(rf"^(?:{ICD}(?:\.?-)?(?:-{ICD})?|{ICD}-{ICD})$")
CODE5_RX = re.compile(r"^[0-9A-Z]{5}$")
HCPCS_RX = re.compile(r"^[A-Z][0-9]{4}$")
NUM_RX = re.compile(r"^-?\d+(?:\.\d+)?$")
GUIDE_ID_RX = re.compile(r"^(?:intro|App[A-Z]+|[IVX]+(?:\.[A-Za-z0-9]+)*)(?:\.[A-Za-z0-9]+)*$")
MCE_LIST_NAMES = {"age_newborn", "age_pediatric", "age_maternity", "age_adult", "manifestation_not_principal",
                  "unacceptable_principal", "unacceptable_principal_requires_secondary",
                  "unspecified_with_laterality_available"}

# set name, row bounds, key column (None = whole row), max share of baseline
# rows added+removed, max share changed (same key, other columns differ).
SPECS = [
    (re.compile(r"^icd10cm_(\d{4})\.tsv\.gz$"), "icd10cm", (85000, 115000), 0, 0.03, 0.05),
    (re.compile(r"^icd10cm_index_(\d{4})\.tsv\.gz$"), "icd10cm_index", (50000, 80000), None, 0.05, 0.0),
    (re.compile(r"^hcpcs\.tsv\.gz$"), "hcpcs", (5500, 10000), 0, 0.10, 0.20),
    # The annual A release revalues most RVUs, so changed rows are not limited.
    (re.compile(r"^pfs_rvu\.tsv\.gz$"), "pfs_rvu", (13000, 22000), 0, 0.10, 1.0),
    (re.compile(r"^mue_practitioner\.tsv\.gz$"), "mue_practitioner", (11000, 20000), 0, 0.15, 0.20),
    (re.compile(r"^ncci_addon\.tsv\.gz$"), "ncci_addon", (500, 1100), 0, 0.25, 0.25),
    (re.compile(r"^mce_v(\d+)\.tsv\.gz$"), "mce", (8, 8), 0, 0.0, 1.0),
    (re.compile(r"^icd10cm_excludes1_(\d{4})\.tsv\.gz$"), "icd10cm_excludes1", (4000, 7000), None, 0.15, 0.0),
    (re.compile(r"^icd_7th_(\d{4})\.tsv\.gz$"), "icd_7th", (380, 700), 0, 0.15, 0.15),
    (re.compile(r"^icd_notes_(\d{4})\.tsv\.gz$"), "icd_notes", (8500, 14500), None, 0.15, 0.0),
    (re.compile(r"^guidelines_fy(\d{4})\.tsv\.gz$"), "guidelines", (380, 650), None, 0.25, 0.0),
    (re.compile(r"^rule_catalog\.tsv\.gz$"), "rule_catalog", (60, 200), 0, 0.30, 1.0),
]
DENY = re.compile(r"ptp|cpt", re.I)


def spec_for(name: str):
    if DENY.search(name):
        return None
    for rx, set_name, bounds, key, max_addrem, max_changed in SPECS:
        m = rx.match(name)
        if m:
            return {"set": set_name, "edition": m.group(1) if m.groups() else None, "bounds": bounds,
                    "key": key, "max_addrem": max_addrem, "max_changed": max_changed}
    return None


def read_rows(path: Path) -> list[list[str]]:
    text = gzip.decompress(path.read_bytes()).decode("utf-8")
    return [line.split("\t") for line in text.split("\n") if line]


def _row_problems(set_name: str, rows: list[list[str]], expect_cols: int) -> list[str]:
    bad = []

    def chk(i, ok, what):
        if not ok and len(bad) < 10:
            bad.append(f"row {i + 1}: {what}: {rows[i]!r}"[:200])

    for i, r in enumerate(rows):
        if len(r) != expect_cols:
            chk(i, False, f"expected {expect_cols} columns")
            continue
        if set_name == "icd10cm":
            chk(i, ICD_RX.match(r[0]) and r[1] in ("0", "1") and r[2], "ICD code/billable/description")
        elif set_name == "icd10cm_index":
            chk(i, r[0] and ICD_RX.match(r[1]), "index path/ICD code")
        elif set_name == "hcpcs":
            chk(i, HCPCS_RX.match(r[0]) and r[1], "HCPCS code/short description")
        elif set_name == "pfs_rvu":
            chk(i, CODE5_RX.match(r[0]) and re.fullmatch(r"[A-Z]", r[1] or "") is not None
                and all(NUM_RX.match(r[j]) for j in (2, 3, 5))
                and re.fullmatch(r"[0-9A-Z]{3}", r[4] or "") is not None, "RVU row format")
        elif set_name == "mue_practitioner":
            chk(i, CODE5_RX.match(r[0]) and r[1].isdigit() and r[2] in ("1", "2", "3"), "MUE row format")
        elif set_name == "ncci_addon":
            chk(i, CODE5_RX.match(r[0]) and r[1] in ("1", "2", "3")
                and all(CODE5_RX.match(c) for c in r[2].split(",") if c), "add-on row format")
        elif set_name == "mce":
            chk(i, r[0] in MCE_LIST_NAMES and all(ICD_RX.match(c) for c in r[3].split(",") if c), "MCE list")
        elif set_name == "icd10cm_excludes1":
            chk(i, ICD_REF_RX.match(r[0]) and ICD_REF_RX.match(r[1]), "Excludes1 source/reference")
        elif set_name == "icd_7th":
            chk(i, ICD_RX.match(r[0].rstrip(".")) is not None or re.fullmatch(r"[A-Z][0-9][0-9A-Z]", r[0]) is not None,
                "7th character prefix")
            chk(i, re.fullmatch(r"[0-9A-Z]=[^|]+(\|[0-9A-Z]=[^|]+)*", r[1]) is not None, "7th character list")
        elif set_name == "icd_notes":
            chk(i, r[1] in ("E1", "E2", "CF", "UA", "CA", "N"), "note kind")
        elif set_name == "guidelines":
            chk(i, GUIDE_ID_RX.match(r[0]) and r[1] is not None, "guideline section id")
        elif set_name == "rule_catalog":
            chk(i, r[0] and r[2] in ("error", "warning", "info") and r[3], "rule id/severity/citation")
    return bad


EXPECT_COLS = {"icd10cm": 3, "icd10cm_index": 2, "hcpcs": 3, "pfs_rvu": 8, "mue_practitioner": 3, "ncci_addon": 3,
               "mce": 4, "icd10cm_excludes1": 2, "icd_7th": 2, "icd_notes": 4, "guidelines": 3, "rule_catalog": 7}
# Sets that carry CPT numbers: no free text may appear in any cell (CPT descriptors are AMA-copyrighted).
CPT_BEARING = {"pfs_rvu", "mue_practitioner", "ncci_addon"}


def diff_rows(old: list[list[str]], new: list[list[str]], key) -> dict:
    if key is None:
        a = {"\t".join(r) for r in old}
        b = {"\t".join(r) for r in new}
        return {"added": len(b - a), "removed": len(a - b), "changed": 0,
                "examples_added": sorted(b - a)[:5], "examples_removed": sorted(a - b)[:5]}
    a = {r[key]: r for r in old}
    b = {r[key]: r for r in new}
    added = sorted(set(b) - set(a))
    removed = sorted(set(a) - set(b))
    changed = sorted(k for k in set(a) & set(b) if a[k] != b[k])
    return {"added": len(added), "removed": len(removed), "changed": len(changed),
            "examples_added": added[:5], "examples_removed": removed[:5], "examples_changed": changed[:5]}


def validate_file(path: Path, baseline: Path | None, baseline_kind: str | None) -> dict:
    """Runs the gates for one asset. Returns a report with 'problems' (gate id -> message)."""
    name = path.name
    spec = spec_for(name)
    rep: dict = {"name": name, "problems": {}}
    if spec is None:
        rep["problems"][f"allowlist:{name}"] = "file is not an allowed public code-set asset"
        return rep
    rows = read_rows(path)
    rep.update(set=spec["set"], edition=spec["edition"], rows=len(rows))
    lo, hi = spec["bounds"]
    if not lo <= len(rows) <= hi:
        rep["problems"][f"rows:{name}"] = f"{len(rows)} rows, expected {lo}..{hi}"
    bad = _row_problems(spec["set"], rows, EXPECT_COLS[spec["set"]])
    if bad:
        rep["problems"][f"format:{name}"] = "; ".join(bad)
    if spec["set"] in CPT_BEARING:
        leak = [r for r in rows if any(re.search(r"[a-z]|\s", c) for c in r)]
        if leak:
            rep["problems"][f"cpt-text:{name}"] = f"{len(leak)} rows carry free text, e.g. {leak[0]!r}"[:200]
    keys = [r[spec["key"]] for r in rows] if spec["key"] is not None else None
    if keys is not None and len(set(keys)) != len(keys):
        rep["problems"][f"unique:{name}"] = f"{len(keys) - len(set(keys))} duplicate keys"
    if baseline is not None and baseline.exists():
        old = read_rows(baseline)
        d = diff_rows(old, rows, spec["key"])
        d["baseline"] = baseline_kind
        d["baseline_rows"] = len(old)
        rep["diff"] = d
        base_n = max(len(old), 1)
        # A new ICD edition is compared with the previous edition: allow the usual yearly change.
        scale = 2.0 if baseline_kind == "previous-edition" else 1.0
        if (d["added"] + d["removed"]) / base_n > spec["max_addrem"] * scale + 1e-9 and (d["added"] + d["removed"]) > 5:
            rep["problems"][f"change:{name}"] = (
                f"{d['added']} added + {d['removed']} removed of {len(old)} (limit {spec['max_addrem'] * scale:.0%})")
        if d["changed"] / base_n > spec["max_changed"] * scale + 1e-9 and d["changed"] > 5:
            rep["problems"][f"changed:{name}"] = f"{d['changed']} changed of {len(old)} (limit {spec['max_changed'] * scale:.0%})"
    else:
        rep["diff"] = {"baseline": None}
    return rep


def citation_problems(guidelines: Path, rule_catalog: Path) -> list[str]:
    """Every guideline section a rule cites must exist in the guideline text."""
    ids = {r[0] for r in read_rows(guidelines)}
    out = []
    for r in read_rows(rule_catalog):
        for ref in (x for x in r[6].split(",") if x):
            if ref not in ids:
                out.append(f"{r[0]} cites guideline {ref}, which is not in {guidelines.name}")
    return out
