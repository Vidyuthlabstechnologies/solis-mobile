#!/usr/bin/env python3
"""Build the SOLIS official code-set assets.

Downloads (or reuses already-downloaded) official US government code files and
writes compact gzip-compressed UTF-8 TSV assets to assets/codes/.

Usage:
    python tool/build_code_assets.py [--src DIR] [--out DIR] [--offline]

    --src      download/cache directory (default: %TEMP%/solis_codesets)
    --out      output directory (default: <repo>/assets/codes)
    --offline  never download; only read files already present in --src

Outputs (all UTF-8, tab separated, one record per line, no header):
    icd10cm_<FY>.tsv.gz      code_with_dot  billable(0|1)  long_description
    icd10cm_index_<FY>.tsv.gz index_path(Main|sub|subsub)  code_with_dot
    hcpcs.tsv.gz             code  short_description  long_description
    pfs_rvu.tsv.gz           code  status  nonfacility_total_rvu  facility_total_rvu  global_days
                             work_rvu  pctc_indicator  bilateral_surgery_indicator
    mue_practitioner.tsv.gz  code  max_units  adjudication_indicator(1|2|3)
    ptp_practitioner.tsv.gz  column1  list of column2+modifier_indicator, comma separated
                             (only built when the PTP edit files are present in --src/ptp,
                             because CMS serves them behind an AMA license click-through)
    icd10cm_excludes1_<FY>.tsv.gz  note_source(code, prefix or range)  excluded_ref
    icd_7th_<FY>.tsv.gz      prefix  allowed 7th characters as A=meaning|D=meaning|...
    mce_v44.tsv.gz           list_name  age_min  age_max  codes (comma separated)
    ncci_addon.tsv.gz        addon_code  aoc_type(1|2|3)  primary codes (comma separated)
    icd_notes_<FY>.tsv.gz    node  kind(E1|E2|CF|UA|CA|N)  note text  refs (comma separated)
                             (the Tabular-note assets exist for every edition in ICD_EDITIONS:
                             KNOWLEDGE_FY from knowledge/rules/, the others parsed straight from
                             the CMS Tabular XML; --tabular-only rebuilds the others)
    guidelines_fy2027.tsv.gz section_id  title  text (paragraphs joined by a literal \n)
    rule_catalog.tsv.gz      id  title  severity  short_citation  citations  rule  guideline_refs
                             (these come from knowledge/rules/, built by
                             tool/build_knowledge_base.py; --knowledge-only rebuilds just them)

CPT descriptors are AMA-copyrighted and are never written to any asset.
"""

from __future__ import annotations

import argparse
import csv
import datetime as _dt
import gzip
import io
import os
import re
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

# Official sources. Update these when CMS posts new releases.
SOURCES = {
    "icd_desc_2026": (
        "icd",
        "april-1-2026-code-descriptions-tabular-order.zip",
        "https://www.cms.gov/files/zip/april-1-2026-code-descriptions-tabular-order.zip",
    ),
    "icd_index_2026": (
        "icd",
        "april-1-2026-code-tables-tabular-index.zip",
        "https://www.cms.gov/files/zip/april-1-2026-code-tables-tabular-index.zip",
    ),
    "icd_desc_2027": (
        "icd",
        "2027-code-descriptions-tabular-order.zip",
        "https://www.cms.gov/files/zip/2027-code-descriptions-tabular-order.zip",
    ),
    "icd_index_2027": (
        "icd",
        "2027-code-tables-tabular-index.zip",
        "https://www.cms.gov/files/zip/2027-code-tables-tabular-index.zip",
    ),
    "hcpcs": (
        "hcpcs",
        "october-2026-alpha-numeric-hcpcs-file.zip",
        "https://www.cms.gov/files/zip/october-2026-alpha-numeric-hcpcs-file.zip",
    ),
    "rvu": (
        "rvu",
        "rvu26d-updated-08-26-2026.zip",
        "https://www.cms.gov/files/zip/rvu26d-updated-08-26-2026.zip",
    ),
    "mue": (
        "mue",
        "medicare-ncci-2026-q4-practitioner-services-mue-table.zip",
        "https://www.cms.gov/files/zip/medicare-ncci-2026-q4-practitioner-services-mue-table.zip",
    ),
}

# ICD-10-CM fiscal-year editions to build. FY N runs October 1 of N-1
# through September 30 of N.
ICD_EDITIONS = (2026, 2027)

# Date used to decide whether HCPCS codes and PTP edits are still active.
AS_OF = "20261001"

ALLOWED_HOSTS = ("www.cms.gov", "cms.gov", "www.cdc.gov", "ftp.cdc.gov", "www.nlm.nih.gov")


