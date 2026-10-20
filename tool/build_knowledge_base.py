#!/usr/bin/env python3
"""Builds the medical coding knowledge base in knowledge/ from public-domain
US government source files (CMS / NCHS).

Outputs (all under knowledge/):
  guidelines/*.md, guidelines/index.json   ICD-10-CM Official Guidelines, one file per section
  rules/icd10cm_code_notes_<FY>.jsonl      Tabular List instructional notes per code
  rules/icd10cm_chapters_<FY>.json         chapters, blocks (sections) and chapter-level notes
  rules/icd10cm_excludes1_<FY>.tsv         flattened Excludes1 pairs (code, excluded ref)
  rules/icd10cm_seventh_character_<FY>.json  7th character definitions by code prefix
  rules/mce_edits_v<NN>.json               Medicare Code Editor code lists (age, manifestation, ...)
  rules/ncci_policy_manual_sections_<YYYY>.json  NCCI manual chapter/section index (titles, pages)
  rules/rule_catalog.json                  coding rules with citations and app implementation status
  build_report.json                        counts, word-count check, citation check

Only the Python standard library and PyMuPDF (`pip install pymupdf`) are used.

Usage (from the repository root, or anywhere):
  python -P tool/build_knowledge_base.py              # download missing sources, then build
  python -P tool/build_knowledge_base.py --offline    # use existing downloads only
  python -P tool/build_knowledge_base.py --downloads D:/cache/solis_codesets

Downloads are kept outside the repository (default %TEMP%/solis_codesets, the
same folder tool/build_code_assets.py uses). To build a new edition (FY2028),
update EDITION and SOURCES below, rerun, and review build_report.json: every
rule citation is re-validated against the new guideline headings.

Source rule: never point this script at the AAPC ICD-10-CM book or the AMA
CPT book. CPT descriptors and AMA guideline text must not enter knowledge/.
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import random
import re
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

try:
    import fitz  # PyMuPDF
except ImportError:  # pragma: no cover
    sys.exit('PyMuPDF is required: pip install pymupdf')

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'knowledge'
DEFAULT_DOWNLOADS = Path(os.environ.get('TEMP') or tempfile.gettempdir()) / 'solis_codesets'

# ---------------------------------------------------------------------------
# Edition configuration. Update these for a new fiscal year.
# ---------------------------------------------------------------------------

EDITION = {
    'icd_fy': 2027,                  # ICD-10-CM fiscal year (Oct 1 2026 - Sep 30 2027)
    'mce_version': 44,               # MS-DRG / MCE version that matches the FY
    'ncci_year': 2026,               # NCCI Policy Manual edition (calendar year)
}

SOURCES = {
    'guidelines': {
        'path': 'kb/fy-2027-icd-10-cm-coding-guidelines.pdf',
        'url': 'https://www.cms.gov/files/document/fy-2027-icd-10-cm-coding-guidelines.pdf',
        'title': 'ICD-10-CM Official Guidelines for Coding and Reporting FY 2027 (October 1, 2026 - September 30, 2027)',
        'publisher': 'CMS and NCHS',
    },
    'tabular': {
        'path': 'icd/2027-code-tables-tabular-index.zip',
        'url': 'https://www.cms.gov/files/zip/2027-code-tables-tabular-index.zip',
        'member': 'Table and Index/icd10cm_tabular_2027.xml',
        'title': '2027 ICD-10-CM Code Tables, Tabular and Index (XML)',
        'publisher': 'CMS / NCHS',
    },
    'order': {
        'path': 'icd/2027-code-descriptions-tabular-order.zip',
        'url': 'https://www.cms.gov/files/zip/2027-code-descriptions-tabular-order.zip',
        'member': 'Code Descriptions/icd10cm_order_2027.txt',
        'title': '2027 ICD-10-CM Code Descriptions in Tabular Order',
        'publisher': 'CMS / NCHS',
    },
    'addendum': {
        'path': 'kb/2027-icd-10-addendum.zip',
        'url': 'https://www.cms.gov/files/zip/2027-icd-10-addendum.zip',
        'title': '2027 ICD-10-CM Addendum (tabular, index, drug, neoplasm changes; PDF)',
        'publisher': 'CMS / NCHS',
        'optional': True,
    },
    'mce': {
        'path': 'kb/fy2027-fr-definition-mce-v44.zip',
        'url': 'https://www.cms.gov/files/zip/fy2027-fr-definition-mce-v44.zip',
        'member_suffix': '.txt',
        'title': 'Definitions of Medicare Code Edits, ICD-10 MCE v44.0 (October 2026), FY2027 final rule',
        'publisher': 'CMS',
    },
    'aoc': {
        'path': 'kb/add-code-edits-medicare-effective-10012026.zip',
        'url': 'https://www.cms.gov/files/zip/add-code-edits-medicare-effective-10012026.zip',
        'title': 'NCCI Add-On Code Edits for Medicare, effective October 1, 2026 (posted September 1, 2026)',
        'publisher': 'CMS',
        'optional': True,
    },
    'ncci_manual': {
        'path': 'kb/2026-ncci-medicare-policy-manual-all-chapters.pdf',
        'url': 'https://www.cms.gov/files/document/2026-ncci-medicare-policy-manual-all-chapters.pdf',
        'title': 'Medicare NCCI Policy Manual 2026, all chapters (effective January 1, 2026, posted December 24, 2025)',
        'publisher': 'CMS',
    },
}

NCCI_CHAPTER_TITLES = {
    'Intro': 'Introduction',
    'I': 'General Correct Coding Policies',
    'II': 'Anesthesia Services (CPT 00000-01999)',
    'III': 'Surgery: Integumentary System (CPT 10000-19999)',
    'IV': 'Surgery: Musculoskeletal System (CPT 20000-29999)',
    'V': 'Surgery: Respiratory, Cardiovascular, Hemic and Lymphatic Systems (CPT 30000-39999)',
    'VI': 'Surgery: Digestive System (CPT 40000-49999)',
    'VII': 'Surgery: Urinary, Male Genital, Female Genital, Maternity Care and Delivery Systems (CPT 50000-59999)',
    'VIII': 'Surgery: Endocrine, Nervous, Eye and Ocular Adnexa, and Auditory Systems (CPT 60000-69999)',
    'IX': 'Radiology Services (CPT 70000-79999)',
    'X': 'Pathology/Laboratory Services (CPT 80000-89999)',
    'XI': 'Medicine, Evaluation and Management Services (CPT 90000-99999)',
    'XII': 'Supplemental Services (HCPCS Level II A0000-V9999)',
    'XIII': 'Category III Codes (CPT 0001T-0999T)',
}

ROMAN = ['', 'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', 'XI', 'XII', 'XIII']


# ---------------------------------------------------------------------------
# Downloads
# ---------------------------------------------------------------------------

def ensure_sources(dl: Path, offline: bool) -> dict:
    paths = {}
    for key, src in SOURCES.items():
        p = dl / src['path']
        if not p.exists() and not offline:
            p.parent.mkdir(parents=True, exist_ok=True)
            print(f'downloading {src["url"]}')
            req = urllib.request.Request(src['url'], headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=600) as r:
                ctype = r.headers.get('Content-Type', '')
                data = r.read()
            if 'html' in ctype or data[:5] == b'<!DOC' or b'/license/ama' in data[:4000]:
                raise SystemExit(f'{src["url"]} returned HTML (license page?); refusing to use it')
            p.write_bytes(data)
        if not p.exists():
            if src.get('optional'):
                print(f'optional source missing: {p}')
                continue
            raise SystemExit(f'missing source {p} (run without --offline to download)')
        paths[key] = p
    return paths


# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

STOPWORDS = set('''a an and are as at be by for from has have in into is it its of on or that the this to with
without when which who will not no may can should must other than any all each code codes coding guidelines
section see also use used using only one two more such their there these those been being per under within
encounter encounters patient patients diagnosis diagnoses condition conditions'''.split())

CODE_TOKEN = r'[A-Z]\d[0-9A-Z](?:\.[0-9A-Z]{1,4})?'


def norm_ws(s: str) -> str:
    return re.sub(r'\s+', ' ', s).strip()


def norm_cmp(s: str) -> str:
    """Normalization used to compare heading text with PDF text."""
    s = s.replace('\u2019', "'").replace('\u2018', "'").replace('\u201c', '"').replace('\u201d', '"')
    s = s.replace('\u2013', '-').replace('\u2014', '-').replace('\ufffd', '"')
    return re.sub(r'[^0-9a-z]', '', s.lower())


def alnum(s: str) -> str:
    return re.sub(r'[^0-9A-Za-z]', '', s)


def dotted(code: str) -> str:
    code = code.strip().upper().replace('.', '')
    return code if len(code) <= 3 else f'{code[:3]}.{code[3:]}'


def write_json(path: Path, obj, indent=1):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=indent, ensure_ascii=False) + '\n', encoding='utf-8', newline='\n')


# ---------------------------------------------------------------------------
# 1. ICD-10-CM Official Guidelines -> Markdown
# ---------------------------------------------------------------------------

HEADER_RES = [
    re.compile(r'^ICD-10-CM Official Guidelines for Coding and Reporting\s*$'),
    re.compile(r'^FY \d{4}\s*$'),
    re.compile(r'^Page \d+ of \d+\s*$'),
]


def page_lines(page, pno: int, strip_header: bool):
    """Visual lines of a page: PyMuPDF lines that share a baseline are merged
    (list markers and two-column code lists come out as separate lines)."""
    raw = []
    for blk in page.get_text('dict')['blocks']:
        if blk.get('type') != 0:
            continue
        for ln in blk['lines']:
            spans = [s for s in ln['spans']]
            text = ''.join(s['text'] for s in spans)
            x0, y0, x1, y1 = ln['bbox']
            if not text.strip():
                raw.append({'page': pno, 'y': y0, 'x0': x0, 'x1': x1, 'text': '', 'blank': True, 'size': 0})
                continue
            sizes = [s['size'] for s in spans if s['text'].strip()]
            raw.append({'page': pno, 'y': y0, 'x0': x0, 'x1': x1, 'text': text, 'blank': False,
                        'size': max(sizes) if sizes else 11})
    raw.sort(key=lambda r: r['y'])
    clusters = []
    for r in raw:
        if clusters and abs(r['y'] - clusters[-1][0]['y']) < 3:
            clusters[-1].append(r)
        else:
            clusters.append([r])
    out = []
    for cl in clusters:
        parts = sorted([r for r in cl if not r['blank']], key=lambda r: r['x0'])
        if not parts:
            out.append({'page': pno, 'y': cl[0]['y'], 'x0': cl[0]['x0'], 'x1': cl[0]['x0'], 'text': '', 'blank': True})
            continue
        line = {'page': pno, 'y': min(p['y'] for p in parts), 'x0': parts[0]['x0'], 'x1': max(p['x1'] for p in parts),
                'text': ' '.join(p['text'].strip() for p in parts), 'blank': False,
                'size': max(p['size'] for p in parts),
                'x0b': parts[1]['x0'] if len(parts) > 1 else parts[0]['x0'], 'segments': len(parts)}
        out.append(line)
    if strip_header:
        kept = []
        for ln in out:
            if not ln['blank'] and (ln['y'] < 90 or ln['y'] > 700) and any(h.match(ln['text'].strip()) for h in HEADER_RES):
                ln['header'] = True
            kept.append(ln)
        out = kept
    return out


MARKER_RES = [
    (1, re.compile(r'^Section\s+([IVX]+)\.')),
    (1, re.compile(r'^(Appendix)\s+I\b')),
    (2, re.compile(r'^([A-Z])\.\s')),
    (3, re.compile(r'^(\d+)\.\s')),
    (4, re.compile(r'^([a-z])\.\s')),
    (5, re.compile(r'^(\d+)\)\s')),
    (6, re.compile(r'^\(([a-z]+)\)\s')),
]
ROMAN_SMALL = {'i', 'ii', 'iii', 'iv', 'v', 'vi', 'vii', 'viii', 'ix', 'x'}


def classify_heading(title: str, toc_level: int):
    t = norm_ws(title)
    for level, rx in MARKER_RES:
        m = rx.match(t + ' ')
        if m:
            tok = m.group(1)
            if level == 1 and tok == 'Appendix':
                return 1, 'AppI'
            if level == 6 and toc_level >= 7 and tok in ROMAN_SMALL:
                return 7, tok
            return level, tok
    return None, None


LIST_START = re.compile(r'^(\d+\.|[a-z]\.|[A-Z]\.|\d+\)|\((?:[a-z]|[ivx]{1,5})\)|\u2022|\uf0b7|-\s|Except:|Note:)')
CODE_ROW = re.compile(r'^(' + CODE_TOKEN + r'-?|[A-Z]\d{2}-[A-Z]\d{2})\s+\S')


def build_guidelines(pdf_path: Path, out_dir: Path) -> dict:
    doc = fitz.open(pdf_path)
    toc = doc.get_toc(simple=False)
    first_body_page = next(t[2] for t in toc if t[1].startswith('Section I.')) - 1  # 0-based

    # Lines of the document: page 1 (introduction) and the body; the table of
    # contents pages are skipped.
    lines = []
    toc_page_words = 0
    for pno in range(doc.page_count):
        if 0 < pno < first_body_page:
            toc_page_words += len(doc[pno].get_text().split())
            continue
        lines.extend(page_lines(doc[pno], pno, strip_header=pno > 0))

    header_words = sum(len(l['text'].split()) for l in lines if l.get('header'))
    lines = [l for l in lines if not l.get('header')]

    # Vocabulary for de-hyphenation decisions.
    alltext = ' '.join(l['text'] for l in lines)
    vocab = collections.Counter(w.lower() for w in re.findall(r"[A-Za-z][A-Za-z'-]*[A-Za-z]", alltext))

    # Right margin per page (Appendix I is set narrower than the body).
    page_x1 = collections.defaultdict(list)
    for l in lines:
        if not l['blank']:
            page_x1[l['page']].append(l['x1'])
    margins = {p: sorted(v)[int(len(v) * 0.9)] for p, v in page_x1.items()}

    # Place bookmarks into the line stream.
    headings = []  # (line_index, toc_entry)
    ids_stack = {}
    entries = []
    for t in toc:
        level_toc, title, pg, dest = t[0], t[1], t[2], t[3]
        title = norm_ws(title.replace('\ufffd', '"'))
        if pg - 1 == 0 and 'Official Guidelines' in title:
            sem, tok = 0, 'intro'
        else:
            sem, tok = classify_heading(title, level_toc)
        if sem is None:
            # unmarked heading (Appendix I title "Present on Admission ...")
            parent = ids_stack.get(1, 'AppI')
            sem = 2
            hid = parent
        elif sem == 0:
            hid = 'intro'
        else:
            if sem == 1:
                ids_stack = {1: tok}
            else:
                for k in list(ids_stack):
                    if k >= sem:
                        del ids_stack[k]
                ids_stack[sem] = tok
            hid = '.'.join(ids_stack[k] for k in sorted(ids_stack))
        y = dest.get('to').y if dest.get('to') is not None else 0
        entries.append({'id': hid, 'level': sem, 'title': title, 'page': pg, 'y': y, 'toc_level': level_toc})

    # Map each entry to a line index.
    def find_line(page0, y):
        best = None
        for i, l in enumerate(lines):
            if l['page'] == page0 and not l['blank'] and l['y'] >= y - 4:
                return i
            if l['page'] > page0:
                return i if best is None else best
        return len(lines) - 1

    consumed = set()
    mismatches = []
    for e in entries:
        i = find_line(e['page'] - 1, e['y'])
        # consume heading lines that spell the bookmark title
        target = norm_cmp(e['title'])
        got = ''
        j = i
        used = []
        while j < len(lines) and len(got) < len(target):
            if lines[j]['blank'] or j in consumed:
                j += 1
                continue
            cand = got + norm_cmp(lines[j]['text'])
            if target.startswith(cand) or cand.startswith(target):
                got = cand
                used.append(j)
                j += 1
            else:
                break
        if used and got.startswith(target) and len(got) <= len(target) + 2:
            e['heading_text'] = norm_ws(' '.join(lines[k]['text'] for k in used))
            consumed.update(used)
            e['line'] = used[0]
        else:
            e['heading_text'] = e['title']
            e['line'] = i
            mismatches.append({'id': e['id'], 'title': e['title'], 'page': e['page']})

    entries.sort(key=lambda e: (e['line'], e['level']))

    # Reflow the lines into paragraphs.
    def join_lines(a: str, b: str) -> str:
        a = a.rstrip()
        b = b.lstrip()
        if a.endswith('-') and len(a) > 1 and a[-2].isalpha():
            left = re.search(r"([A-Za-z]+)-$", a)
            right = re.match(r"([A-Za-z]+)", b)
            if left and right and b[0].islower():
                hy = f'{left.group(1)}-{right.group(1)}'.lower()
                solid = f'{left.group(1)}{right.group(1)}'.lower()
                if vocab.get(solid, 0) > 0 and vocab.get(hy, 0) <= 1:
                    return a[:-1] + b
            return a + b  # keep the hyphen (compound words, "ICD-10-CM")
        if a.endswith('/'):
            return a + b
        return a + ' ' + b

    def is_break(prev, cur) -> bool:
        # Multi-segment lines are list items or code-list rows (marker or code
        # in its own column). A wrapped line that merely starts with a code
        # is one segment and continues the paragraph.
        if cur.get('segments', 1) > 1 and (LIST_START.match(cur['text']) or CODE_ROW.match(cur['text'])):
            return True
        if re.match(r'^(Except:|Note:|•|)', cur['text']):
            return True
        if prev.get('segments', 1) > 1 and CODE_ROW.match(prev['text']) and abs(cur['x0'] - prev['x0b']) < 4:
            return False  # continuation of a code list row
        ptxt = prev['text'].rstrip()
        if ptxt.count('(') > ptxt.count(')'):
            return False  # open parenthesis continues on the next line
        if not re.search(r'[.:;?!)"”]$', ptxt) and re.match(r'^[a-z0-9(]', cur['text']):
            return False  # sentence continues
        first_word = cur['text'].split()[0] if cur['text'].split() else ''
        width_needed = (len(first_word) + 1) * cur.get('size', 11) * 0.5
        if prev['x1'] + width_needed < margins.get(prev['page'], 560) - 4:
            return True  # previous line ended early: paragraph or list break
        return False

    blocks = []  # (entry_index or None, paragraph text)
    starts = {e['line']: [] for e in entries}
    for k, e in enumerate(entries):
        starts[e['line']].append(k)

    para = None
    para_row = False
    prev = None
    for i, l in enumerate(lines):
        if i in starts:
            if para:
                blocks.append(('p', (para, para_row)))
            para, prev = None, None
            for k in starts[i]:
                blocks.append(('h', k))
        if i in consumed:
            continue
        if l['blank']:
            # Blank lines at a page bottom/top are layout, not paragraph
            # breaks: a paragraph can continue on the next page.
            nxt = next((m for m in lines[i + 1:] if not m['blank']), None)
            if prev is not None and nxt is not None and nxt['page'] > prev['page']:
                continue
            if para:
                blocks.append(('p', (para, para_row)))
            para, prev = None, None
            continue
        if para is None or (prev is not None and is_break(prev, l)):
            if para:
                blocks.append(('p', (para, para_row)))
            para = l['text'].strip()
            para_row = l.get('segments', 1) > 1 and bool(CODE_ROW.match(para))
        else:
            para = join_lines(para, l['text'])
        prev = l
    if para:
        blocks.append(('p', (para, para_row)))

    # Group into files.
    def file_key(hid: str) -> str:
        if hid == 'intro':
            return 'intro'
        parts = hid.split('.')
        if parts[0] == 'I':
            if len(parts) == 1:
                return 'I.A'
            if parts[1] in ('A', 'B'):
                return f'I.{parts[1]}'
            if parts[1] == 'C':
                return 'I.C.0' if len(parts) == 2 else f'I.C.{parts[2]}'
        return parts[0]

    files = collections.OrderedDict()
    current = None
    for kind, val in blocks:
        if kind == 'h':
            e = entries[val]
            key = file_key(e['id'])
            if key not in files:
                files[key] = {'key': key, 'entries': [], 'blocks': []}
            current = files[key]
            current['entries'].append(e)
            current['blocks'].append(('h', e))
        else:
            if current is None:
                files['intro'] = current = {'key': 'intro', 'entries': [], 'blocks': []}
            current['blocks'].append(('p', val))

    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob('*.md'):
        old.unlink()

    index_files = []
    sections = collections.OrderedDict()
    md_alnum_total = []
    md_words_total = 0
    for key, f in files.items():
        root_level = min((e['level'] for e in f['entries']), default=1)
        first = f['entries'][0] if f['entries'] else None
        if key == 'intro':
            fname = '00_introduction.md'
            ftitle = 'ICD-10-CM Official Guidelines for Coding and Reporting (introduction)'
        else:
            main = next((e for e in f['entries'] if e['id'] == key), first)
            if key == 'I.C.0':
                main = next(e for e in f['entries'] if e['id'] == 'I.C')
            ftitle = re.sub(r'^(Section\s+[IVX]+\.|[A-Z]\.|\d+\.)\s*', '', main['heading_text']).strip()
            slug_src = re.sub(r'\(.*?\)', '', ftitle)
            slug = '-'.join(w for w in re.findall(r'[a-z0-9]+', slug_src.lower()) if w not in STOPWORDS)[:60].strip('-')
            if key.startswith('I.C.') and key != 'I.C.0':
                n = int(key.split('.')[2])
                fname = f'I.C.{n:02d}_{slug}.md'
            elif key == 'I.C.0':
                fname = 'I.C.00_chapter-specific-coding-guidelines.md'
            elif key == 'AppI':
                fname = 'AppI_present-on-admission-reporting-guidelines.md'
                ftitle = 'Appendix I: Present on Admission Reporting Guidelines'
            else:
                fname = f'{key}_{slug}.md'
        lines_out = [f'<!-- Source: {SOURCES["guidelines"]["title"]}. {SOURCES["guidelines"]["url"]} -->',
                     '<!-- Public domain (US Government). Extracted by tool/build_knowledge_base.py; do not edit by hand. -->',
                     '']
        body_words = 0
        body_alnum = []
        for kind, val in f['blocks']:
            if kind == 'h':
                e = val
                depth = max(1, min(6, e['level'] - root_level + 1)) if key != 'intro' else 1
                if key == 'I.A' and e['id'] == 'I':
                    depth = 1
                elif key == 'I.A':
                    depth = min(6, e['level'])
                lines_out.append(f'{"#" * depth} [{e["id"]}] {e["heading_text"]}')
                lines_out.append('')
                body_words += len(e['heading_text'].split())
                body_alnum.append(alnum(e['heading_text']))
                kw = [w for w in re.findall(r'[a-z][a-z0-9-]+', re.sub(r'^\S+\s', '', e['heading_text']).lower())
                      if w not in STOPWORDS and len(w) > 2]
                if e['id'] not in sections:
                    sections[e['id']] = {'file': fname, 'title': e['heading_text'], 'page': e['page'],
                                         'keywords': sorted(set(kw))}
            else:
                val, row = val
                text = ('- ' + val) if row else val
                lines_out.append(text)
                lines_out.append('')
                body_words += len(val.split())
                body_alnum.append(alnum(val))
        content = '\n'.join(lines_out).rstrip() + '\n'
        (out_dir / fname).write_text(content, encoding='utf-8', newline='\n')
        md_words_total += body_words
        md_alnum_total.append(''.join(body_alnum))

        # keywords: heading words + most frequent ICD categories referenced
        head_kw = []
        for e in f['entries']:
            head_kw += sections.get(e['id'], {}).get('keywords', [])
        cats = collections.Counter(m[:3] for m in re.findall(CODE_TOKEN, content))
        index_files.append({
            'id': key if key not in ('intro', 'I.C.0') else ('intro' if key == 'intro' else 'I.C'),
            'file': fname,
            'title': ftitle,
            'pages': [min(e['page'] for e in f['entries']), max(e['page'] for e in f['entries'])] if f['entries'] else [1, 1],
            'words': body_words,
            'keywords': [w for w, _ in collections.Counter(head_kw).most_common(40)],
            'codes_mentioned': [c for c, _ in cats.most_common(25)],
            'subsections': [e['id'] for e in f['entries']],
        })

    # Word-count / coverage check.
    pdf_words_all = sum(len(doc[p].get_text().split()) for p in range(doc.page_count))
    body_lines = [l for l in lines if not l['blank']]
    pdf_words_body = sum(len(l['text'].split()) for l in body_lines)
    pdf_alnum = sum(len(alnum(l['text'])) for l in body_lines)
    out_alnum_str = ''.join(md_alnum_total)
    missing_lines = []
    for l in body_lines:
        a = alnum(l['text'])
        if a and a not in out_alnum_str:
            missing_lines.append({'page': l['page'] + 1, 'text': l['text'][:120]})
    check = {
        'pdf_pages': doc.page_count,
        'pdf_words_all_pages': pdf_words_all,
        'excluded_table_of_contents_pages': f'2-{first_body_page}',
        'excluded_table_of_contents_words': toc_page_words,
        'excluded_running_header_words': header_words,
        'pdf_words_body': pdf_words_body,
        'markdown_words_body': md_words_total,
        'word_difference': md_words_total - pdf_words_body,
        'pdf_alphanumeric_chars_body': pdf_alnum,
        'markdown_alphanumeric_chars_body': len(out_alnum_str),
        'alphanumeric_difference': len(out_alnum_str) - pdf_alnum,
        'pdf_lines_not_found_in_output': len(missing_lines),
        'missing_line_samples': missing_lines[:20],
        'bookmarks': len(entries),
        'bookmarks_without_matching_heading_text': mismatches,
    }
    index = {
        'edition': f'FY{EDITION["icd_fy"]}',
        'source': {k: SOURCES['guidelines'][k] for k in ('title', 'url', 'publisher')},
        'how_to_cite': 'Cite as "ICD-10-CM Guidelines FY2027 Section <id>", e.g. Section I.C.4.a.3 or IV.H.',
        'files': index_files,
        'sections': sections,
        'extraction_check': check,
    }
    write_json(out_dir / 'index.json', index)
    return index




# ---------------------------------------------------------------------------
# 2. ICD-10-CM Tabular List XML -> code notes
# ---------------------------------------------------------------------------

NOTE_TYPES = ['inclusionTerm', 'includes', 'excludes1', 'excludes2', 'codeFirst', 'useAdditionalCode',
              'codeAlso', 'notes']
REF_TOKEN = r'[A-Z]\d[0-9A-Z](?:\.[0-9A-Z]{1,4})?'
REF_RX = re.compile(rf'({REF_TOKEN})\s*-\s*({REF_TOKEN})(?![0-9A-Z])|({REF_TOKEN})(\.-|-)?(?![0-9A-Z])')


def parse_refs(text: str) -> list:
    """Code references in parentheses: 'E11.9' exact code, 'O24.-' / 'E10.1-'
    any code starting with that prefix, 'E10-E13' inclusive range."""
    refs = []
    for grp in re.findall(r'\(([^()]*)\)', text):
        for m in REF_RX.finditer(grp):
            a, b, c, inc = m.groups()
            if a:
                refs.append(f'{a}-{b}')
            elif c:
                if inc:
                    refs.append(f'{c}.-' if '.' not in c else f'{c}-')
                else:
                    refs.append(c)
    out = []
    for r in refs:
        if r not in out:
            out.append(r)
    return out


def ref_matches(ref: str, code: str) -> bool:
    """True when an ICD-10-CM code (with or without dot) is covered by a ref
    produced by parse_refs."""
    c = code.replace('.', '')
    if ref.endswith('-') and not re.search(r'\d-[A-Z]', ref):
        return c.startswith(ref.rstrip('-').replace('.', ''))
    if '-' in ref:
        lo, hi = (x.replace('.', '') for x in ref.split('-', 1))
        return c[:len(lo)] >= lo and c[:len(hi)] <= hi
    return c.startswith(ref.replace('.', ''))


def note_texts(el) -> list:
    return [norm_ws(''.join(n.itertext())) for n in el.findall('note')]


def load_order(order_zip: Path, member: str) -> dict:
    with zipfile.ZipFile(order_zip) as z:
        text = z.read(member).decode('latin-1')
    billable = {}
    for line in text.splitlines():
        if len(line) < 16:
            continue
        billable[dotted(line[6:13].strip())] = line[14] == '1'
    return billable


def build_tabular(tab_zip: Path, member: str, order: dict, out_rules: Path, fy: int) -> dict:
    with zipfile.ZipFile(tab_zip) as z:
        raw = z.read(member)
    if b'<!DOCTYPE' in raw[:4096] or b'<!ENTITY' in raw:
        raise SystemExit('tabular XML declares a DTD or entities; refusing to parse')  # XXE / entity-expansion guard
    root = ET.fromstring(raw)
    records = []
    chapters = []
    seventh = collections.OrderedDict()
    excl1_rows = []
    titles = {}
    stats = collections.Counter()

    def own_notes(el):
        rec = {}
        for t in NOTE_TYPES:
            vals = []
            for sub in el.findall(t):
                vals += note_texts(sub)
            if vals:
                rec[t] = vals
        sn = el.find('sevenChrNote')
        sd = el.find('sevenChrDef')
        if sn is not None:
            rec['sevenChrNote'] = ' '.join(note_texts(sn))
        if sd is not None:
            rec['sevenChrDef'] = {x.get('char'): norm_ws(''.join(x.itertext())) for x in sd.findall('extension')}
        return rec

    def emit(code, title, level, notes, ancestors, extra=None):
        """ancestors: list of (code, notes), nearest first."""
        if not notes:
            return
        inherited = {}
        for t in NOTE_TYPES + ['sevenChrDef']:
            src = [a for a, an in ancestors if t in an]
            if src:
                inherited[t] = src
        seventh_src = next((a for a, an in ancestors if 'sevenChrDef' in an), None)
        rec = {'code': code, 'title': title, 'level': level}
        if level in ('category', 'subcategory', 'code'):
            rec['billable'] = order.get(code, False)
            if code not in order:
                stats['codes_not_in_order_file'] += 1
        rec.update(extra or {})
        for t in NOTE_TYPES:
            rec[t] = notes.get(t, [])
        rec['sevenChrNote'] = notes.get('sevenChrNote')
        rec['sevenChrDef'] = notes.get('sevenChrDef', {})
        refs = {}
        for t in ('includes', 'excludes1', 'excludes2', 'codeFirst', 'useAdditionalCode', 'codeAlso', 'notes'):
            if notes.get(t):
                refs[t] = [parse_refs(x) for x in notes[t]]
        rec['refs'] = refs
        rec['parents'] = [a for a, _ in ancestors]
        rec['inherited'] = inherited
        if seventh_src and 'sevenChrDef' not in notes:
            rec['sevenChrDefFrom'] = seventh_src
        records.append(rec)
        stats[f'records_{level}'] += 1
        for rl in refs.get('excludes1', []):
            if not rl:
                stats['excludes1_notes_without_code_ref'] += 1
            for r in rl:
                excl1_rows.append((code, r))
        stats['excludes1_notes'] += len(notes.get('excludes1', []))

    def walk_diag(el, ancestors, section_id):
        code = el.findtext('name').strip()
        title = norm_ws(el.findtext('desc') or '')
        notes = own_notes(el)
        children = el.findall('diag')
        titles[code] = title
        level = 'category' if len(code) == 3 else ('subcategory' if children else 'code')
        extra = {'section': section_id}
        if el.get('placeholder') == 'true':
            extra['placeholder'] = True
            stats['placeholder_flagged'] += 1
        if 'sevenChrDef' in notes:
            seventh[code] = {'chars': notes['sevenChrDef'], 'note': notes.get('sevenChrNote', '')}
        stats['diag_elements'] += 1
        emit(code, title, level, notes, ancestors, extra)
        for ch in children:
            walk_diag(ch, [(code, notes)] + ancestors, section_id)

    for chap in root.findall('chapter'):
        num = int(chap.findtext('name'))
        desc = norm_ws(chap.findtext('desc'))
        m = re.search(r'\(([A-Z]\d{2})-([A-Z0-9]{3})\)\s*$', desc)
        rng = f'{m.group(1)}-{m.group(2)}' if m else ''
        ckey = f'chapter-{num}'
        cnotes = own_notes(chap)
        sections = []
        for sref in chap.findall('sectionIndex/sectionRef'):
            sections.append({'id': sref.get('id'), 'first': sref.get('first'), 'last': sref.get('last'),
                             'title': norm_ws(''.join(sref.itertext()))})
        chapters.append({'chapter': num, 'range': rng, 'title': re.sub(r'\s*\([A-Z0-9-]+\)\s*$', '', desc),
                         'notes': dict(cnotes),
                         'refs': {t: [parse_refs(x) for x in cnotes[t]] for t in cnotes if t in NOTE_TYPES},
                         'sections': sections})
        emit(ckey, desc, 'chapter', cnotes, [], {'chapter': num, 'range': rng})
        for sec in chap.findall('section'):
            sid = sec.get('id')
            snotes = own_notes(sec)
            stitle = norm_ws(sec.findtext('desc') or '')
            anc = [(ckey, cnotes)]
            emit(sid, stitle, 'section', snotes, anc, {'chapter': num})
            for d in sec.findall('diag'):
                walk_diag(d, [(sid, snotes)] + anc, sid)

    out_rules.mkdir(parents=True, exist_ok=True)
    jl = out_rules / f'icd10cm_code_notes_{fy}.jsonl'
    with jl.open('w', encoding='utf-8', newline='\n') as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=False, separators=(',', ':')) + '\n')
    write_json(out_rules / f'icd10cm_chapters_{fy}.json', {
        'edition': f'FY{fy}', 'source': {k: SOURCES['tabular'][k] for k in ('title', 'url')},
        'chapters': chapters})
    with (out_rules / f'icd10cm_excludes1_{fy}.tsv').open('w', encoding='utf-8', newline='\n') as f:
        f.write('# code\texcluded_ref   ref = exact code (and its children), prefix ending ".-" or "-",'
                ' or inclusive range A-B. A note at a code applies to every code below it.\n')
        for c, r in excl1_rows:
            f.write(f'{c}\t{r}\n')
    write_json(out_rules / f'icd10cm_seventh_character_{fy}.json', {
        'edition': f'FY{fy}',
        'how_to_use': 'A code under one of these prefixes needs a 7th character from "chars". Pad with placeholder X '
                      'to 6 characters first (Guidelines I.A.4, I.A.5). The longest matching prefix wins.',
        'prefixes': seventh})

    def needs7(code):
        c = code.replace('.', '')
        return any(c.startswith(p.replace('.', '')) for p in seventh)
    stats.update({
        'records_total': len(records),
        'excludes1_pairs': len(excl1_rows),
        'codes_with_excludes1_pairs': len({c for c, _ in excl1_rows}),
        'seventh_character_prefixes': len(seventh),
        'order_file_codes': len(order),
        'order_file_billable': sum(1 for v in order.values() if v),
        'billable_codes_with_7th_character': sum(1 for c, b in order.items() if b and needs7(c)),
    })
    return {'records': records, 'stats': dict(stats), 'jsonl': jl, 'seventh': seventh, 'titles': titles}


# ---------------------------------------------------------------------------
# 3. Medicare Code Editor (MCE) definitions -> code lists
# ---------------------------------------------------------------------------

MCE_LISTS = [
    (re.compile(r'^A\. Perinatal/Newborn diagnoses'), 'age_newborn', '4A', 'Age conflict: perinatal/newborn diagnoses, age 0 only'),
    (re.compile(r'^B\. Pediatric diagnoses'), 'age_pediatric', '4B', 'Age conflict: pediatric diagnoses, age 0 through 17'),
    (re.compile(r'^C\. Maternity diagnoses'), 'age_maternity', '4C', 'Age conflict: maternity diagnoses, age 9 through 64'),
    (re.compile(r'^D\. Adult diagnoses'), 'age_adult', '4D', 'Age conflict: adult diagnoses, age 15 through 124'),
    (re.compile(r'^Manifestation codes not allowed as principal diagnosis'), 'manifestation_not_principal', '6',
     'Manifestation code as principal diagnosis'),
    (re.compile(r'^Questionable admission codes'), 'questionable_admission', '8A',
     'Questionable admission (inpatient principal diagnosis)'),
    (re.compile(r'^Unacceptable principal diagnosis codes'), 'unacceptable_principal', '9',
     'Unacceptable principal diagnosis (codes in requires_secondary are acceptable when a secondary diagnosis is present)'),
    (re.compile(r'^Wrong procedure performed codes'), 'wrong_procedure_performed', '18',
     'Wrong procedure performed (external cause codes)'),
    (re.compile(r'^The following pages contain the list of unspecified ICD-10-CM diagnosis codes'),
     'unspecified_with_laterality_available', '20',
     'Unspecified code: unspecified side when a right/left/bilateral code exists in the family'),
]
MCE_AGE = {'age_newborn': [0, 0], 'age_pediatric': [0, 17], 'age_maternity': [9, 64], 'age_adult': [15, 124]}


def build_mce(mce_zip: Path, out_rules: Path) -> dict:
    with zipfile.ZipFile(mce_zip) as z:
        name = next(n for n in z.namelist() if n.lower().endswith('.txt'))
        text = z.read(name).decode('cp1252', errors='replace')
    edits = []
    started = False
    current = None
    lists = collections.OrderedDict()
    for ln in text.splitlines():
        s = ln.strip()
        if s == 'Below is a list of edits described in this chapter.':
            started = True
            continue
        if not started:
            continue
        if s.startswith('Chapter 2: Code list changes'):
            break
        m = re.match(r'^(\d{1,2})\. (.+)$', s)
        if m and '\t' not in ln and len(s) < 90 and not s.endswith(('.', ':')):
            num, title = int(m.group(1)), m.group(2)
            if not any(e['number'] == num for e in edits):
                pm = re.search(r'\((deactivated|discontinued)[^)]*\)', title)
                edits.append({'number': num, 'title': re.sub(r'\s*\((deactivated|discontinued)[^)]*\)', '', title),
                              'status': pm.group(0).strip('()') if pm else 'active'})
            current = None
            continue
        hit = False
        for rx, key, eid, desc in MCE_LISTS:
            if rx.match(s):
                current = key
                lists.setdefault(key, {'edit': eid, 'description': desc, 'codes': [], 'requires_secondary': []})
                hit = True
                break
        if hit or not current:
            continue
        if '\t' in ln:
            code = ln.split('\t')[0].strip()
            star = code.startswith('*')
            code = code.lstrip('*')
            if re.fullmatch(r'[A-Z]\d[0-9A-Z]{1,5}', code):
                lists[current]['codes'].append(dotted(code))
                if star:
                    lists[current]['requires_secondary'].append(dotted(code))
        elif s and not s.startswith(('Note:', 'The following')):
            current = None
    for k, v in lists.items():
        if k in MCE_AGE:
            v['age_min'], v['age_max'] = MCE_AGE[k]
        v['count'] = len(v['codes'])
        if not v['requires_secondary']:
            del v['requires_secondary']
    obj = {
        'version': f'v{EDITION["mce_version"]}.0',
        'effective': 'October 1, 2026 (FY2027)',
        'source': {k: SOURCES['mce'][k] for k in ('title', 'url', 'publisher')},
        'scope': 'The MCE edits inpatient (institutional) claims grouped to MS-DRGs. The age lists and the '
                 'manifestation list describe the codes themselves and are commonly reused by outpatient and '
                 'professional claim editors, but payers apply their own variants. The MCE sex conflict edit is '
                 'deactivated as of 10/01/2024, so the MCE no longer publishes sex lists.',
        'edits': edits,
        'lists': lists,
    }
    write_json(out_rules / f'mce_edits_v{EDITION["mce_version"]}.json', obj, indent=None)
    return obj


# ---------------------------------------------------------------------------
# 4. NCCI Policy Manual -> chapter / section index (titles and pages only)
# ---------------------------------------------------------------------------

def build_ncci_index(pdf_path: Path, out_rules: Path) -> dict:
    doc = fitz.open(pdf_path)
    starts = []
    for lvl, title, page in doc.get_toc():
        if lvl != 1:
            continue
        m = re.match(r'^\d+\s+Chapter(\d+)', title)
        if m:
            starts.append((ROMAN[int(m.group(1))], page - 1))
        elif 'Introduction' in title:
            starts.append(('Intro', page - 1))
    starts.sort(key=lambda x: x[1])
    chapters = []
    for idx, (chap, p0) in enumerate(starts):
        p_end = starts[idx + 1][1] if idx + 1 < len(starts) else doc.page_count
        text = '\n'.join(doc[p].get_text() for p in range(p0, min(p0 + 4, p_end)))
        buf = ''
        sections = []
        for ln in text.splitlines():
            s = ln.strip()
            if not s:
                continue
            if re.match(r'^[A-Z]\.\s', s):
                buf = s
            elif buf:
                buf = buf + ' ' + s
            else:
                continue
            m = re.match(r'^([A-Z])\.\s+(.+?)\s*\.{3,}\s*((?:[IVX]+|Intro)-\d+)\s*$', buf)
            if m:
                if not any(x['section'] == m.group(1) for x in sections):
                    sections.append({'section': m.group(1), 'title': norm_ws(m.group(2)), 'page_label': m.group(3)})
                buf = ''
            elif len(buf) > 250:
                buf = ''
        chapters.append({'chapter': chap, 'title': NCCI_CHAPTER_TITLES.get(chap, ''), 'pdf_pages': [p0 + 1, p_end],
                         'sections': sections})
    obj = {
        'edition': f'Medicare NCCI Policy Manual {EDITION["ncci_year"]}',
        'source': {k: SOURCES['ncci_manual'][k] for k in ('title', 'url', 'publisher')},
        'note': 'Chapter and section titles only, for citations. The manual text is not copied: it quotes CPT '
                'descriptors (AMA copyright). Cite as "NCCI Policy Manual 2026, Ch. I, Sec. E".',
        'chapters': chapters,
    }
    write_json(out_rules / f'ncci_policy_manual_sections_{EDITION["ncci_year"]}.json', obj)
    return obj


# ---------------------------------------------------------------------------
# 5. NCCI add-on code edits (CMS quarterly file; bare code numbers only)
# ---------------------------------------------------------------------------

def julian_to_iso(j: str):
    import datetime
    j = j.strip()
    if not re.fullmatch(r'\d{7}', j):
        return None
    d = datetime.date(int(j[:4]), 1, 1) + datetime.timedelta(days=int(j[4:]) - 1)
    return d.isoformat()


def build_aoc(aoc_zip: Path, out_rules: Path, as_of: str) -> dict:
    """Fixed-width rows (same columns as the .xlsx in the zip): type(1) add-on
    code(5) add-on deletion date(7, YYYYDDD) primary code(5) primary deletion
    date(7) edit effective date(7) edit deletion date(7) notes."""
    with zipfile.ZipFile(aoc_zip) as z:
        name = next(n for n in z.namelist() if n.lower().endswith('.txt'))
        lines = z.read(name).decode('latin-1').splitlines()
    rows = []
    for ln in lines:
        if len(ln) < 32:
            continue
        typ, addon, addon_del, primary, prim_del, eff, dele = (
            ln[0], ln[1:6].strip(), ln[6:13], ln[13:18].strip(), ln[18:25], ln[25:32], ln[32:39])
        dates = [julian_to_iso(x) for x in (addon_del, prim_del, dele)]
        if any(d and d <= as_of for d in dates):
            continue  # deleted before the as-of date
        rows.append((addon, primary, typ))
    out = out_rules / f'ncci_addon_code_edits_{name.split("_")[1][:7].lower() if "_" in name else "current"}.tsv'
    with out.open('w', encoding='utf-8', newline='\n') as f:
        f.write(f'# NCCI add-on code (AOC) edits active on {as_of}; source {SOURCES["aoc"]["url"]}\n')
        f.write('# addon_code\tprimary_code\taoc_type   type 1 = only the listed primary codes are acceptable; type 2 = '
                'primary codes defined by the MAC (primary shown as CCCCC); type 3 = listed primaries plus MAC-defined. '
                'NCCI Policy Manual Ch. I, Sec. R and W. Codes are bare HCPCS/CPT numbers as CMS publishes them; '
                'no descriptors.\n')
        for r in rows:
            f.write('\t'.join(r) + '\n')
    types = collections.Counter(t for _, _, t in rows)
    return {'file': out.name, 'rows': len(rows), 'addon_codes': len({a for a, _, _ in rows}), 'by_type': dict(types)}


# ---------------------------------------------------------------------------
# 6. Rule catalog
# ---------------------------------------------------------------------------

def G(section):
    return {'type': 'guideline', 'ref': section}


def T(note_type):
    return {'type': 'tabular_note', 'ref': note_type}


def M(edit_number):
    return {'type': 'mce', 'ref': edit_number}


def N(chapter, section):
    return {'type': 'ncci_manual', 'ref': f'{chapter}.{section}'}


def IMPL(status, files=(), evidence=None, note=''):
    return {'status': status, 'files': list(files), 'evidence': evidence, 'note': note}


SCRUB = 'lib/services/coding/claim_scrubber.dart'
CODER = 'lib/services/coding/clinical_coder.dart'
RULES_DART = 'lib/services/coding/code_rules.dart'
BUILDER = 'lib/services/coding/claim_builder.dart'
ICDCAT = 'lib/services/codesets/icd_catalog.dart'
MUE_DART = 'lib/services/codesets/mue.dart'
PTP_DART = 'lib/services/codesets/ptp.dart'
FEES = 'lib/services/codesets/fee_schedule.dart'
CLAIM_TAB = 'lib/screens/claim_tab.dart'
KC = 'lib/services/coding/knowledge_checks.dart'

# Each rule: id, title, sources, rule (plain English, paraphrased from the
# cited official text), inputs, check, severity (error = the claim is expected
# to reject or deny; warning = review, coding-guideline violation or likely
# payer edit; info = guidance), settings, data (knowledge files used),
# implemented (app status, verified at build time by an evidence regex),
# impact (1-5, claim-denial impact used to rank gaps) and hint (how to
# implement in the existing Dart code).
RULES = [
    # --- Code validity --------------------------------------------------------
    dict(id='ICD-VALID-01', title='Code must exist in the ICD-10-CM edition for the date of service',
         sources=[G('I.A.3'), G('IV.F.2'), M(1)],
         rule='Every diagnosis code must be a code in the ICD-10-CM edition in effect on the date of service '
              '(FY2027 covers October 1, 2026 through September 30, 2027).',
         inputs=['diagnosis codes', 'date of service'], check='Look the code up in the order file of the edition for the DOS.',
         severity='error', settings=['all'], data=['assets/codes/icd10cm_<FY>.tsv.gz'],
         implemented=IMPL('yes', [SCRUB, ICDCAT], r'icd\.isValid\('), impact=5, hint=''),
    dict(id='ICD-BILLABLE-01', title='Report codes to the full number of characters (no categories or subcategories)',
         sources=[G('I.A.3'), G('IV.F.1'), G('IV.F.2')],
         rule='Only codes are reportable, not categories or subcategories; a code is invalid if it is not coded to '
              'the full number of characters required, including an applicable 7th character.',
         inputs=['diagnosis codes'], check='billable flag = 1 in icd10cm_order_<FY>.txt (billable=true in the JSONL).',
         severity='error', settings=['all'], data=['assets/codes/icd10cm_<FY>.tsv.gz', 'rules/icd10cm_code_notes_<FY>.jsonl'],
         implemented=IMPL('yes', [SCRUB, ICDCAT], r'isBillable\('), impact=5, hint=''),
    dict(id='ICD-7TH-01', title='7th character required where the Tabular defines one, and must be a defined value',
         sources=[G('I.A.5'), T('sevenChrDef'), G('I.C.19.a')],
         rule='Codes in categories or subcategories that carry a 7th character definition need a 7th character, and it '
              'must be one of the values listed for that category (for example A, D, S for most injuries).',
         inputs=['diagnosis codes'], check='Find the longest prefix in icd10cm_seventh_character_<FY>.json; the code must '
              'have 7 characters and its 7th must be a key of "chars".',
         severity='error', settings=['all'], data=['rules/icd10cm_seventh_character_<FY>.json'],
         implemented=IMPL('yes', [SCRUB, 'lib/services/codesets/seventh_character.dart'], r'seventhCharacterIssue\(', 'ClaimScrubber names the missing or invalid 7th character, lists the allowed values from icd_7th_2027.tsv.gz and gives a corrected code. The coder still defaults injuries to A (see CH19-INJ-01).'),
         impact=5, hint='In ClaimScrubber, when isValid/isBillable fails, look up the seventh-character prefix and list '
                        'the allowed characters (and the X padding) in the issue text.'),
    dict(id='ICD-PLACEHOLDER-01', title='Placeholder X fills empty positions before a 7th character',
         sources=[G('I.A.4'), G('I.A.5')],
         rule='Where a placeholder exists the X must be used; a code that needs a 7th character but has fewer than 6 '
              'characters is padded with X (for example T36.0X1A).',
         inputs=['diagnosis codes'], check='If the code is invalid and inserting X up to 6 characters makes it valid, '
              'suggest the padded code.', severity='error', settings=['all'],
         data=['rules/icd10cm_seventh_character_<FY>.json', 'rules/icd10cm_code_notes_<FY>.jsonl (placeholder=true)'],
         implemented=IMPL('yes', [SCRUB, RULES_DART], r'Missing placeholder X', 'withSeventhCharacter() pads with X to 6 characters; the scrubber suggests the padded code when it is billable.'),
         impact=4, hint='Add a helper in code_rules.dart that pads with X to 6 characters and re-checks IcdCatalog.isBillable; '
                        'offer the fix in the scrubber issue.'),

    # --- Tabular conventions ---------------------------------------------------
    dict(id='ICD-EXCL1-01', title='Excludes1: the two codes are not reported together',
         sources=[G('I.A.12.a'), T('excludes1')],
         rule='An Excludes1 note means the excluded condition is never coded with the code above the note. Exception: '
              'when the two conditions are unrelated to each other both may be reported; if unclear, query the provider.',
         inputs=['all diagnosis codes on the claim'],
         check='For each code, collect excludes1 refs at the code and at every ancestor (subcategory, category, block, '
               'chapter); flag any other claim code that matches a ref.',
         severity='error', severity_basis='coding convention; commercial claim editors deny Excludes1 pairs; allow a '
                                          'documented override for unrelated conditions',
         settings=['all'], data=['rules/icd10cm_excludes1_<FY>.tsv', 'rules/icd10cm_code_notes_<FY>.jsonl'],
         implemented=IMPL('yes', [SCRUB, 'lib/services/codesets/excludes1.dart'], r'excludes1Issues\(', 'Pairwise check over the claim diagnoses using icd10cm_excludes1_2027.tsv.gz (notes at the code and every ancestor, prefix and range refs). Error by default; a diagnosis note saying the conditions are unrelated turns it into a warning (I.A.12.a exception).'), impact=4,
         hint='Bundle icd10cm_excludes1_<FY>.tsv as an asset, load it in ReferenceData, and add a pairwise check in '
              'ClaimScrubber over claim.billable (prefix/range match as in ref_matches).'),
    dict(id='ICD-EXCL2-01', title='Excludes2: both codes may be reported',
         sources=[G('I.A.12.b'), T('excludes2')],
         rule='An Excludes2 note means the excluded condition is not part of the code, but the patient may have both; '
              'both codes may be reported together when appropriate.',
         inputs=['all diagnosis codes'], check='Never block on an Excludes2 match; at most show it as information.',
         severity='info', settings=['all'], data=['rules/icd10cm_code_notes_<FY>.jsonl'],
         implemented=IMPL('yes', [SCRUB], r'class ClaimScrubber',
                          'Nothing to enforce: the scrubber does not block Excludes2 pairs. Keep it that way when '
                          'Excludes1 checks are added.'), impact=1, hint=''),
    dict(id='ICD-MANIF-01', title='Manifestation codes are never first-listed and follow their etiology',
         sources=[G('I.A.13'), T('codeFirst'), M(6)],
         rule='"In diseases classified elsewhere" codes (and other manifestation codes with a "code first" note) are '
              'never the first-listed or principal diagnosis; they are listed after the underlying condition.',
         inputs=['ordered diagnosis list'],
         check='First-listed code must not be in MCE list manifestation_not_principal and must not have "in diseases '
               'classified elsewhere" in its title; when such a code is present the etiology code must precede it.',
         severity='error', settings=['all'], data=['rules/mce_edits_v44.json', 'rules/icd10cm_code_notes_<FY>.jsonl'],
         implemented=IMPL('yes', [SCRUB, KC, CODER], r"'ICD-MANIF-01'", 'Error when the first-listed code is on the MCE manifestation list or its title says "in diseases classified elsewhere"; warning when the etiology its code-first note names is listed after it (icd_notes_2027.tsv.gz); finalizeDiagnoses moves that etiology ahead.'), impact=5,
         hint='Remaining: read the codeFirst refs of the manifestation code (icd10cm_code_notes JSONL) and warn when '
              'no matching etiology code precedes it.'),
    dict(id='ICD-CODEFIRST-01', title='"Code first" notes: sequence the underlying condition first when present',
         sources=[G('I.A.13'), G('I.B.7'), T('codeFirst')],
         rule='When a code has a "code first" note and the underlying condition is present, the underlying condition is '
              'sequenced first. "Code, if applicable, any causal condition first" allows the code first-listed only '
              'when the cause is unknown or not applicable.',
         inputs=['ordered diagnosis list'], check='If a codeFirst ref matches another claim code that is listed later, '
                                                  'warn and offer to reorder.',
         severity='warning', settings=['all'], data=['rules/icd10cm_code_notes_<FY>.jsonl'],
         implemented=IMPL('yes', [KC, CODER], r"'ICD-CODEFIRST-01'", 'KnowledgeChecks.codeFirstIssues warns when a code named in a code-first note is listed after the code; ClinicalCoder.finalizeDiagnoses reorders (a physician-pinned primary stays first). Lines qualified with a character ("with .42") are not used.'), impact=3,
         hint='Use refs.codeFirst from the JSONL (asset or generated Dart map) in finalizeDiagnoses ordering.'),
    dict(id='ICD-USEADD-01', title='"Use additional code" notes: add the secondary code when known',
         sources=[G('I.B.7'), G('I.A.13'), T('useAdditionalCode')],
         rule='A "use additional code" note indicates that a secondary code should be added, if known, to fully '
              'describe the condition (for example the organism B95-B97 for an infection, Z79.4 for insulin use).',
         inputs=['diagnosis codes', 'documentation'], check='If a code (or its ancestors) has useAdditionalCode refs and '
              'no claim code matches them, suggest them for review.',
         severity='warning', settings=['all'], data=['rules/icd10cm_code_notes_<FY>.jsonl'],
         implemented=IMPL('yes', [KC], r"'ICD-USEADD-01'", 'Info suggestion per code when no claim code satisfies a category- or code-level use-additional-code note group; never auto-added. The notes are also shown in the claim tab.'), impact=2, hint='Show as a suggestion chip in claim_tab.dart; never auto-add without documentation.'),
    dict(id='ICD-CODEALSO-01', title='"Code also" notes: a second code may be needed, sequencing is discretionary',
         sources=[G('I.A.17'), T('codeAlso')],
         rule='A "code also" note says two codes may be needed to fully describe a condition; it does not set the order.',
         inputs=['diagnosis codes'], check='Informational prompt only.', severity='info', settings=['all'],
         data=['rules/icd10cm_code_notes_<FY>.jsonl'], implemented=IMPL('yes', [KC], r"'ICD-CODEALSO-01'", 'Info prompt when no claim code satisfies a code-also note.'), impact=1, hint='Suggestion only.'),

    # --- General guidelines ----------------------------------------------------
    dict(id='ICD-SYMPTOM-01', title='Signs and symptoms integral to a confirmed diagnosis are not coded',
         sources=[G('I.B.5'), G('I.C.18.b')],
         rule='Signs and symptoms routinely associated with a disease process are not assigned as additional codes '
              'unless the classification instructs otherwise. Symptoms not routinely associated may be coded.',
         inputs=['confirmed diagnoses', 'symptom codes'], check='Drop Chapter 18 symptom codes that are routinely part '
              'of a confirmed diagnosis; definitive diagnosis is sequenced before any symptom code.',
         severity='warning', settings=['all'], data=['guidelines/I.B_general.md'],
         implemented=IMPL('yes', [CODER], r'ICD-SYMPTOM-01', 'ClinicalCoder folds a symptom into a confirmed diagnosis when an Excludes1 note of the diagnosis names the symptom, plus the body-system heuristic; the scrubber flags hand-entered pairs through Excludes1 and ICD-SYMPTOM-02.'),
         impact=3, hint='Keep the heuristic but also check Excludes1 notes of the confirmed code that point at the symptom.'),
    dict(id='ICD-SYMPTOM-02', title='Symptom codes when no definitive diagnosis is established',
         sources=[G('I.B.4'), G('IV.D'), G('II.A')],
         rule='Symptom and sign codes are acceptable when a related definitive diagnosis has not been established. '
              'They are not the principal/first-listed diagnosis when a related definitive diagnosis has been established.',
         inputs=['ordered diagnosis list'], check='Warn when the first-listed code is in Chapter 18 (R00-R99) and a '
              'related confirmed diagnosis is also on the claim.',
         severity='warning', settings=['all'], data=[],
         implemented=IMPL('yes', [KC], r"'ICD-SYMPTOM-02'", 'Warning when an R00-R99 code is first-listed and a confirmed diagnosis of the same body system is on the claim.'),
         impact=3, hint=''),
    dict(id='ICD-COMBO-01', title='Use a combination code when one code captures all elements',
         sources=[G('I.B.9'), G('I.C.18.c')],
         rule='When a combination code fully identifies the conditions (two diagnoses, a diagnosis with its '
              'manifestation, or with a complication), assign only the combination code; add a secondary code only '
              'when the combination code lacks needed specificity.',
         inputs=['diagnosis codes'], check='Flag pairs that a combination code covers (Index "with" subterms, Excludes1 '
              'notes and inclusion terms of the combination code).',
         severity='warning', settings=['all'], data=['rules/icd10cm_code_notes_<FY>.jsonl'],
         implemented=IMPL('yes', [KC, CODER], r"'ICD-COMBO-01'", 'Alphabetic Index "with" subterms and "acute and chronic" entries give the combination code: warning in the scrubber; ClinicalCoder.combineFromIndex replaces confirmed pairs (keeps the second code when the combination code asks for it). Excludes1 pairs are errors (ICD-EXCL1-01).'),
         impact=3, hint='Derive candidate pairs from Excludes1 notes of combination codes rather than hard-coded families.'),
    dict(id='ICD-ACUTECHRONIC-01', title='Acute and chronic forms: code both, acute first',
         sources=[G('I.B.8')],
         rule='If the same condition is described as both acute (subacute) and chronic and separate Index subentries '
              'exist at the same level, code both and sequence the acute code first.',
         inputs=['diagnosis codes', 'documentation'], check='Requires Index data; warn when both forms are present in '
              'the wrong order.', severity='warning', settings=['all'], data=['assets/codes/icd10cm_index_<FY>.tsv.gz'],
         implemented=IMPL('yes', [KC], r"'ICD-ACUTECHRONIC-01'", 'Index subentries acute and chronic under the same term: warning when the chronic code is listed first; a combination entry becomes ICD-COMBO-01.'), impact=2, hint='Use IcdIndex paths containing "acute" and "chronic" under the same main term.'),
    dict(id='ICD-SEQUELA-01', title='Sequela: condition first, sequela code second',
         sources=[G('I.B.10'), G('I.C.19.a')],
         rule='Coding a sequela generally needs two codes: the residual condition first, then the sequela code (7th '
              'character S for injuries). The acute-phase code is never used with a code for the late effect.',
         inputs=['ordered diagnosis list'], check='If a code with 7th character S is first-listed, or no residual '
              'condition code accompanies it, warn.', severity='warning', settings=['all'],
         data=['rules/icd10cm_seventh_character_<FY>.json'], implemented=IMPL('yes', [KC], r"'ICD-SEQUELA-01'", 'Warning when a 7th character S (sequela) code is first-listed or has no residual condition code.'), impact=3,
         hint='In ClaimScrubber detect 7th character S on injury/poisoning codes (chapter 19) and check position.'),
    dict(id='ICD-DUP-01', title='Report each code only once per encounter',
         sources=[G('I.B.12'), M(3)],
         rule='Each unique ICD-10-CM code may be reported only once for an encounter, including bilateral conditions '
              'without distinct laterality codes.',
         inputs=['diagnosis codes'], check='No duplicate codes in the diagnosis list.', severity='error',
         settings=['all'], data=[],
         implemented=IMPL('yes', [KC, CLAIM_TAB], r"'ICD-DUP-01'", 'Error in the scrubber; the claim tab also prevents adding a duplicate.'),
         impact=2, hint='One-line check in ClaimScrubber: dx.map(code).toSet().length != dx.length.'),
    dict(id='ICD-LAT-01', title='Laterality and bilateral codes',
         sources=[G('I.B.13'), G('I.C.13.a')],
         rule='If no bilateral code exists and the condition is bilateral, assign separate left and right codes; when '
              'a bilateral code exists use it. Laterality may be taken from other clinicians; unspecified side codes '
              'should rarely be used.',
         inputs=['diagnosis codes', 'documented side'],
         check='Warn when right and left codes of the same family are both on the claim and a bilateral code exists '
               'in that family.', severity='warning', settings=['all'], data=['assets/codes/icd10cm_<FY>.tsv.gz'],
         implemented=IMPL('yes', [KC], r"'ICD-LAT-01'", 'Warning when right and left codes of the same condition are reported and the category has a bilateral code.'),
         impact=3, hint='Use IcdCatalog.billableChildren on the shared parent to find a "bilateral" sibling.'),
    dict(id='ICD-LAT-02', title='Unspecified side when a sided code exists (MCE unspecified code edit)',
         sources=[M(20), G('I.B.13'), G('I.B.18')],
         rule='MCE edit 20 lists unspecified codes for which a more specific code identifies laterality. Unspecified '
              'side codes are acceptable only when documentation is insufficient.',
         inputs=['diagnosis codes'], check='Warn when a code is in MCE list unspecified_with_laterality_available.',
         severity='warning', severity_basis='payer specificity edits; MCE edit 20 is informational for inpatient',
         settings=['all'], data=['rules/mce_edits_v44.json'],
         implemented=IMPL('yes', [KC, 'lib/services/codesets/mce.dart'], r"'ICD-LAT-02'", 'Warning for every code on the MCE v44 edit 20 list (3,476 codes in mce_v44.tsv.gz).'),
         impact=3, hint='Replace isUnspecifiedIcd with the official 3,476-code MCE list.'),
    dict(id='ICD-SECONDARY-ONLY-01', title='Codes that are only reported as secondary diagnoses',
         sources=[G('I.B.14'), G('I.C.21.c.17'), G('I.C.18.e.1'), G('I.C.18.i')],
         rule='BMI, coma scale, NIHSS, blood alcohol level, social determinants of health and underimmunization status '
              'codes are reported only as secondary diagnoses, and the associated condition must be documented by '
              'the patient\'s provider.',
         inputs=['ordered diagnosis list'], check='First-listed code must not match the resolved code list in "official_list".',
         severity='error', settings=['all'], data=['rule_catalog.json official_list'],
         implemented=IMPL('yes', [RULES_DART, SCRUB], r'secondaryOnlyIcdPrefixes', 'Const prefix list in code_rules.dart; error in ClaimScrubber.sequencingIssues; finalizeDiagnoses ranks them last.'), impact=4,
         hint='Add a const prefix list to code_rules.dart (generated from official_list) and an error in ClaimScrubber '
              'when dx.first matches.'),
    dict(id='ICD-UNSPEC-01', title='Unspecified codes are allowed when documentation lacks detail',
         sources=[G('I.A.9.b'), G('I.B.18'), G('IV.F.3')],
         rule='Code to the highest specificity the documentation supports; signs, symptoms and unspecified codes are '
              'acceptable when the record does not provide more detail.',
         inputs=['diagnosis codes', 'documentation'], check='Information prompt to document specificity.',
         severity='info', settings=['all'], data=[],
         implemented=IMPL('yes', [SCRUB], r'Unspecified primary diagnosis'), impact=1, hint=''),

    # --- Outpatient (Section IV) -----------------------------------------------
    dict(id='OP-UNCERTAIN-01', title='Outpatient: do not code uncertain diagnoses',
         sources=[G('IV.H')],
         rule='In the outpatient setting do not code diagnoses documented as probable, suspected, questionable, rule '
              'out, compatible with, consistent with, working diagnosis or similar; code the signs, symptoms or '
              'other reasons for the visit instead.',
         inputs=['diagnosis certainty from documentation', 'setting'], check='Uncertain diagnoses are not billed on '
              'outpatient/professional claims.', severity='warning',
         severity_basis='coding-guideline violation (overcoding; audit and recoupment risk)', settings=['outpatient', 'professional'],
         data=['guidelines/IV_diagnostic-reporting-outpatient-services.md'],
         implemented=IMPL('yes', [CODER, SCRUB], r'_hedge'), impact=4, hint=''),
    dict(id='INPT-UNCERTAIN-01', title='Inpatient: uncertain diagnoses at discharge are coded as if established',
         sources=[G('II.H'), G('III.C')],
         rule='For inpatient admissions (short-term, acute, long-term care and psychiatric hospitals), a diagnosis '
              'documented as uncertain at discharge is coded as if it existed. This does not apply to outpatients.',
         inputs=['setting', 'certainty'], check='Apply only for inpatient place of service.', severity='info',
         settings=['inpatient'], data=['guidelines/II_selection-principal.md', 'guidelines/III_reporting-additional.md'],
         implemented=IMPL('yes', [CODER], r'!inpatient'), impact=1, hint=''),
    dict(id='OP-FIRSTLISTED-01', title='Outpatient first-listed diagnosis is the reason chiefly responsible for the visit',
         sources=[G('IV.A'), G('IV.G'), G('IV.J')],
         rule='List first the code for the condition chiefly responsible for the services; list additional codes for '
              'coexisting conditions that affect care. Do not code conditions previously treated that no longer exist.',
         inputs=['ordered diagnosis list'], check='Review ordering; history codes Z80-Z87 only as secondary information.',
         severity='info', settings=['outpatient', 'professional'], data=[],
         implemented=IMPL('yes', [KC, CODER], r"'OP-FIRSTLISTED-01'", 'finalizeDiagnoses ranking with a physician-pinned primary; warning when a Z80-Z87 history code is first-listed.'),
         impact=2, hint=''),
    dict(id='ICD-EXTCAUSE-01', title='External cause codes are never first-listed',
         sources=[G('I.C.20.a.6'), G('IV.B'), M(2)],
         rule='External cause of morbidity codes (V00-Y99) are never the principal or first-listed diagnosis; the '
              'first-listed code comes from A00.0-T88.9, Z00-Z99 or U00-U85.',
         inputs=['ordered diagnosis list'], check='Error when dx.first starts with V, W, X or Y.', severity='error',
         settings=['all'], data=['rules/icd10cm_chapters_<FY>.json'], implemented=IMPL('yes', [SCRUB, RULES_DART], r'External cause listed first', 'Error in ClaimScrubber.sequencingIssues; finalizeDiagnoses ranks V00-Y99 codes last.'), impact=5,
         hint='Two lines in ClaimScrubber: if dx.first.code starts with V/W/X/Y raise an error and offer to reorder.'),
    dict(id='ICD-EXTCAUSE-02', title='Place of occurrence (Y92) and external cause status (Y99) are reported once',
         sources=[G('I.C.20.b'), G('I.C.20.k')],
         rule='Y92 and Y99 are secondary codes used with other external cause codes, generally only at the initial '
              'encounter; only one Y99 per record; do not use Y92.9 or Y99.9 when not stated; Y99 is not used for '
              'poisonings, adverse effects, misadventures or late effects.',
         inputs=['diagnosis codes', 'encounter (initial or subsequent)'], check='Warn on more than one Y99, Y92.9/Y99.9, '
              'or Y92/Y99 without another external cause code.', severity='warning', settings=['all'], data=[],
         implemented=IMPL('yes', [KC], r"'ICD-EXTCAUSE-02'", 'Warnings on more than one Y99 or Y92, on Y92.9/Y99.9, and on Y92/Y99 without another external cause code.'), impact=2, hint=''),
    dict(id='OP-DIAGSERVICES-01', title='Outpatient diagnostic services: code the interpreted result',
         sources=[G('IV.K')],
         rule='For diagnostic services only, sequence first the reason for the test; when a physician has interpreted '
              'the test and the report is available, code confirmed diagnoses from the interpretation and not the '
              'related signs and symptoms.',
         inputs=['test interpretation'], check='Workflow rule.', severity='info', settings=['outpatient'], data=[],
         implemented=IMPL('yes', [KC], r"'OP-DIAGSERVICES-01'", 'Info reminder when a diagnostic test (PFS PC/TC indicator 1, 2, 4, 6 or 8) is billed with a symptom first-listed.'), impact=1, hint=''),
    dict(id='OP-PREOP-01', title='Preoperative evaluation: Z01.81- first',
         sources=[G('IV.M')],
         rule='For preoperative evaluations only, sequence first a code from Z01.81-, then the reason for surgery and '
              'any findings.', inputs=['visit type'], check='Warn when a pre-op visit is not led by Z01.81-.',
         severity='warning', settings=['outpatient', 'professional'], data=[], implemented=IMPL('yes', [CODER, SCRUB], r'OP-PREOP-01', 'ClinicalCoder adds Z01.810/Z01.811/Z01.818 for a documented preoperative evaluation and ranks it first; error when Z01.81- is not first.'), impact=2, hint=''),
    dict(id='OP-THERAPY-01', title='Encounter for chemotherapy, immunotherapy or radiation therapy: Z51.- first',
         sources=[G('IV.L'), G('I.C.2.a'), G('I.C.2.e.2')],
         rule='When the encounter is chiefly for antineoplastic chemotherapy, immunotherapy or radiation therapy, the '
              'Z51.0 / Z51.1- code is listed first and the malignancy second.', inputs=['services', 'diagnoses'],
         check='Warn when chemo/radiation administration services are billed and Z51.0/Z51.1- is not first.',
         severity='warning', settings=['outpatient'], data=[], implemented=IMPL('yes', [KC], r"'OP-THERAPY-01'", 'Warning when chemotherapy administration (96401-96549) or radiation treatment delivery (77401-77525) is billed and Z51.0/Z51.1- is not first.'), impact=2, hint=''),
    dict(id='POA-01', title='Present on admission indicator: inpatient institutional claims only',
         sources=[G('AppI')],
         rule='The POA indicator is assigned to diagnoses on inpatient claims (UB-04 / 837 Institutional) subject to '
              'POA reporting. It is not reported on outpatient or professional (837P / CMS-1500) claims.',
         inputs=['claim type'], check='Do not send POA on 837P; require it only on inpatient 837I.', severity='info',
         settings=['inpatient'], data=['guidelines/AppI_present-on-admission-reporting-guidelines.md'],
         implemented=IMPL('yes', [BUILDER], r"'transaction': '837P'", 'The app builds 837P only; no POA is sent.'),
         impact=1, hint=''),

    # --- Chapter-specific --------------------------------------------------------
    dict(id='CH1-SEPSIS-01', title='Severe sepsis R65.2- is never first-listed; the systemic infection comes first',
         sources=[G('I.C.1.d.1.a'), G('I.C.1.d.2'), G('I.C.1.d.3'), M(9), T('codeFirst')],
         rule='Code the underlying systemic infection first; R65.2- (severe sepsis, with or without septic shock) can '
              'never be the principal diagnosis and is assigned only when severe sepsis or an associated acute organ '
              'dysfunction is documented.',
         inputs=['ordered diagnosis list'], check='Error when dx.first starts with R65.2; warn when R65.2- has no '
              'infection code before it.', severity='error', settings=['all'],
         data=['rules/mce_edits_v44.json (unacceptable_principal)'], implemented=IMPL('yes', [SCRUB, RULES_DART], r'Severe sepsis listed first', 'Error when R65.2- is first-listed; warning when no systemic infection code precedes it.'), impact=4, hint=''),
    dict(id='CH2-NEO-01', title='Current malignancy versus personal history (Z85)',
         sources=[G('I.C.2.m'), G('I.C.2.d')],
         rule='Use the malignancy code while treatment is directed at the site; use Z85 when the malignancy was excised '
              'or eradicated, no further treatment is directed to the site and there is no evidence of disease.',
         inputs=['diagnoses', 'treatment status'], check='Warn when a C code and the Z85 code for the same site are both '
              'present.', severity='warning', settings=['all'], data=[], implemented=IMPL('yes', [KC], r"'CH2-NEO-01'", 'Warning when a C code (not C77-C79) matches the site of a Z85 code; the site comes from the Index entries History, personal, malignant neoplasm.'), impact=2, hint=''),
    dict(id='CH2-NEO-02', title='Neoplasm symptoms do not replace the malignancy as first-listed',
         sources=[G('I.C.2.g'), G('I.C.2.l')],
         rule='Chapter 18 symptoms associated with an existing malignancy are not used in place of the malignancy as '
              'principal/first-listed diagnosis.', inputs=['ordered diagnosis list'],
         check='Warn when dx.first is R00-R99 and a C code is present.', severity='warning', settings=['all'], data=[],
         implemented=IMPL('yes', [KC], r"'CH2-NEO-02'", 'Warning when an R code is first-listed and a malignancy is on the claim.'), impact=2, hint=''),
    dict(id='CH4-DM-01', title='Diabetes: default type, combination codes, long-term drug codes',
         sources=[G('I.C.4.a'), G('I.C.4.a.2'), G('I.C.4.a.3'), T('useAdditionalCode')],
         rule='If the type is not documented the default is E11 (type 2). Use as many E08-E13 codes as needed for all '
              'complications. Add Z79.4 (insulin), Z79.84 (oral hypoglycemics) and/or Z79.85 (injectable non-insulin) '
              'for long-term use; not Z79.4 for temporary insulin in a type 2 patient.',
         inputs=['diabetes codes', 'medications'], check='Warn when an E08-E13 code is present with documented insulin, '
              'oral or injectable antidiabetic use and no matching Z79 code.', severity='warning', settings=['all'],
         data=['rules/icd10cm_code_notes_<FY>.jsonl (E11 useAdditionalCode)'],
         implemented=IMPL('yes', [CODER, KC], r'addLongTermDrugCodes', 'Defaults to E11; ClinicalCoder adds Z79.4/Z79.84/Z79.85 for documented current use (not for temporary insulin); the scrubber suggests the Z79 group from the E08-E13 use-additional-code note when none is present.'),
         impact=3, hint='In ClinicalCoder add Z79.4/Z79.84/Z79.85 when the management regex matches insulin/oral agents.'),
    dict(id='CH9-HTN-01', title='Hypertension with heart disease: I11 plus the heart failure code',
         sources=[G('I.C.9.a'), G('I.C.9.a.1')],
         rule='The classification presumes a causal relationship between hypertension and heart involvement. '
              'Hypertension with heart conditions in I50.-, I51.4, I51.89 or I51.9 is coded to I11 with an additional '
              'I50/I51 code (I51.5 and I51.7 need no additional code), unless the provider documents they are unrelated.',
         inputs=['diagnosis codes'], check='Warn when I10 is on the claim with I50.-, I51.4-I51.7, I51.89 or I51.9.',
         severity='warning', severity_basis='guideline violation; affects risk adjustment and audits',
         settings=['all'], data=['guidelines/I.C.09_chapter-9-diseases-circulatory-system.md'],
         implemented=IMPL('yes', [CODER, SCRUB], r'combineHypertension\(', 'ClinicalCoder replaces I10 with I11.0 when heart failure is confirmed unless the physician says they are unrelated; ClaimScrubber.combinationIssues warns on hand-entered I10 with I50/I51.4-I51.7/I51.89/I51.9.'),
         impact=4, hint='In ClinicalCoder.finalizeDiagnoses replace I10 + I50.x by I11.0 + I50.x unless documentation says unrelated.'),
    dict(id='CH9-HTN-02', title='Hypertension with chronic kidney disease: I12 plus N18',
         sources=[G('I.C.9.a.2'), G('I.C.14.a')],
         rule='Hypertension with a condition in N18 is coded to I12 (presumed causal), with the N18 code as a secondary '
              'code for the stage, unless the provider says the CKD is not related.',
         inputs=['diagnosis codes'], check='Warn when I10 and N18.- are both on the claim.', severity='warning',
         settings=['all'], data=[], implemented=IMPL('yes', [CODER, SCRUB], r'I12\.9', 'ClinicalCoder codes CKD stages and uses I12.0/I12.9; the scrubber warns on I10 with N18.'), impact=4, hint='Same place as CH9-HTN-01.'),
    dict(id='CH9-HTN-03', title='Hypertension with heart disease and CKD: I13',
         sources=[G('I.C.9.a.3')],
         rule='Hypertension with both heart disease and CKD is coded to I13 (not I11 or I12), with N18 for the stage and '
              'I50 for heart failure when present.', inputs=['diagnosis codes'],
         check='Warn when I11 and I12 are both present, or I10 with both heart and CKD codes.', severity='warning',
         settings=['all'], data=[], implemented=IMPL('yes', [CODER, SCRUB], r'I13\.0', 'ClinicalCoder uses I13.0/I13.2 when both are confirmed; the scrubber warns on I10 with both, and on I11 with I12.'), impact=3, hint=''),
    dict(id='CH14-CKD-01', title='CKD stage and ESRD both documented: N18.6 only',
         sources=[G('I.C.14.a.1')], rule='If both a CKD stage and ESRD are documented, assign N18.6 only.',
         inputs=['diagnosis codes'], check='Warn when N18.6 and another N18 code are both present.', severity='warning',
         settings=['all'], data=[], implemented=IMPL('yes', [CODER, SCRUB], r'ESRD replaces the CKD stage', 'The coder keeps N18.6 only; the scrubber warns when N18.6 is reported with another N18 code.'), impact=2, hint=''),
    dict(id='CH15-OB-01', title='Pregnancy (Chapter 15) codes: maternal record only, maternity age 9-64',
         sources=[G('I.C.15.a.2'), M(4)],
         rule='Chapter 15 codes are used only on the maternal record, never on the newborn record. The MCE maternity '
              'age edit lists the codes (Chapter 15 and related Z/other codes) valid for ages 9 through 64.',
         inputs=['diagnosis codes', 'patient age', 'patient sex'], check='Error when a code in MCE list age_maternity is '
              'reported for an age outside 9-64 or for a newborn.', severity='error', settings=['all'],
         data=['rules/mce_edits_v44.json (age_maternity, 2,587 codes)'],
         implemented=IMPL('yes', [RULES_DART, SCRUB, 'lib/services/codesets/mce.dart'], r'mce\.ageFor\(', 'icdAgeRange uses the MCE v44 age_maternity list (2,587 codes); O codes 9-64 as fallback without the asset.'),
         impact=4, hint='Replace the O-prefix test in icdAgeRange with the MCE age_maternity list.'),
    dict(id='CH15-OB-02', title='Chapter 15 codes have sequencing priority; Z33.1 when pregnancy is incidental',
         sources=[G('I.C.15.a.1')],
         rule='Obstetric cases use Chapter 15 codes, which are sequenced before codes from other chapters; when the '
              'provider documents the pregnancy is incidental, Z33.1 replaces Chapter 15 codes.',
         inputs=['ordered diagnosis list'], check='Warn when an O code is present but not first-listed.',
         severity='warning', settings=['all'], data=[], implemented=IMPL('yes', [KC, CODER], r"'CH15-OB-02'", 'Warning when an O code is present but not first; finalizeDiagnoses ranks O codes first.'), impact=3, hint=''),
    dict(id='CH15-OB-03', title='Routine prenatal visit: Z34 first-listed and not with Chapter 15 codes',
         sources=[G('I.C.15.b.1'), G('IV.O')],
         rule='For routine outpatient prenatal visits without complications, a Z34 code is first-listed; Z34 codes are '
              'not used together with Chapter 15 codes.', inputs=['diagnosis codes'],
         check='Error when Z34.- and any O code are on the same claim; warn when Z34.- is not first.', severity='error',
         settings=['outpatient', 'professional'], data=[], implemented=IMPL('yes', [KC, RULES_DART], r"'CH15-OB-03'", 'Error when Z34 and an O code are reported together; Z34 not first is a CH21-Z-01 error.'), impact=3, hint=''),
    dict(id='CH15-OB-04', title='Weeks of gestation (Z3A) only on the maternal record, after the obstetric code',
         sources=[G('I.C.15.a.7'), T('codeFirst'), T('notes')],
         rule='Z3A codes indicate weeks of gestation, only on the maternal record; code first the obstetric condition.',
         inputs=['ordered diagnosis list'], check='Warn when Z3A is first-listed or used without an O code.',
         severity='warning', settings=['all'], data=['rules/icd10cm_code_notes_<FY>.jsonl (Z3A)'],
         implemented=IMPL('yes', [KC], r"'CH15-OB-04'", 'Warning when Z3A is first-listed or has no obstetric code.'), impact=2, hint=''),
    dict(id='CH16-PERI-01', title='Perinatal (Chapter 16) codes may be used after the perinatal period',
         sources=[G('I.C.16.a.4'), M(4)],
         rule='A condition that originates in the perinatal period and continues through life keeps its P code '
              'regardless of age. The MCE newborn age edit (age 0) applies only to its specific list of 42 codes '
              '(for example Z38, Z05, Z00.11-, A33), not to all P codes.',
         inputs=['diagnosis codes', 'patient age'], check='Age-0 error only for codes in MCE list age_newborn.',
         severity='error', settings=['all'], data=['rules/mce_edits_v44.json (age_newborn)'],
         implemented=IMPL('yes', [RULES_DART, SCRUB], r'isPerinatalCode\(', 'P codes are no longer age-limited; age-0 errors come only from the MCE age_newborn list, and a P code after age 0 gets a warning to confirm perinatal onset.'),
         impact=4, hint='Replace the P-prefix rule in icdAgeRange with the MCE age_newborn list.'),
    dict(id='CH19-INJ-01', title='Injury 7th characters: A active treatment, D healing phase, S sequela',
         sources=[G('I.C.19.a'), G('I.C.19.c.1')],
         rule='7th character A is for each encounter with active treatment, D for routine care during healing or '
              'recovery, S for sequelae. Fractures use their own initial (A/B/C), subsequent (D-H), nonunion (K/M/N), '
              'malunion (P/Q/R) and sequela (S) values. Aftercare Z codes are not used for injuries; use D instead.',
         inputs=['diagnosis codes', 'encounter type'], check='Warn on Z47/Z48 aftercare with a current injury; warn '
              'when a follow-up visit uses A.', severity='warning', settings=['all'],
         data=['rules/icd10cm_seventh_character_<FY>.json'],
         implemented=IMPL('yes', [CODER, KC], r'CH19-INJ-01', 'ClinicalCoder picks D when the injury was coded on an earlier visit and no active treatment is documented (CodingContext.priorDiagnosisCodes); warnings on Z47/Z48 aftercare with an injury and on A for an injury coded on an earlier visit.'),
         impact=3, hint='Pass newPatient/visit history into _withLaterality to choose A or D.'),
    dict(id='CH19-POIS-01', title='Poisoning, adverse effect and underdosing sequencing',
         sources=[G('I.C.19.e.5'), G('I.C.19.e.5.c')],
         rule='Poisoning: the T36-T65 poisoning code first, then the manifestations. Adverse effect of a correctly '
              'prescribed drug: the nature of the effect first, then the T36-T50 adverse-effect code. Underdosing codes '
              'are never principal or first-listed.', inputs=['ordered diagnosis list'],
         check='Error when an underdosing code (T36-T50 with 5th/6th character 6) is first-listed; warn when an '
               'adverse-effect code (character 5) is first-listed.', severity='error', settings=['all'], data=[],
         implemented=IMPL('yes', [KC], r"'CH19-POIS-01'", 'Error when underdosing (6th character 6) is first; warning when an adverse effect (5) is first or a poisoning code is not first.'), impact=3, hint=''),
    dict(id='CH21-Z-01', title='Z codes that may only be first-listed',
         sources=[G('I.C.21.c.15'), G('I.C.21.a')],
         rule='The listed Z codes/categories may only be reported as the principal/first-listed diagnosis, except when '
              'there are multiple encounters on the same day and the records are combined.',
         inputs=['ordered diagnosis list'], check='Error when a code in "official_list" (minus its exceptions) is not first.',
         severity='error', settings=['all'], data=['rule_catalog.json official_list'], implemented=IMPL('yes', [RULES_DART, SCRUB, CODER], r'firstListedOnlyZPrefixes', 'Const list with exceptions in code_rules.dart; error when one is not first; finalizeDiagnoses ranks them first.'), impact=4,
         hint='Generate a const list in code_rules.dart from official_list; check in ClaimScrubber.'),
    dict(id='CH21-Z-02', title='Status Z codes are not used when the diagnosis code already includes the status',
         sources=[G('I.C.21.c.3')],
         rule='A status code is not used with a body-system diagnosis code that already includes the status information '
              '(for example Z94.1 heart transplant status with T86.2- complications of heart transplant).',
         inputs=['diagnosis codes'], check='Warn on known redundant pairs.', severity='warning', settings=['all'], data=[],
         implemented=IMPL('yes', [KC], r"'CH21-Z-02'", 'Warning for Z94.- transplant status with the T86.- complication of the same organ, and Z93.- opening status with the Z43.- attention code (the guideline examples and their same-organ equivalents).'), impact=2, hint=''),

    # --- Medicare Code Editor --------------------------------------------------
    dict(id='MCE-AGE-01', title='Diagnosis age conflict (MCE edit 4)',
         sources=[M(4)],
         rule='A diagnosis on the MCE newborn (age 0), pediatric (0-17), maternity (9-64) or adult (15-124) list '
              'conflicts with a patient age outside that range.',
         inputs=['diagnosis codes', 'age on date of service'], check='Look up the code in the four MCE age lists.',
         severity='error', severity_basis='MCE edit for inpatient claims; outpatient editors apply equivalent age edits',
         settings=['all'], data=['rules/mce_edits_v44.json'],
         implemented=IMPL('yes', [RULES_DART, SCRUB, 'lib/services/codesets/mce.dart'], r'ReferenceData\.mce', 'icdAgeRange reads the four MCE v44 age lists from mce_v44.tsv.gz; a small hand-written fallback applies only when the asset is missing.'),
         impact=4, hint='Load the four MCE lists (3,612 codes) as a const map code -> [min,max] and use it in icdAgeRange.'),
    dict(id='MCE-SEX-01', title='Diagnosis sex conflict',
         sources=[M(5)],
         rule='The MCE sex conflict edit is deactivated as of 10/01/2024 (MCE v44 publishes no sex lists). Sex-specific '
              'diagnosis and procedure edits are still applied by many payers and by the outpatient code editor.',
         inputs=['diagnosis codes', 'patient sex'], check='Use a payer-configurable warning, not a hard error, unless the '
              'payer publishes a sex edit.', severity='warning', settings=['all'], data=[],
         implemented=IMPL('yes', [RULES_DART, SCRUB], r'enforceSexEdits', 'Payer-configurable: warning by default, error when the provider turns on enforceSexEdits for a payer that publishes a sex edit. MCE v44 publishes no sex lists, so the ranges follow the sex-specific Tabular chapters and categories.'),
         impact=2, hint='Keep provider.enforceSexEdits default off; cite the payer source when on.'),
    dict(id='MCE-UNACC-01', title='Unacceptable principal diagnosis (inpatient)',
         sources=[M(9)],
         rule='MCE edit 9 lists codes that describe circumstances rather than a current illness and are unacceptable '
              'as inpatient principal diagnosis (Z51.89 is acceptable when a secondary diagnosis is present).',
         inputs=['principal diagnosis', 'claim type'], check='Inpatient claims only: error when the principal diagnosis '
              'is on the list.', severity='error', settings=['inpatient'], data=['rules/mce_edits_v44.json'],
         implemented=IMPL('yes', [SCRUB, 'lib/services/codesets/mce.dart'], r'isUnacceptablePrincipal\(', 'Error on hospital inpatient visits; Z codes the guidelines allow first (I.C.21.c.15) and Z51.89 with a secondary diagnosis are exempt.'), impact=2, hint='Make it an error if the app ever builds inpatient institutional (837I) claims.'),

    # --- NCCI -------------------------------------------------------------------
    dict(id='NCCI-PTP-01', title='Procedure-to-procedure (unbundling) edits',
         sources=[N('I', 'A'), N('I', 'B'), N('I', 'C')],
         rule='When the same provider reports two codes of an NCCI PTP pair for the same beneficiary and date of '
              'service, the column two code is denied unless the edit allows an NCCI PTP-associated modifier and the '
              'clinical circumstances justify it. Component services integral to a comprehensive service are not '
              'reported separately.',
         inputs=['procedure codes', 'modifiers', 'same provider/patient/DOS'], check='Look up each ordered pair in the PTP '
              'table; deny column two unless modifier indicator 1 and an associated modifier is present.',
         severity='error', settings=['professional', 'outpatient'], data=['ptp_practitioner.tsv.gz (not bundled: AMA license gate)'],
         implemented=IMPL('partial', [SCRUB, PTP_DART], r'ptpIssues\(', 'ClaimScrubber.ptpIssues checks every line pair when ReferenceData.ptp is set, but the table is not bundled because CMS serves it behind the AMA CPT license click-through.'),
         impact=5, hint='Code is in place (ClaimScrubber.ptpIssues); bundle the table with --ship-ptp once the owner holds '
                        'an AMA CPT distribution license.'),
    dict(id='NCCI-MUTEX-01', title='Mutually exclusive procedures',
         sources=[N('I', 'P')],
         rule='Procedures that cannot reasonably be performed at the same anatomic site or encounter (for example two '
              'methods of the same repair, or "initial" and "subsequent" versions) are PTP pairs and are not paid together.',
         inputs=['procedure codes', 'modifiers'], check='Same PTP table lookup.', severity='error',
         settings=['professional', 'outpatient'], data=['ptp_practitioner.tsv.gz (not bundled)'],
         implemented=IMPL('partial', [SCRUB, PTP_DART], r'ptpIssues\(', 'Covered by ClaimScrubber.ptpIssues when the PTP table is available (not bundled).'),
         impact=4, hint='Same as NCCI-PTP-01.'),
    dict(id='NCCI-MOD-01', title='Only NCCI PTP-associated modifiers bypass a PTP edit, and only when the indicator allows',
         sources=[N('I', 'E')],
         rule='PTP-associated modifiers: anatomic (E1-E4, FA, F1-F9, TA, T1-T9, LT, RT, LC, LD, RC, LM, RI), global '
              'surgery (24, 25, 57, 58, 78, 79) and others (27, 59, 91, XE, XS, XP, XU). Modifier indicator 0 = no '
              'bypass; 1 = bypass allowed when clinically justified; 9 = not applicable. Modifiers 22, 76 and 77 do '
              'not bypass a PTP edit. A modifier is never added only to bypass an edit.',
         inputs=['procedure codes', 'modifiers', 'PTP modifier indicator'], check='When a PTP pair exists, accept the '
              'column two line only if indicator = 1 and one of the listed modifiers is present.', severity='error',
         settings=['professional', 'outpatient'], data=['rules/ncci_policy_manual_sections_2026.json'],
         implemented=IMPL('yes', [SCRUB], r'ncciModifiers', 'ClaimScrubber.ncciModifiers; modifier indicator 0 never bypasses, 1 needs one of the listed modifiers. Applies when the PTP table is available.'), impact=4, hint='Put the modifier list in a Dart const next to Ptp.modifierAllowed.'),
    dict(id='NCCI-MOD-02', title='Modifier 59 and X{EPSU}: separate encounter, structure, practitioner or non-overlapping service',
         sources=[N('I', 'E')],
         rule='Modifier 59 is used only when no more descriptive modifier applies; XE, XS, XP, XU are preferred where '
              'they fit. It is not appended to E/M services (use 25). Different diagnoses alone do not justify 59/XS; '
              'the procedures must be at different anatomic sites or separate encounters. Not used with 77427.',
         inputs=['modifiers', 'procedure codes', 'documentation'], check='Error on 59/X modifiers on an E/M code; warn '
              'on 59 when an X modifier fits.', severity='warning', settings=['professional', 'outpatient'], data=[],
         implemented=IMPL('yes', [KC], r"'NCCI-MOD-02'", 'Error on 59/XE/XS/XP/XU on an E/M code and on 59 with 77427; warning on 59 without an X modifier.'), impact=3, hint='Add modifier validation per line in ClaimScrubber using emSettingOf().'),
    dict(id='NCCI-EM-01', title='E/M on the day of a minor procedure (global 000/010) needs modifier 25 and a separate service',
         sources=[N('I', 'D'), N('I', 'E')],
         rule='E/M services on the same day as a minor surgical procedure (global 000 or 010) are included, including '
              'the decision to perform it, unless a significant, separately identifiable E/M service is performed, '
              'reported with modifier 25. Different diagnoses are not required. Being a new patient alone does not '
              'justify it.', inputs=['E/M line', 'procedure lines', 'PFS global days', 'modifiers'],
         check='When an E/M line and a procedure with global 000/010 share the DOS, require modifier 25 on the E/M '
               'and documentation of the separate service.', severity='error', settings=['professional'],
         data=['assets/codes/pfs_rvu.tsv.gz (global days)'], implemented=IMPL('yes', [SCRUB, FEES], r'E/M needs modifier 25', 'Error when an E/M without modifier 25 is billed with a 000/010 global procedure. The coder does not add 25 itself: the physician decides whether the E/M was separately identifiable.'), impact=5,
         hint='FeeSchedule.lookup(code).globalDays is already loaded; add the check in ClaimScrubber and default '
              'modifier 25 in ClinicalCoder when a separate E/M is documented.'),
    dict(id='NCCI-EM-02', title='E/M on the day before or of a major procedure (global 090): modifier 57 for the decision',
         sources=[N('I', 'D')],
         rule='For a major procedure (global 090), an E/M on the same day to decide to perform the surgery is separately '
              'reportable with modifier 57; other preoperative E/M services that day are included. MACs, not NCCI, '
              'edit this.', inputs=['E/M line', 'procedure global days', 'modifiers'],
         check='Warn when an E/M and a 090 procedure share the DOS without modifier 57.', severity='warning',
         settings=['professional'], data=['assets/codes/pfs_rvu.tsv.gz'], implemented=IMPL('yes', [KC, FEES], r"'NCCI-EM-02'", 'Warning when an E/M without 57 is billed on the day of a 090 procedure, or the day before one recorded on the next visit.'), impact=3, hint=''),
    dict(id='NCCI-EM-03', title='E/M with XXX procedures',
         sources=[N('I', 'D')],
         rule='Global indicator XXX procedures are outside global surgery rules, but their inherent pre/post work, '
              'supervision and interpretation are not reported as E/M; a significant, separately identifiable E/M may '
              'be reported with modifier 25.', inputs=['E/M line', 'procedure global days'],
         check='Warn when an E/M and an XXX procedure with physician work share the DOS without modifier 25.',
         severity='warning', settings=['professional'], data=['assets/codes/pfs_rvu.tsv.gz'], implemented=IMPL('yes', [KC, FEES], r"'NCCI-EM-03'", 'Warning when an E/M without 25 is billed with an XXX procedure that has work RVUs and PC/TC indicator 0 or 5 (diagnostic tests excluded); pfs_rvu.tsv.gz keeps the work RVU and PC/TC columns.'),
         impact=3, hint=''),
    dict(id='NCCI-GLOBAL-01', title='Postoperative visits in the global period',
         sources=[N('I', 'D')],
         rule='E/M services related to recovery from surgery, including complications, are included in the global '
              'package; unrelated E/M services during the postoperative period are reported with modifier 24.',
         inputs=['prior procedures with global days and dates', 'E/M line'], check='Warn when an E/M falls inside the '
              'global period of a prior procedure by the same provider without modifier 24.', severity='warning',
         settings=['professional'], data=['assets/codes/pfs_rvu.tsv.gz'], implemented=IMPL('yes', [KC, FEES], r"'NCCI-GLOBAL-01'", 'Warning when an E/M without 24 falls within 10 or 90 days after a 010/090 procedure billed on an earlier visit of the patient account.'), impact=3,
         hint='Needs the patient account visit history (PatientAccount.visits) with billed procedures.'),
    dict(id='NCCI-ADDON-01', title='Add-on codes require an acceptable primary code',
         sources=[N('I', 'R'), N('I', 'W')],
         rule='An add-on code is reported only with its primary procedure. Type 1: only the listed primary codes; '
              'Type 2: the MAC defines primaries; Type 3: listed primaries plus MAC-defined. If the primary is denied, '
              'the add-on is not paid.', inputs=['procedure codes on the claim'],
         check='For each add-on code in the AOC file, require one of its primary codes on the same claim/DOS (type 1 '
               'error, types 2/3 warning).', severity='error', settings=['professional', 'outpatient'],
         data=['rules/ncci_addon_code_edits_<quarter>.tsv'], implemented=IMPL('yes', [SCRUB, 'lib/services/codesets/addon_codes.dart'], r'addOnIssues\(', 'ncci_addon.tsv.gz; type 1 error, type 3 warning; type 2 primaries are contractor-defined and cannot be checked.'), impact=4,
         hint='Bundle the AOC TSV as an asset (bare codes), load it in ReferenceData, and check in ClaimScrubber.'),
    dict(id='NCCI-MUE-01', title='Medically unlikely edits: units per line (MAI 1)',
         sources=[N('I', 'V')],
         rule='Units of service above the MUE value for a code on one claim line are denied (MAI 1 = claim line edit).',
         inputs=['code', 'units'], check='units <= MUE value.', severity='error', settings=['professional', 'outpatient'],
         data=['assets/codes/mue_practitioner.tsv.gz'], implemented=IMPL('yes', [SCRUB, MUE_DART], r'maxUnits\('),
         impact=5, hint=''),
    dict(id='NCCI-MUE-02', title='Medically unlikely edits: date-of-service totals (MAI 2 and 3)',
         sources=[N('I', 'V')],
         rule='For MAI 2 (policy) and MAI 3 (clinical) edits, units for the same code on all lines for the date of '
              'service are summed and compared with the MUE; all units are denied if exceeded. MAI 2 denials cannot be '
              'overridden on appeal.', inputs=['all lines with the same code and DOS'],
         check='Sum units by code across lines before comparing when adjudicationIndicator is 2 or 3.', severity='error',
         settings=['professional', 'outpatient'], data=['assets/codes/mue_practitioner.tsv.gz'],
         implemented=IMPL('yes', [SCRUB, MUE_DART], r'unitsByCode', 'Units of the same code are summed across lines when the MAI is 2 or 3.'),
         impact=4, hint='Group claim.lines by code and compare the sum when Mue.adjudicationIndicator(code) is 2 or 3.'),
    dict(id='NCCI-MUE-03', title='Bilateral procedures: units and modifier 50 follow the PFS bilateral indicator',
         sources=[N('I', 'V')],
         rule='With bilateral indicator 1 or 3 a bilateral surgical procedure is one unit with modifier 50; indicator 0 '
              'or 2 is one unit without 50 (see the manual for diagnostic procedures with RT/LT lines).',
         inputs=['code', 'modifiers', 'units', 'PFS bilateral indicator'], check='Units and modifiers consistent with '
              'the indicator.', severity='warning', settings=['professional'], data=['assets/codes/pfs_rvu.tsv.gz (bilateral surgery indicator)'],
         implemented=IMPL('yes', [KC, FEES], r"'NCCI-MUE-03'", 'pfs_rvu.tsv.gz keeps the bilateral surgery indicator: warnings on modifier 50 with indicator 0/2/9, on 50 with more than one unit, on indicator 2 with more than one unit, and on indicator 1 codes billed as RT and LT lines.'), impact=3, hint='Keep the BILAT SURG column when building pfs_rvu.tsv.gz.'),
    dict(id='NCCI-LAB-01', title='Laboratory panels and repeat tests',
         sources=[N('I', 'N'), N('X', 'C')],
         rule='When all tests of an organ or disease panel are performed, report the panel code; a medically necessary '
              'repeat of a component test on the same day is reported with modifier 91.', inputs=['lab codes', 'modifiers'],
         check='Warn when all components of a panel are billed separately.', severity='warning',
         settings=['professional', 'outpatient'], data=[], implemented=IMPL('partial', [KC, SCRUB], r"'NCCI-LAB-01'", 'Repeat tests: warning when a lab code is repeated without modifier 91. Panel composition is CPT (AMA) content, so panels are enforced only through ptpIssues when the PTP table is loaded.'), impact=2, hint=''),
    dict(id='NCCI-FAMILY-01', title='Report the most comprehensive code; a code means all its components were done',
         sources=[N('I', 'H'), N('I', 'K'), N('I', 'L')],
         rule='A code is reported only if all services it describes were performed; report the most comprehensive '
              'code that describes the services rather than component codes; a more extensive and a less extensive '
              'version of the same procedure are not reported together.', inputs=['procedure codes'],
         check='Mostly enforced through PTP pairs.', severity='warning', settings=['professional', 'outpatient'],
         data=[], implemented=IMPL('partial', [SCRUB, PTP_DART], r'ptpIssues\(', 'Enforced through ClaimScrubber.ptpIssues (comprehensive/component and more/less extensive pairs) whenever the NCCI PTP table is loaded; the table is not bundled (AMA CPT license).'), impact=2, hint=''),
]


def resolve_secondary_only(titles: dict, gl_dir: Path) -> list:
    """Codes named by concept in Guideline I.B.14, resolved against Tabular titles."""
    concepts = [
        ('BMI', r'^Body mass index \[BMI\]'),
        ('coma scale', r'coma scale'),
        ('NIHSS', r'National Institutes of Health Stroke Scale'),
        ('blood alcohol level', r'blood alcohol level'),
        ('underimmunization status', r'^Underimmunization status'),
    ]
    out = []
    for concept, rx in concepts:
        hits = sorted(c for c, t in titles.items() if re.search(rx, t, re.I))
        tops = [c for c in hits if not any(c != h and c.startswith(h) for h in hits)]
        out.append({'concept': concept, 'codes': tops, 'titles': [titles[c] for c in tops],
                    'resolved_from': 'Tabular List titles'})
    # SDOH categories are listed explicitly in Guideline I.C.21.c.17
    sdoh = []
    f = next(gl_dir.glob('I.C.21_*.md'))
    text = f.read_text(encoding='utf-8')
    sec = text.split('[I.C.21.c.17]', 1)[1]
    for m in re.finditer(r'^- (Z\d\d) ', sec, re.M):
        sdoh.append(m.group(1))
    out.append({'concept': 'social determinants of health', 'codes': sdoh,
                'titles': [titles.get(c, '') for c in sdoh], 'resolved_from': 'Guideline I.C.21.c.17 list'})
    return out


def parse_first_listed_z(gl_dir: Path, titles: dict) -> list:
    f = next(gl_dir.glob('I.C.21_*.md'))
    sec = f.read_text(encoding='utf-8').split('[I.C.21.c.15]', 1)[1].split('\n#', 1)[0]
    items = []
    for ln in sec.splitlines():
        m = re.match(r'^- (Z\d\d(?:\.[0-9A-Z]{1,4})?-?) (.*)$', ln)
        if m:
            items.append({'code': m.group(1), 'title': m.group(2).strip(), 'except': []})
            continue
        m = re.match(r'^Except:\s*(Z\d\d(?:\.[0-9A-Z]{1,4})?)', ln)
        if m and items:
            items[-1]['except'].append(m.group(1))
    return items


def build_catalog(out: Path, gl_index: dict, ncci: dict, mce: dict, titles: dict, aoc_info: dict) -> dict:
    sections = gl_index['sections']
    ncci_secs = {f'{c["chapter"]}.{s["section"]}': s['title'] for c in ncci['chapters'] for s in c['sections']}
    mce_edits = {e['number']: e for e in mce['edits']}
    problems = []
    rules = []
    fy = EDITION['icd_fy']
    for r in RULES:
        r = json.loads(json.dumps(r))  # copy
        for s in r['sources']:
            if s['type'] == 'guideline':
                sec = sections.get(s['ref'])
                if not sec:
                    problems.append(f'{r["id"]}: guideline section {s["ref"]} not found')
                    continue
                s['citation'] = f'ICD-10-CM Official Guidelines FY{fy}, Section {s["ref"]}'
                s['title'] = sec['title']
                s['file'] = 'guidelines/' + sec['file']
            elif s['type'] == 'ncci_manual':
                t = ncci_secs.get(s['ref'])
                if not t:
                    problems.append(f'{r["id"]}: NCCI section {s["ref"]} not found')
                    continue
                ch, sc = s['ref'].split('.')
                s['citation'] = f'Medicare NCCI Policy Manual {EDITION["ncci_year"]}, Chapter {ch}, Section {sc}'
                s['title'] = t
            elif s['type'] == 'mce':
                e = mce_edits.get(s['ref'])
                if not e:
                    problems.append(f'{r["id"]}: MCE edit {s["ref"]} not found')
                    continue
                s['citation'] = f'Definitions of Medicare Code Edits v{EDITION["mce_version"]}.0, edit {s["ref"]}'
                s['title'] = e['title']
                s['status'] = e['status']
            elif s['type'] == 'tabular_note':
                s['citation'] = f'ICD-10-CM Tabular List FY{fy}, "{s["ref"]}" instructional notes'
        r['data'] = [d.replace('<FY>', str(fy)).replace('<quarter>', aoc_info.get('file', '').replace(
            'ncci_addon_code_edits_', '').replace('.tsv', '')) for d in r['data']]
        imp = r['implemented']
        found = []
        if imp.get('evidence') and imp['files']:
            for f in imp['files']:
                p = ROOT / f
                if p.exists() and re.search(imp['evidence'], p.read_text(encoding='utf-8')):
                    found.append(f)
            if not found:
                problems.append(f'{r["id"]}: implementation evidence /{imp["evidence"]}/ not found in {imp["files"]}')
        imp['evidence_found_in'] = found
        if r['id'] == 'CH21-Z-01':
            r['official_list'] = parse_first_listed_z(OUT / 'guidelines', titles)
        if r['id'] == 'ICD-SECONDARY-ONLY-01':
            r['official_list'] = resolve_secondary_only(titles, OUT / 'guidelines')
        r.setdefault('severity_basis', {'error': 'claim edit rejection or denial expected',
                                        'warning': 'coding-guideline violation or payer-specific edit; review',
                                        'info': 'guidance'}[r['severity']])
        rules.append(r)
    counts = collections.Counter(r['implemented']['status'] for r in rules)
    catalog = {
        'version': f'FY{fy} ICD-10-CM / MCE v{EDITION["mce_version"]} / NCCI manual {EDITION["ncci_year"]}',
        'severity_levels': {'error': 'claim is expected to reject or deny', 'warning': 'review: guideline violation, '
                            'audit risk or payer-specific edit', 'info': 'guidance'},
        'implemented_levels': {'yes': 'enforced in the app', 'partial': 'partly enforced or heuristic',
                               'no': 'not enforced'},
        'counts': {'rules': len(rules), 'implemented': dict(counts)},
        'rules': rules,
    }
    write_json(out / 'rules' / 'rule_catalog.json', catalog)
    return {'catalog': catalog, 'problems': problems}


HINTS = {
    'ICD-SYMPTOM-02': 'Promote the scrubber info to a warning when dx.first is R00-R99 and a confirmed diagnosis is present.',
    'OP-FIRSTLISTED-01': 'Keep the finalizeDiagnoses ranking; let the physician pin the first-listed code (pinnedOrder exists).',
    'ICD-EXTCAUSE-02': 'Count Y92/Y99 codes in ClaimScrubber; warn on duplicates and on Y92.9/Y99.9.',
    'OP-DIAGSERVICES-01': 'Workflow hint in the encounter screen when a test interpretation is signed.',
    'OP-PREOP-01': 'When the visit reason is pre-op, prepend Z01.81- in ClinicalCoder.finalizeDiagnoses.',
    'OP-THERAPY-01': 'When chemo/radiation administration lines are billed, require Z51.0/Z51.1- first.',
    'CH1-SEPSIS-01': 'Error in ClaimScrubber when dx.first starts with R65.2 (MCE unacceptable principal list).',
    'CH2-NEO-01': 'Warn when C-code and Z85 code of the same site are both present.',
    'CH2-NEO-02': 'Warn when dx.first is R00-R99 and any C00-C96 code is present.',
    'CH9-HTN-03': 'Extend the CH9-HTN-01 replacement to I13.x when both heart and CKD codes are present.',
    'CH14-CKD-01': 'Drop other N18 codes when N18.6 is present (finalizeDiagnoses).',
    'CH15-OB-02': 'Rank O codes first in finalizeDiagnoses.',
    'CH15-OB-03': 'Error in ClaimScrubber when Z34.- and any O code are both present.',
    'CH15-OB-04': 'Warn when Z3A is first-listed or present without an O code.',
    'CH19-POIS-01': 'Use the 6th character of T36-T50 codes (5 = adverse effect, 6 = underdosing) to check position.',
    'CH21-Z-02': 'Start with the pairs named in the guideline (Z94.1 with T86.2-); extend from Excludes1 notes.',
    'NCCI-EM-02': 'Use FeeSchedule.globalDays == "090" in ClaimScrubber to suggest modifier 57.',
    'NCCI-EM-03': 'Use FeeSchedule.globalDays == "XXX" and work RVU > 0 to require modifier 25 on the E/M.',
    'NCCI-LAB-01': 'Needs a panel-to-component map; panel definitions are AMA CPT content, so rely on PTP edits.',
    'NCCI-FAMILY-01': 'Covered by PTP edits once the PTP table is available.',
}


# ---------------------------------------------------------------------------
# 7. Reports: build_report.json, GAP_REPORT.md, README.md
# ---------------------------------------------------------------------------

def write_gap_report(out: Path, catalog: dict):
    sev_rank = {'error': 0, 'warning': 1, 'info': 2}
    gaps = [r for r in catalog['rules'] if r['implemented']['status'] != 'yes']
    gaps.sort(key=lambda r: (-r['impact'], sev_rank[r['severity']], r['implemented']['status'] == 'partial', r['id']))
    lines = [
        '# Gap report: coding rules the app does not fully enforce',
        '',
        f'Generated by `tool/build_knowledge_base.py` from `rules/rule_catalog.json` ({catalog["version"]}).',
        'Ranked by claim-denial impact (5 = front-end rejection or certain denial, 1 = informational), then',
        'severity. "partial" rules are listed after "no" rules of the same impact. Each line ends with how to',
        'implement it in the existing Dart code (`lib/services/coding/`, `lib/services/codesets/`).',
        '',
        f'Totals: {catalog["counts"]["rules"]} rules; implemented yes {catalog["counts"]["implemented"].get("yes", 0)}, '
        f'partial {catalog["counts"]["implemented"].get("partial", 0)}, no {catalog["counts"]["implemented"].get("no", 0)}.',
        '',
        '| Rank | Rule | Impact | Severity | Status | Source | Suggestion |',
        '|---:|---|---:|---|---|---|---|',
    ]
    for i, r in enumerate(gaps, 1):
        src = '; '.join(s.get('citation', s['ref']).replace('ICD-10-CM Official Guidelines FY2027, Section ', 'Guidelines ')
                        .replace('Medicare NCCI Policy Manual 2026, ', 'NCCI ')
                        .replace('Definitions of Medicare Code Edits v44.0, ', 'MCE ')
                        .replace('ICD-10-CM Tabular List FY2027, ', 'Tabular ') for s in r['sources'])
        hint = r.get('hint') or HINTS.get(r['id'], '')
        status = r['implemented']['status']
        if r['implemented'].get('note') and status != 'no':
            status += ' (' + re.split(r'\.(?:\s|$)', r['implemented']['note'])[0] + ')'
        lines.append(f'| {i} | **{r["id"]}** {r["title"]} | {r["impact"]} | {r["severity"]} | {status} | {src} | {hint} |')
    lines += ['', 'Notes', '',
              '- PTP and mutually exclusive checks (NCCI-PTP-01, NCCI-MUTEX-01) run in `ClaimScrubber.ptpIssues` only '
              'when the NCCI PTP table is available, which CMS serves only after the AMA CPT license click-through. '
              'Bundling it in the app needs an AMA CPT distribution license (see `assets/codes/SOURCES.md`).',
              '- NCCI-FAMILY-01 and the panel part of NCCI-LAB-01 depend on the same PTP table (panel components are CPT '
              'content); the repeat-test part of NCCI-LAB-01 (modifier 91) is enforced.',
              '- The coding checks read assets built from this folder by `python -I tool/build_code_assets.py --knowledge-only`: '
              '`icd10cm_excludes1_2027.tsv.gz`, `icd_7th_2027.tsv.gz`, `mce_v44.tsv.gz` (with the edit 20 unspecified-laterality list), '
              '`ncci_addon.tsv.gz`, `icd_notes_2027.tsv.gz` (code first, use additional code, code also, Excludes1/2 per code), '
              '`guidelines_fy2027.tsv.gz` and `rule_catalog.tsv.gz` (the "Why" explanations). Each check is skipped when its asset is not loaded.',
              '']
    (out / 'GAP_REPORT.md').write_text('\n'.join(lines), encoding='utf-8', newline='\n')
    return gaps


def write_readme(out: Path, report: dict):
    fy = EDITION['icd_fy']
    s = report
    gl = s['guidelines']
    tab = s['tabular']
    files_table = '\n'.join(f'| `{f}` | {sz:,} |' for f, sz in s['files']
                            if f not in ('README.md', 'build_report.json'))
    text = f'''# SOLIS coding knowledge base

Machine-readable medical coding rules for agents and for the SOLIS claim scrubber, built only from
public-domain US government sources (CMS and NCHS). Everything here is generated by
`tool/build_knowledge_base.py`; do not edit generated files by hand.

## What is here

| Path | What it is |
|---|---|
| `guidelines/*.md` | ICD-10-CM Official Guidelines for Coding and Reporting FY{fy}, one file per section (I.A, I.B, each I.C chapter, II, III, IV, Appendix I POA). Every heading carries its official id in brackets, e.g. `### [IV.H] H. Uncertain diagnosis`. |
| `guidelines/index.json` | `sections`: every guideline id -> file, title, page, keywords. `files`: per file title, pages, keywords, ICD categories mentioned. `extraction_check`: word/character comparison with the PDF. |
| `rules/icd10cm_code_notes_{fy}.jsonl` | One JSON object per Tabular List node (chapter, block, category, subcategory, code) that has instructional notes: inclusion terms, includes, Excludes1, Excludes2, code first, use additional code, code also, notes, 7th character note and values, placeholder flag, billable flag, parsed code `refs`, the `parents` chain and `inherited` (which ancestors carry each note type). |
| `rules/icd10cm_chapters_{fy}.json` | The 22 chapters: range, title, chapter-level notes, and their blocks (id, first, last, title). |
| `rules/icd10cm_excludes1_{fy}.tsv` | Flattened Excludes1 pairs: code, excluded reference. |
| `rules/icd10cm_seventh_character_{fy}.json` | 7th character definitions by code prefix. |
| `rules/mce_edits_v{EDITION["mce_version"]}.json` | Medicare Code Editor v{EDITION["mce_version"]} edit list with status, and code lists: newborn/pediatric/maternity/adult age, manifestation-not-principal, questionable admission, unacceptable principal, wrong procedure, unspecified-laterality. |
| `rules/ncci_policy_manual_sections_{EDITION["ncci_year"]}.json` | Chapter and section index of the Medicare NCCI Policy Manual {EDITION["ncci_year"]} (titles and pages, for citations). |
| `rules/ncci_addon_code_edits_*.tsv` | NCCI add-on code edits (add-on code, primary code, type), bare code numbers as CMS publishes them. |
| `rules/rule_catalog.json` | The coding rules to enforce: id, sources with citations, plain-English rule, inputs, check, severity, data files, app implementation status (yes/partial/no, with the Dart file and an evidence pattern checked at build time), impact and implementation hint. |
| `GAP_REPORT.md` | Rules the app does not yet enforce, ranked by claim-denial impact. |
| `build_report.json` | Counts, extraction check, citation check, implementation evidence check. |

Files and sizes (bytes):

| File | Size |
|---|---:|
{files_table}

## Sources

| Source | Publisher | Release | URL |
|---|---|---|---|
| ICD-10-CM Official Guidelines for Coding and Reporting FY{fy} | CMS and NCHS | FY{fy}, effective October 1, 2026 - September 30, 2027 (PDF created June 8, 2026) | {SOURCES["guidelines"]["url"]} |
| ICD-10-CM {fy} Code Tables, Tabular and Index (XML) | CMS / NCHS | FY{fy} | {SOURCES["tabular"]["url"]} |
| ICD-10-CM {fy} Code Descriptions in Tabular Order (billable flags) | CMS / NCHS | FY{fy} | {SOURCES["order"]["url"]} |
| ICD-10-CM {fy} Addendum (change pages, PDF; downloaded for reference, not parsed) | CMS / NCHS | FY{fy} | {SOURCES["addendum"]["url"]} |
| Definitions of Medicare Code Edits v{EDITION["mce_version"]}.0 | CMS | October 2026 (FY{fy} final rule) | {SOURCES["mce"]["url"]} |
| Medicare NCCI Policy Manual {EDITION["ncci_year"]}, all chapters | CMS | effective January 1, 2026, posted December 24, 2025 | {SOURCES["ncci_manual"]["url"]} |
| NCCI Add-on Code Edits, Medicare | CMS | effective October 1, 2026, posted September 1, 2026 | {SOURCES["aoc"]["url"]} |

Pages: https://www.cms.gov/medicare/coding-billing/icd-10-codes ,
https://www.cms.gov/medicare/payment/prospective-payment-systems/acute-inpatient-pps/ms-drg-classifications-and-software ,
https://www.cms.gov/medicare/coding-billing/national-correct-coding-initiative-ncci-edits/medicare-ncci-policy-manual ,
https://www.cms.gov/medicare/coding-billing/national-correct-coding-initiative-ncci-edits/medicare-ncci-add-code-edits

Not included: the NCCI procedure-to-procedure (PTP) tables. CMS serves them only after the AMA CPT
license click-through (`cms.gov/license/ama?...`), which this build does not accept. The NCCI Policy
Manual and the add-on code file downloaded directly without a license page. The NCCI manual text is
not copied (it quotes CPT descriptors); only its section titles are indexed. No CPT descriptor or AMA
guideline text appears anywhere in this folder; CPT codes appear only as bare numbers in the add-on
code file and in NCCI citations, as CMS publishes them.

## How an agent should query it

1. Guideline question ("can I code a probable diagnosis in the office?"): search `guidelines/index.json`
   `sections` by keywords, open the file, jump to the bracketed id (`[IV.H]`). Cite as
   "ICD-10-CM Official Guidelines FY{fy}, Section IV.H".
2. Notes for a code, e.g. `E11.42`: grep `rules/icd10cm_code_notes_{fy}.jsonl` for `"code":"E11.42"`.
   Notes are inherited down the hierarchy, so also read every ancestor: strip one character at a time
   (`E11.4`, `E11`), then the block (`"section"` field, e.g. `E08-E13`) and `chapter-4`. Each record's
   `parents` lists that chain and `inherited` names the ancestors that carry each note type. A code
   with no record of its own simply has no own notes; walk its prefixes.
3. Excludes1 conflict between two codes: for each code and its ancestors, test the other code against
   the refs in `icd10cm_excludes1_{fy}.tsv` (or `refs.excludes1` in the JSONL). Ref forms: `E11.9`
   exact code and its children; `O24.-` or `E10.1-` any code starting with that prefix; `E10-E13`
   inclusive range compared on the leading characters. 148 Excludes1 notes have no code reference
   (for example "see body system chapters"); read their text.
4. 7th character: longest matching prefix in `icd10cm_seventh_character_{fy}.json`; pad with `X` to six
   characters first.
5. Is a code billable? `billable` in the JSONL (from the order file); for codes without notes use
   `assets/codes/icd10cm_{fy}.tsv.gz`.
6. Claim checks: iterate `rules/rule_catalog.json` `rules`; each has `inputs`, `check`, `severity`,
   `data` and `sources[].citation`. `official_list` holds lists extracted from the guidelines
   (first-listed-only Z codes, secondary-only codes).
7. Age edits and manifestation codes: `rules/mce_edits_v{EDITION["mce_version"]}.json` `lists`. Note the scope
   field: the MCE is an inpatient editor; its sex edit is deactivated since 10/01/2024.

## How to rebuild

    python -P tool/build_knowledge_base.py            # downloads missing sources to %TEMP%/solis_codesets
    python -P tool/build_knowledge_base.py --offline  # reuse downloads

Requires Python 3.9+ and PyMuPDF (`pip install pymupdf`). Downloads stay outside the repository
(`%TEMP%/solis_codesets/icd` and `.../kb`). For FY2028: update `EDITION` and the URLs in `SOURCES`
at the top of the script, rerun, then read `build_report.json`: `citation_problems` lists rules whose
guideline section ids moved, and `implementation_evidence` flags Dart code that changed.

## Counts (this build)

- Guidelines: {len(gl["files"])} Markdown files, {gl["extraction_check"]["bookmarks"]} headings with official ids.
- Tabular notes: {tab["records_total"]:,} records ({tab.get("records_chapter", 0)} chapters, {tab.get("records_section", 0)} blocks,
  {tab.get("records_category", 0):,} categories, {tab.get("records_subcategory", 0):,} subcategories, {tab.get("records_code", 0):,} codes);
  {tab["excludes1_notes"]:,} Excludes1 notes giving {tab["excludes1_pairs"]:,} code-reference pairs on {tab["codes_with_excludes1_pairs"]:,} codes;
  {tab["seventh_character_prefixes"]} 7th-character definitions covering {tab["billable_codes_with_7th_character"]:,} billable codes;
  {tab.get("placeholder_flagged", 0)} nodes flagged placeholder.
- Rule catalog: {s["catalog"]["rules"]} rules; implemented yes {s["catalog"]["implemented"].get("yes", 0)},
  partial {s["catalog"]["implemented"].get("partial", 0)}, no {s["catalog"]["implemented"].get("no", 0)}.

Extraction check (guidelines PDF vs Markdown): PDF {gl["extraction_check"]["pdf_pages"]} pages,
{gl["extraction_check"]["pdf_words_all_pages"]:,} words in total; excluded the table of contents (pages
{gl["extraction_check"]["excluded_table_of_contents_pages"]}, {gl["extraction_check"]["excluded_table_of_contents_words"]:,} words) and running
footers ({gl["extraction_check"]["excluded_running_header_words"]:,} words). Body: PDF {gl["extraction_check"]["pdf_words_body"]:,} words vs Markdown
{gl["extraction_check"]["markdown_words_body"]:,} words (difference {gl["extraction_check"]["word_difference"]}, from words split by a line-end
hyphen that were joined); alphanumeric characters PDF {gl["extraction_check"]["pdf_alphanumeric_chars_body"]:,} vs Markdown
{gl["extraction_check"]["markdown_alphanumeric_chars_body"]:,} (difference {gl["extraction_check"]["alphanumeric_difference"]}); PDF lines not found in the
output: {gl["extraction_check"]["pdf_lines_not_found_in_output"]}. Bold/underline/italic change marks in the PDF are not preserved.

## Official sources vs scanned books

| | Official CMS/NCHS files (this folder) | Scanned commercial books (AAPC ICD-10-CM 2025, AMA CPT 2025) |
|---|---|---|
| Currency | FY{fy} ICD-10-CM (October 1, 2026), MCE v{EDITION["mce_version"]}, NCCI manual 2026, add-on edits October 2026 | FY2025 ICD-10-CM (two editions behind; codes added in FY2026/FY2027 missing, deleted codes still present); CPT 2025 |
| Format | XML (Tabular), fixed-width text (billable flags, add-on edits), text-layer PDF (guidelines): exact characters, no OCR | Page scans: OCR needed, error-prone on codes (0/O, 1/l, 5/S), tables and indentation lose structure |
| Structure | Notes typed by kind (Excludes1, code first...), hierarchy explicit, guideline ids as headings | Notes inferred from typography and layout |
| Licensing | Public domain (US Government works); may be redistributed in the app | Copyrighted (AAPC, AMA); cannot be copied into the app or this knowledge base |
| Update cadence | ICD-10-CM yearly (October 1) plus occasional April 1 updates; MCE with each MS-DRG version; NCCI manual yearly (January 1); add-on and MUE files quarterly | New purchase each year; rescan and re-OCR |
| CPT | Not available as text from CMS; descriptors need an AMA license either way | Same: CPT requires an AMA license whether scanned or licensed electronically |

Rebuilding from the official files is reproducible and auditable; nothing here depends on the books.
'''
    (out / 'README.md').write_text(text, encoding='utf-8', newline='\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--downloads', type=Path, default=DEFAULT_DOWNLOADS)
    ap.add_argument('--offline', action='store_true', help='do not download; use files already in --downloads')
    ap.add_argument('--out', type=Path, default=OUT)
    args = ap.parse_args()
    dl = args.downloads.resolve()
    out = args.out.resolve()
    if ROOT in dl.parents or dl == ROOT:
        raise SystemExit('downloads must stay outside the repository')
    paths = ensure_sources(dl, args.offline)
    (out / 'rules').mkdir(parents=True, exist_ok=True)

    print('guidelines ...')
    gl = build_guidelines(paths['guidelines'], out / 'guidelines')
    print('tabular ...')
    order = load_order(paths['order'], SOURCES['order']['member'])
    tab = build_tabular(paths['tabular'], SOURCES['tabular']['member'], order, out / 'rules', EDITION['icd_fy'])
    print('MCE ...')
    mce = build_mce(paths['mce'], out / 'rules')
    print('NCCI manual ...')
    ncci = build_ncci_index(paths['ncci_manual'], out / 'rules')
    aoc = {}
    if 'aoc' in paths:
        print('add-on code edits ...')
        for old in (out / 'rules').glob('ncci_addon_code_edits_*.tsv'):
            old.unlink()
        aoc = build_aoc(paths['aoc'], out / 'rules', as_of=f'{EDITION["icd_fy"] - 1}-10-01')
    print('rule catalog ...')
    cat = build_catalog(out, gl, ncci, mce, tab['titles'], aoc)
    for r in cat['catalog']['rules']:
        if not r.get('hint'):
            r['hint'] = HINTS.get(r['id'], '')
    write_json(out / 'rules' / 'rule_catalog.json', cat['catalog'])
    gaps = write_gap_report(out, cat['catalog'])

    files = sorted(p for p in out.rglob('*') if p.is_file())
    report = {
        'edition': EDITION,
        'downloads': str(dl),
        'guidelines': {'files': [f['file'] for f in gl['files']], 'extraction_check': gl['extraction_check']},
        'tabular': tab['stats'],
        'mce': {k: v['count'] for k, v in mce['lists'].items()},
        'ncci_manual_sections': sum(len(c['sections']) for c in ncci['chapters']),
        'addon_code_edits': aoc,
        'catalog': cat['catalog']['counts'],
        'citation_problems': cat['problems'],
        'implementation_evidence': {r['id']: {'status': r['implemented']['status'],
                                               'evidence': r['implemented']['evidence'],
                                               'found_in': r['implemented']['evidence_found_in']}
                                    for r in cat['catalog']['rules'] if r['implemented']['evidence']},
        'gaps': len(gaps),
    }
    write_json(out / 'build_report.json', report)
    write_readme(out, {**report, 'catalog': {'rules': cat['catalog']['counts']['rules'],
                                             'implemented': cat['catalog']['counts']['implemented']},
                       'guidelines': gl, 'files': []})
    files = sorted(p for p in out.rglob('*') if p.is_file())
    report['files'] = [(str(p.relative_to(out)).replace('\\', '/'), p.stat().st_size) for p in files]
    write_readme(out, {**report, 'catalog': {'rules': cat['catalog']['counts']['rules'],
                                             'implemented': cat['catalog']['counts']['implemented']},
                       'guidelines': gl})
    report['files'] = [(str(p.relative_to(out)).replace('\\', '/'), p.stat().st_size)
                       for p in sorted(q for q in out.rglob('*') if q.is_file())]
    write_json(out / 'build_report.json', report)
    print(json.dumps({k: report[k] for k in ('tabular', 'mce', 'catalog', 'citation_problems', 'addon_code_edits')}, indent=1))
    if cat['problems']:
        print('WARNING: citation or evidence problems, see build_report.json', file=sys.stderr)


if __name__ == '__main__':
    main()