def fetch(src_dir: Path, key: str, offline: bool) -> Path:
    sub, name, url = SOURCES[key]
    target = src_dir / sub / name
    if target.exists() and target.stat().st_size > 0:
        return target
    if offline:
        sys.exit(f"missing {target} (offline mode)")
    host = url.split("/")[2]
    if host not in ALLOWED_HOSTS:
        sys.exit(f"refusing non-government host {host}")
    target.parent.mkdir(parents=True, exist_ok=True)
    print(f"downloading {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=300) as resp, open(target, "wb") as fh:
        fh.write(resp.read())
    return target


def write_tsv_gz(path: Path, rows) -> int:
    buf = io.StringIO()
    count = 0
    for row in rows:
        cells = [str(c).replace("\t", " ").replace("\n", " ").strip() for c in row]
        buf.write("\t".join(cells))
        buf.write("\n")
        count += 1
    data = buf.getvalue().encode("utf-8")
    # mtime=0 keeps the output byte-for-byte reproducible.
    with open(path, "wb") as fh:
        with gzip.GzipFile(fileobj=fh, mode="wb", compresslevel=9, mtime=0, filename="") as gz:
            gz.write(data)
    return count


def dotted(code: str) -> str:
    code = code.strip().upper().replace(".", "")
    return code if len(code) <= 3 else code[:3] + "." + code[3:]


def zip_member(zf: zipfile.ZipFile, pattern: str) -> str:
    rx = re.compile(pattern, re.IGNORECASE)
    for name in zf.namelist():
        if rx.search(name):
            return name
    sys.exit(f"no member matching {pattern} in {zf.filename}")


# ICD-10-CM ------------------------------------------------------------------

def build_icd(src: Path, out: Path, fy: int):
    zf = zipfile.ZipFile(src)
    text = zf.read(zip_member(zf, r"icd10cm_order_\d{4}\.txt$")).decode("latin-1")
    rows = []
    for line in text.splitlines():
        if len(line) < 16:
            continue
        # Fixed layout: order(5) sp code(7) sp billable(1) sp short(60) sp long
        code = line[6:13].strip()
        billable = line[14]
        long_desc = line[77:].strip() or line[16:76].strip()
        rows.append((dotted(code), billable, long_desc))
    n = write_tsv_gz(out / f"icd10cm_{fy}.tsv.gz", rows)
    print(f"icd10cm_{fy}: {n} rows ({sum(1 for r in rows if r[1] == '1')} billable)")
    return {r[0].replace(".", "") for r in rows}


def _title_text(el) -> str:
    """Title text without nonessential modifiers (nemod) or parentheses."""
    title = el.find("title")
    if title is None:
        return ""
    parts = [title.text or ""]
    for child in title:
        if child.tag != "nemod" and child.text:
            parts.append(child.text)
        if child.tail:
            parts.append(child.tail)
    txt = "".join(parts)
    txt = re.sub(r"\([^)]*\)", " ", txt)
    txt = txt.replace("|", " ")
    return re.sub(r"\s+", " ", txt).strip().strip(",")


def build_icd_index(src: Path, out: Path, known: set[str], fy: int):
    zf = zipfile.ZipFile(src)
    root = ET.fromstring(zf.read(zip_member(zf, r"icd10cm_index_\d{4}\.xml$")))
    rows = []
    seen = set()

    def walk(el, path):
        title = _title_text(el)
        if not title:
            return
        here = path + [title]
        code_el = el.find("code")
        if code_el is not None and code_el.text:
            raw = code_el.text.strip().upper().rstrip("-").rstrip(".")
            norm = raw.replace(".", "")
            if norm in known:
                key = ("|".join(here), norm)
                if key not in seen:
                    seen.add(key)
                    rows.append(("|".join(here), dotted(norm)))
        for child in el.findall("term"):
            walk(child, here)

    for letter in root.findall("letter"):
        for main in letter.findall("mainTerm"):
            walk(main, [])
    n = write_tsv_gz(out / f"icd10cm_index_{fy}.tsv.gz", rows)
    print(f"icd10cm_index_{fy}: {n} rows")


# HCPCS ----------------------------------------------------------------------

def build_hcpcs(src: Path, out: Path):
    zf = zipfile.ZipFile(src)
    text = zf.read(zip_member(zf, r"ANWEB.*\.txt$")).decode("latin-1")
    codes: dict[str, dict] = {}
    order: list[str] = []
    for line in text.splitlines():
        if len(line) < 12:
            continue
        line = line.ljust(320)
        code = line[0:5].strip()
        rec = line[10]
        if rec not in ("3", "4") or not code:
            continue  # 7/8 are modifier records
        long_part = line[11:91].strip()
        if rec == "3":
            term = line[284:292].strip()
            codes[code] = {
                "short": line[91:119].strip(),
                "long": long_part,
                "terminated": bool(term) and term < AS_OF,
            }
            order.append(code)
        elif code in codes:
            codes[code]["long"] = (codes[code]["long"] + " " + long_part).strip()
    rows = [
        (c, codes[c]["short"], codes[c]["long"])
        for c in order
        if not codes[c]["terminated"] and re.match(r"^[A-Z]\d{4}$", c)
    ]
    n = write_tsv_gz(out / "hcpcs.tsv.gz", rows)
    print(f"hcpcs: {n} active Level II codes")


# PFS RVU --------------------------------------------------------------------

def build_rvu(src: Path, out: Path):
    zf = zipfile.ZipFile(src)
    name = zip_member(zf, r"PPRRVU\d{4}.*nonQPP\.csv$")
    reader = csv.reader(io.TextIOWrapper(zf.open(name), encoding="latin-1"))
    header_found = False
    rows = []
    cfs = set()
    for r in reader:
        if not header_found:
            if r and r[0].strip() == "HCPCS":
                header_found = True
            continue
        if len(r) < 26 or not r[0].strip():
            continue
        code, mod = r[0].strip(), r[1].strip()
        if mod:
            continue
        # Columns: 3 status, 5 work, 11 non-fac total, 12 facility total, 13 PC/TC,
        # 14 global, 19 bilateral surgery, 25 CF.
        # Column 2 (description) is deliberately dropped: CPT descriptors are AMA-copyrighted.
        # 5 work RVU, 13 PC/TC indicator, 19 bilateral surgery indicator
        # (NCCI-EM-03 and NCCI-MUE-03 read them).
        rows.append((code, r[3].strip(), r[11].strip(), r[12].strip(), r[14].strip(),
                     r[5].strip(), r[13].strip(), r[19].strip()))
        cfs.add(r[25].strip())
    n = write_tsv_gz(out / "pfs_rvu.tsv.gz", rows)
    print(f"pfs_rvu: {n} rows (conversion factor column values: {sorted(cfs)})")
    qpp = zip_member(zf, r"PPRRVU\d{4}.*_QPP\.csv$")
    qcf = set()
    for r in csv.reader(io.TextIOWrapper(zf.open(qpp), encoding="latin-1")):
        if len(r) > 25 and re.match(r"^\d+\.\d{4}$", r[25].strip()):
            qcf.add(r[25].strip())
    print(f"pfs_rvu: QPP file conversion factor values: {sorted(qcf)}")


# MUE ------------------------------------------------------------------------

def build_mue(src: Path, out: Path):
    zf = zipfile.ZipFile(src)
    name = zip_member(zf, r"Practitioner.*\.csv$")
    rows = []
    for r in csv.reader(io.TextIOWrapper(zf.open(name), encoding="latin-1")):
        if len(r) < 3:
            continue
        code = r[0].strip()
        if not re.match(r"^[0-9A-Z]{4}[0-9A-Z]$", code):
            continue
        units = r[1].strip()
        mai = r[2].strip()[:1]
        if not units.isdigit() or mai not in ("1", "2", "3"):
            continue
        rows.append((code, units, mai))
    n = write_tsv_gz(out / "mue_practitioner.tsv.gz", rows)
    print(f"mue_practitioner: {n} rows")


# PTP (optional) -------------------------------------------------------------

PTP_LINE = re.compile(
    r"^([0-9A-Z]{5})\t([0-9A-Z]{5})\t[^\t]*\t(\d{8})\t(\d{8}|\*)\t([019])"
)


def build_ptp(src_dir: Path, out: Path) -> bool:
    """Builds PTP from practitioner PTP edit zips the user placed in src/ptp.

    CMS serves the complete PTP tables only after an AMA CPT license
    click-through, so this script never downloads them. Download the four
    practitioner files (ccipra ... f1..f4) yourself after accepting the license
    and drop them in <src>/ptp/.
    """
    folder = src_dir / "ptp"
    zips = sorted(set(folder.glob("*practitioner-ptp-edits*.zip")) | set(folder.glob("ccipra-*.zip")))
    texts = sorted(p for p in folder.glob("**/ccipra-*") if p.suffix.lower() == ".txt")
    if not zips and not texts:
        print("ptp: practitioner PTP edit files not present, skipped")
        return False

    def sources():
        seen = set()
        for f in zips:
            zf = zipfile.ZipFile(f)
            for name in zf.namelist():
                if name.lower().endswith(".txt") and Path(name).name.lower() not in seen:
                    seen.add(Path(name).name.lower())
                    yield Path(name).name, zf.read(name).decode("latin-1")
        for t in texts:
            if t.name.lower() not in seen:
                seen.add(t.name.lower())
                yield t.name, t.read_text(encoding="latin-1")

    groups: dict[str, list[str]] = {}
    total = 0
    parts = []
    for name, text in sources():
        parts.append(name)
        if True:
            for line in text.splitlines():
                m = PTP_LINE.match(line)
                if not m:
                    continue
                c1, c2, eff, dele, mod = m.groups()
                if eff > AS_OF or (dele != "*" and dele <= AS_OF):
                    continue  # keep only edits active on AS_OF
                groups.setdefault(c1, []).append(c2 + mod)
                total += 1
    rows = ((c1, ",".join(sorted(set(v)))) for c1, v in sorted(groups.items()))
    out.mkdir(parents=True, exist_ok=True)
    write_tsv_gz(out / "ptp_practitioner.tsv.gz", rows)
    print(f"ptp_practitioner: {total} active edits across {len(groups)} column-1 codes from {len(parts)} part(s): {', '.join(parts)}")
    print(f"ptp_practitioner written to {out}")
    return True


# Coding-edit assets from the knowledge base (knowledge/rules/) --------------
#
# These are built from files tool/build_knowledge_base.py already extracted
# from public CMS/CDC releases, so no download is needed:
#   icd10cm_excludes1_2027.tsv.gz  source(code, prefix or range)  excluded_ref
#   icd_7th_2027.tsv.gz            prefix  A=meaning|D=meaning|...
#   mce_v44.tsv.gz                 list  age_min  age_max  codes(comma separated)
#   ncci_addon.tsv.gz              addon_code  aoc_type(1|2|3)  primary codes(comma separated)

# ICD-10-CM edition the knowledge base (knowledge/rules/) is built for. Other
# editions in ICD_EDITIONS get their Tabular-note assets from build_prior_tabular.
KNOWLEDGE_FY = 2027

KNOWLEDGE_FILES = {
    "excludes1": "icd10cm_excludes1_2027.tsv",
    "seventh": "icd10cm_seventh_character_2027.json",
    "chapters": "icd10cm_chapters_2027.json",
    "mce": "mce_edits_v44.json",
    "addon": "ncci_addon_code_edits_v2026q4.tsv",
}

MCE_LISTS = (
    "age_newborn",
    "age_pediatric",
    "age_maternity",
    "age_adult",
    "manifestation_not_principal",
    "unacceptable_principal",
    "unspecified_with_laterality_available",
)


def _knowledge_rows(path: Path):
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        yield line.split("\t")


def build_knowledge(rules_dir: Path, out: Path) -> None:
    import json

    files = {k: rules_dir / v for k, v in KNOWLEDGE_FILES.items()}
    missing = [str(p) for p in files.values() if not p.exists()]
    if missing:
        print(f"knowledge assets skipped, missing: {', '.join(missing)}")
        return

    chapter_range = write_tabular_edition(rules_dir, out, KNOWLEDGE_FY)

    # MCE v44 lists.
    mce = json.loads(files["mce"].read_text(encoding="utf-8"))
    rows = []
    for name in MCE_LISTS:
        lst = mce["lists"][name]
        rows.append((name, lst.get("age_min", ""), lst.get("age_max", ""), ",".join(lst["codes"])))
        if name == "unacceptable_principal":
            rows.append((name + "_requires_secondary", "", "", ",".join(lst.get("requires_secondary", []))))
    n = write_tsv_gz(out / "mce_v44.tsv.gz", rows)
    print(f"mce_v44: {n} lists, {sum(len(r[3].split(',')) for r in rows if r[3])} codes")

    # NCCI add-on code edits (bare codes as CMS publishes them; no descriptors).
    groups: dict[str, dict] = {}
    for row in _knowledge_rows(files["addon"]):
        if len(row) < 3:
            continue
        addon, primary, typ = row[0].strip(), row[1].strip(), row[2].strip()
        if typ not in ("1", "2", "3"):
            continue
        g = groups.setdefault(addon, {"types": set(), "primaries": set()})
        g["types"].add(typ)
        if primary != "CCCCC":
            g["primaries"].add(primary)
    mixed = [a for a, g in groups.items() if len(g["types"]) > 1]
    rows = []
    for addon, g in sorted(groups.items()):
        # A code listed with more than one type is treated as type 3 (listed
        # primaries plus contractor-defined ones), the least strict reading.
        typ = next(iter(g["types"])) if len(g["types"]) == 1 else "3"
        rows.append((addon, typ, ",".join(sorted(g["primaries"]))))
    n = write_tsv_gz(out / "ncci_addon.tsv.gz", rows)
    print(f"ncci_addon: {n} add-on codes ({len(mixed)} listed with more than one type)")

    build_code_notes(rules_dir, out, chapter_range, KNOWLEDGE_FY)
    build_guidelines(rules_dir.parent / "guidelines", out)
    build_rule_catalog(rules_dir / "rule_catalog.json", out)


# Tabular instructional notes per node -----------------------------------------
#   icd_notes_2027.tsv.gz  node  kind  text  refs(comma separated)
# node is a code or category (with dot), a block range "A15-A19" or a chapter
# range "A00-B99". kind: E1 Excludes1, E2 Excludes2, CF code first, UA use
# additional code, CA code also, N note. Inclusion terms are not bundled.

NOTE_KINDS = (
    ("excludes1", "E1"),
    ("excludes2", "E2"),
    ("codeFirst", "CF"),
    ("useAdditionalCode", "UA"),
    ("codeAlso", "CA"),
    ("notes", "N"),
)


def build_code_notes(rules_dir: Path, out: Path, chapter_range: dict, fy: int = 2027) -> None:
    import json

    src = rules_dir / f"icd10cm_code_notes_{fy}.jsonl"
    if not src.exists():
        print(f"icd_notes skipped, missing {src}")
        return
    rows = []
    for line in src.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        d = json.loads(line)
        node = d["code"]
        if d["level"] == "chapter":
            node = d.get("range") or chapter_range.get(node, node)
        refs = d.get("refs") or {}
        for key, kind in NOTE_KINDS:
            texts = d.get(key) or []
            kind_refs = refs.get(key) or []
            for i, text in enumerate(texts):
                r = kind_refs[i] if i < len(kind_refs) else []
                rows.append((node, kind, text, ",".join(r)))
    n = write_tsv_gz(out / f"icd_notes_{fy}.tsv.gz", rows)
    print(f"icd_notes_{fy}: {n} note lines")


def write_tabular_edition(rules_dir: Path, out: Path, fy: int) -> dict:
    """Excludes1 and 7th character assets for ICD-10-CM edition [fy] from the
    Tabular extracts in [rules_dir]. Returns the chapter ranges (chapter-N to
    A00-B99) used for chapter-level notes."""
    import json

    # Excludes1. Chapter-level notes ("chapter-15") become the chapter's code range.
    chapters = json.loads((rules_dir / f"icd10cm_chapters_{fy}.json").read_text(encoding="utf-8"))
    chapter_range = {f"chapter-{c['chapter']}": c["range"] for c in chapters["chapters"]}
    seen = set()
    excl = []
    for row in _knowledge_rows(rules_dir / f"icd10cm_excludes1_{fy}.tsv"):
        if len(row) < 2:
            continue
        src, ref = row[0].strip(), row[1].strip()
        src = chapter_range.get(src, src)
        if (src, ref) in seen:
            continue
        seen.add((src, ref))
        excl.append((src, ref))
    n = write_tsv_gz(out / f"icd10cm_excludes1_{fy}.tsv.gz", excl)
    print(f"icd10cm_excludes1_{fy}: {n} notes")

    # Seventh characters.
    seventh = json.loads((rules_dir / f"icd10cm_seventh_character_{fy}.json").read_text(encoding="utf-8"))
    rows = []
    for prefix, spec in sorted(seventh["prefixes"].items()):
        chars = "|".join(f"{k}={v}" for k, v in spec["chars"].items())
        rows.append((prefix, chars))
    n = write_tsv_gz(out / f"icd_7th_{fy}.tsv.gz", rows)
    print(f"icd_7th_{fy}: {n} prefixes")
    return chapter_range


def build_prior_tabular(src: Path, out: Path, fy: int, offline: bool) -> None:
    """Tabular-note assets (Excludes1, 7th characters, instructional notes)
    for an ICD-10-CM edition other than the knowledge-base one, so a claim
    with a date of service in that fiscal year is checked against its own
    Tabular List. Extracted with the same parser as tool/build_knowledge_base.py
    from the CMS code-tables zip, into a temporary directory (the extracts are
    not kept in knowledge/)."""
    build_tabular_from_zips(fetch(src, f"icd_desc_{fy}", offline), fetch(src, f"icd_index_{fy}", offline), out, fy, work=src)


def build_tabular_from_zips(order_zip: Path, tables_zip: Path, out: Path, fy: int, work: Path | None = None) -> None:
    """The Tabular-note assets of edition [fy] from its CMS code-descriptions
    zip and code-tables zip (also used by tool/codeset_updater/update.py)."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import build_knowledge_base as kb

    order = kb.load_order(order_zip, f"Code Descriptions/icd10cm_order_{fy}.txt")
    with tempfile.TemporaryDirectory(dir=str(work) if work else None) as tmp:
        rules = Path(tmp)
        kb.build_tabular(tables_zip, f"Table and Index/icd10cm_tabular_{fy}.xml", order, rules, fy)
        chapter_range = write_tabular_edition(rules, out, fy)
        build_code_notes(rules, out, chapter_range, fy)


# ICD-10-CM Official Guidelines FY2027 text --------------------------------------
#   guidelines_fy2027.tsv.gz  section_id  title  text (paragraphs joined by a literal \n)

def build_guidelines(guide_dir: Path, out: Path) -> None:
    files = sorted(guide_dir.glob("*.md"))
    if not files:
        print(f"guidelines skipped, nothing in {guide_dir}")
        return
    head = re.compile(r"^#+\s*\[([^\]]+)\]\s*(.*)$")
    rows = []
    for f in files:
        state = {"sid": None, "title": "", "body": []}

        def flush():
            if state["sid"] is not None:
                paras = [re.sub(r"[ \t]+", " ", p).strip() for p in "\n".join(state["body"]).split("\n\n")]
                text = "\\n".join(p.replace("\n", " ") for p in paras if p)
                rows.append((state["sid"], state["title"], text))

        for raw in f.read_text(encoding="utf-8").splitlines():
            if raw.startswith("<!--"):
                continue
            m = head.match(raw)
            if m:
                flush()
                state = {"sid": m.group(1).strip(), "title": m.group(2).strip(), "body": []}
            else:
                state["body"].append(raw.strip())
        flush()
    n = write_tsv_gz(out / "guidelines_fy2027.tsv.gz", rows)
    print(f"guidelines_fy2027: {n} sections")


# Rule catalog for the app's "Why" explanations ----------------------------------
#   rule_catalog.tsv.gz  id  title  severity  short_citation  citations("; ")  rule  guideline_refs(comma)
# Knowledge-base rules come from knowledge/rules/rule_catalog.json. APP_RULES are
# claim-form data checks (not coding rules); their citations name the CMS-1500
# item or the CMS publication the check follows.

TABULAR_NOTE_NAMES = {
    "codeFirst": "Code first",
    "useAdditionalCode": "Use additional code",
    "codeAlso": "Code also",
    "excludes1": "Excludes1",
    "excludes2": "Excludes2",
    "sevenChrDef": "7th character",
    "notes": "Notes",
    "inclusionTerm": "Inclusion term",
    "includes": "Includes",
}

APP_RULES = [
    ("CLAIM-SIGNED-01", "The note is signed before the claim is sent", "error", "Medicare Program Integrity Manual, Chapter 3, Section 3.3.2.4",
     "Services must be documented in a signed record before they are billed; an unsigned note does not support the claim."),
    ("CLAIM-PATIENT-01", "Patient date of birth and sex are on the claim", "error", "CMS-1500 claim form, item 3",
     "Item 3 carries the patient birth date and sex; payers reject claims without them and use them for age and sex code edits."),
    ("CLAIM-PAYER-01", "Payer and member ID are on the claim", "error", "CMS-1500 claim form, item 1a",
     "Item 1a carries the insured's ID number exactly as shown on the insurance card."),
    ("CLAIM-NETWORK-01", "Payer is one you accept", "warning", "Provider payer contracts",
     "A payer outside your accepted list may deny the claim or pay it out of network."),
    ("CLAIM-NPI-01", "Rendering provider NPI is valid", "error", "CMS-1500 claim form, item 24J; 45 CFR 162.406",
     "Item 24J needs the rendering provider's 10-digit National Provider Identifier, whose last digit is a check digit."),
    ("CLAIM-TIN-01", "Federal tax ID is on the claim", "error", "CMS-1500 claim form, item 25",
     "Item 25 needs the billing provider's federal tax ID (EIN or SSN)."),
    ("CLAIM-DX-01", "At least one and at most 12 diagnoses", "error", "CMS-1500 claim form, item 21",
     "Item 21 holds up to 12 ICD-10-CM codes (A to L); every claim needs at least one."),
    ("CLAIM-SERVICE-01", "At least one service line with a charge", "error", "CMS-1500 claim form, items 24D and 24F",
     "Item 24D carries the CPT or HCPCS code and item 24F its charge."),
    ("CLAIM-POINTER-01", "Every service points to a diagnosis that supports it", "error", "CMS-1500 claim form, item 24E; Social Security Act 1862(a)(1)(A)",
     "Item 24E links each service to the diagnoses that make it reasonable and necessary; a service without a supporting diagnosis is denied."),
    ("CLAIM-PROCAGE-01", "Age-specific service codes match the patient's age", "error", "CPT code age bands (preventive medicine and newborn care codes)",
     "Preventive visit, newborn care and immunization administration codes are defined for specific age ranges; a code for another age range is denied."),
    ("CLAIM-PROCEDURE-01", "Procedure code is on the fee schedule or HCPCS file", "warning", "CMS Physician Fee Schedule RVU file 2026; HCPCS Level II file October 2026",
     "Codes that are on neither file are invalid or deleted and will be rejected."),
    ("CLAIM-COVERAGE-01", "Medicare non-covered services", "warning", "CMS Physician Fee Schedule status indicator N; Medicare Claims Processing Manual, Chapter 30",
     "PFS status N services are not covered by Medicare; an Advance Beneficiary Notice lets you bill the patient."),
    ("CLAIM-POS-01", "Place of service matches the E/M family", "error", "CMS Place of Service code set",
     "The place of service code on the claim must match the setting the E/M code describes (office, hospital, emergency department, nursing facility, home)."),
    ("CLAIM-NEWPT-01", "New patient codes only for new patients", "warning", "Medicare Claims Processing Manual, Chapter 12, Section 30.6.7",
     "A new patient has not received professional services from the physician or a same-specialty physician in the same group within the past three years."),
    ("CLAIM-EM-01", "One E/M per provider per day", "warning", "Medicare Claims Processing Manual, Chapter 12, Section 30.6.7",
     "Medicare normally pays one E/M visit per day for a physician or physicians of the same specialty in the same group."),
    ("CLAIM-TELEHEALTH-01", "Telehealth services carry the payer's telehealth modifier", "warning", "Medicare Claims Processing Manual, Chapter 12, Section 190",
     "Telehealth claims use the telehealth place of service and, for many payers, modifier 95."),
    ("CLAIM-AMBULANCE-01", "Ambulance services use ambulance codes and places of service", "error", "Medicare Claims Processing Manual, Chapter 15",
     "Ground ambulance transport is billed with HCPCS A0425 to A0436 and place of service 41 or 42; mileage A0425 is billed per loaded mile."),
    ("CLAIM-UNCERTAIN-01", "Uncertain diagnoses wait for confirmation", "info", "ICD-10-CM Guidelines IV.H",
     "Outpatient diagnoses documented as probable, suspected or rule out are not coded; code the symptoms until the diagnosis is confirmed."),
    ("CLAIM-PROVIDER-01", "The claim carries the clinician's own identity", "error", "CMS-1500 claim form, items 24J, 25 and 33; 45 CFR 162.410",
     "A claim must carry the NPI and tax ID of the provider who rendered and bills the service; the demo provider's identifiers are fictional."),
    ("CLAIM-PROVIDER-02", "Billing provider name, taxonomy and address are complete", "error", "CMS-1500 claim form, items 32 and 33; 837P loop 2010AA",
     "Items 32 and 33 and loop 2010AA need the billing provider name, taxonomy code and a street address with city, state and ZIP."),
    ("CLAIM-SAMPLE-01", "Only real patients are billed", "error", "False Claims Act, 31 U.S.C. 3729",
     "Demo patients are fictional; a claim for a person who was not seen must never be sent."),
    ("CLAIM-ELIG-01", "Coverage is active on the date of service", "warning", "ASC X12 270/271 eligibility (005010X279A1)",
     "A real-time eligibility check confirms the plan is active and shows the copay to collect; an inactive plan is denied."),
    ("CLAIM-AMBULANCE-02", "Ambulance claims carry the transport details", "error", "837P 005010X222A1 loop 2300 CR1, loops 2310E and 2310F",
     "Ambulance claims report the transport reason and loaded miles (CR1) and the pick-up and drop-off locations (2310E, 2310F)."),
    ("CLAIM-AMBULANCE-03", "Ambulance lines carry origin and destination modifiers", "error", "Medicare Claims Processing Manual, Chapter 15, Section 30.A",
     "Each ambulance service and mileage line carries a two-letter modifier: the origin code then the destination code (for example RH)."),
    # Medicare front-end (CCEM) edits, CMS CR 14429 (transmittal R13967OTN, October 2026). docs/CMS_EDI_OCT2026.md.
    ("CMS-EDI-X222.351.2400.SV101-7.020", "Unlisted and not-otherwise-classified services carry a description", "error",
     "CMS CR 14429 (R13977OTN)",
     "Medicare 837P edit X222.351.2400.SV101-7.020 (revised October 5, 2026): when the procedure code is on the CMS table of codes "
     "that require a description (unlisted CPT codes, NOC and unclassified HCPCS codes), loop 2400 SV101-7 must describe the service, "
     "1 to 80 characters, or the claim is rejected on the 277CA (CSCC A8, CSC 306)."),
    ("CMS-EDI-X222.121.2010BA.NM109.020", "Medicare member ID is an MBI", "error",
     "CMS CR 14429 (R13977OTN)",
     "Medicare 837P edit X222.121.2010BA.NM109.020: the subscriber ID in loop 2010BA NM109 must be a Medicare Beneficiary Identifier "
     "(11 characters: a digit 1-9, letters without S, L, O, I, B, Z, and digits in fixed positions), or the claim is rejected (CSCC A7, CSC 164)."),
]


def short_citation(src: dict) -> str:
    t, ref = src["type"], src["ref"]
    if t == "guideline":
        return f"ICD-10-CM Guidelines {ref}"
    if t == "mce":
        return f"MCE v44 edit {ref}"
    if t == "tabular_note":
        return f'ICD-10-CM Tabular, "{TABULAR_NOTE_NAMES.get(ref, ref)}" notes'
    if t == "ncci_manual":
        ch, sec = str(ref).split(".", 1)
        return f"NCCI Policy Manual 2026, Ch. {ch}, Sec. {sec}"
    return src.get("citation", str(ref))


def build_rule_catalog(src: Path, out: Path) -> None:
    import json

    if not src.exists():
        print(f"rule_catalog skipped, missing {src}")
        return
    cat = json.loads(src.read_text(encoding="utf-8"))
    rows = []
    for r in cat["rules"]:
        cites = [short_citation(s) for s in r["sources"]]
        guide = [s["ref"] for s in r["sources"] if s["type"] == "guideline"]
        rows.append((r["id"], r["title"], r["severity"], cites[0], "; ".join(cites), r["rule"], ",".join(guide)))
    for rid, title, sev, cite, rule in APP_RULES:
        guide = re.findall(r"Guidelines ([IVX]+(?:\.[A-Za-z0-9]+)*)", cite)
        rows.append((rid, title, sev, cite, cite, rule, ",".join(guide)))
    n = write_tsv_gz(out / "rule_catalog.tsv.gz", rows)
    print(f"rule_catalog: {n} rules")
    write_rule_citations_dart(rows)


def write_rule_citations_dart(rows) -> None:
    """Writes the rule id to short citation map the claim checks attach to
    every ClaimIssue, so explanations work even before the assets load."""
    repo = Path(__file__).resolve().parent.parent
    target = repo / "lib" / "services" / "coding" / "rule_citations.g.dart"
    lines = [
        "// GENERATED by tool/build_code_assets.py --knowledge-only from",
        "// knowledge/rules/rule_catalog.json and APP_RULES. Do not edit by hand.",
        "",
        "/// Short official citation for each rule id (the first source of the rule).",
        "const Map<String, String> ruleCitations = {",
    ]
    for row in rows:
        rid, cite = row[0], row[3]
        esc = cite.replace("\\", "\\\\").replace("'", "\\'").replace("$", "\\$")
        lines.append(f"  '{rid}': '{esc}',")
    lines.append("};")
    target.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {target.relative_to(repo)}")


def main() -> None:
    repo = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.join(tempfile.gettempdir(), "solis_codesets"))
    ap.add_argument("--out", default=str(repo / "assets" / "codes"))
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--ptp-only", action="store_true", help="rebuild only the PTP table")
    ap.add_argument(
        "--knowledge-only",
        action="store_true",
        help="rebuild only the coding-edit assets from knowledge/rules (no download)",
    )
    ap.add_argument("--pfs-only", action="store_true", help="rebuild only pfs_rvu.tsv.gz")
    ap.add_argument(
        "--tabular-only",
        action="store_true",
        help="rebuild only the Tabular-note assets of the editions other than KNOWLEDGE_FY",
    )
    ap.add_argument(
        "--ship-ptp",
        action="store_true",
        help="write PTP into the app assets. Only with an AMA CPT distribution license; "
        "by default it goes to local_data/ (internal use under the CMS click-through).",
    )
    args = ap.parse_args()
    ptp_out = Path(args.out) if args.ship_ptp else repo / "local_data"
    if args.ptp_only:
        build_ptp(Path(args.src), ptp_out)
        return
    src = Path(args.src)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if args.pfs_only:
        build_rvu(fetch(src, "rvu", args.offline), out)
        return
    if args.knowledge_only:
        build_knowledge(repo / "knowledge" / "rules", out)
        return
    if args.tabular_only:
        for fy in ICD_EDITIONS:
            if fy != KNOWLEDGE_FY:
                build_prior_tabular(src, out, fy, args.offline)
        return

    for fy in ICD_EDITIONS:
        known = build_icd(fetch(src, f"icd_desc_{fy}", args.offline), out, fy)
        build_icd_index(fetch(src, f"icd_index_{fy}", args.offline), out, known, fy)
    # Unversioned names from earlier builds are superseded by the per-edition files.
    for stale in ("icd10cm.tsv.gz", "icd10cm_index.tsv.gz"):
        (out / stale).unlink(missing_ok=True)
    build_hcpcs(fetch(src, "hcpcs", args.offline), out)
    build_rvu(fetch(src, "rvu", args.offline), out)
    build_mue(fetch(src, "mue", args.offline), out)
    build_ptp(src, ptp_out)
    build_knowledge(repo / "knowledge" / "rules", out)
    for fy in ICD_EDITIONS:
        if fy != KNOWLEDGE_FY:
            build_prior_tabular(src, out, fy, args.offline)

    total = 0
    print("\nasset sizes:")
    for p in sorted(out.glob("*.tsv.gz")):
        size = p.stat().st_size
        total += size
        print(f"  {p.name:28s} {size / 1024 / 1024:7.2f} MB")
    print(f"  {'total':28s} {total / 1024 / 1024:7.2f} MB")
    print(f"built {_dt.date.today().isoformat()}")


if __name__ == "__main__":
    main()
