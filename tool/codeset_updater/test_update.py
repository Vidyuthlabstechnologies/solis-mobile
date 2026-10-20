"""Unit tests for the code-set updater (no network, no upload).

    python -P -m unittest tool/codeset_updater/test_update.py -v
"""

from __future__ import annotations

import base64
import datetime as dt
import gzip
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import codeset_lib as lib  # noqa: E402

DATA = HERE / "testdata"  # copies of solis-codesets-worker/test/fixtures

PAGE_FILES = {
    lib.PAGES["icd"]: "icd.html",
    lib.PAGES["hcpcs"]: "hcpcs.html",
    lib.PAGES["rvuIndex"]: "rvu_index.html",
    lib.PAGES["rvuIndex"] + "/rvu26d": "rvu26d.html",
    lib.PAGES["mue"]: "mue.html",
    lib.PAGES["aoc"]: "aoc.html",
    lib.PAGES["mce"]: "msdrg.html",
    lib.PAGES["ncciManual"]: "ncci_manual.html",
}


def fixture_fetch(url: str) -> str:
    return (DATA / PAGE_FILES[url]).read_text(encoding="utf-8")


def write_gz(path: Path, rows) -> Path:
    path.write_bytes(gzip.compress(("".join("\t".join(r) + "\n" for r in rows)).encode(), mtime=0))
    return path


class DetectionMirror(unittest.TestCase):
    def test_matches_worker_snapshot(self):
        """The local detector returns exactly what the Worker's detect.ts returns."""
        res = lib.check_all(fixture_fetch, dt.date(2026, 10, 17))
        self.assertEqual(res["errors"], {})
        expected = json.loads((DATA / "expected_releases.json").read_text(encoding="utf-8"))
        self.assertEqual(res["releases"], expected)

    def test_new_quarter_and_fiscal_year(self):
        html = (DATA / "hcpcs.html").read_text() + '<a href="/files/zip/january-2027-alpha-numeric-hcpcs-file.zip">x</a>'
        self.assertEqual(lib.parse_hcpcs(html)["effective_from"], "2027-01-01")
        icd = """<a href="/files/zip/2028-code-descriptions-tabular-order.zip">a</a>
                 <a href="/files/zip/2028-code-tables-tabular-and-index.zip">b</a>
                 <a href="https://evil.example/files/zip/2029-code-descriptions-tabular-order.zip">c</a>"""
        r = lib.parse_icd(icd, dt.date(2027, 8, 1))
        self.assertEqual([(x["id"], x["version"]) for x in r], [("icd10cm-2028", "2027-10-01")])

    def test_fiscal_year(self):
        self.assertEqual(lib.fiscal_year(dt.date(2026, 9, 30)), 2026)
        self.assertEqual(lib.fiscal_year(dt.date(2026, 10, 1)), 2027)


class Signing(unittest.TestCase):
    def setUp(self):
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

        k = Ed25519PrivateKey.from_private_bytes(bytes(range(1, 33)))
        self.pem = k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                   serialization.NoEncryption())
        raw = k.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        self.keys = {lib.key_id_for(raw): raw}

    def test_canonical(self):
        self.assertEqual(lib.canonical_json({"b": [1, True, None], "a": 'x"y\\z/'}),
                         b'{"a":"x\\"y\\\\z/","b":[1,true,null]}')
        with self.assertRaises(ValueError):
            lib.canonical_json({"a": 1.5})
        with self.assertRaises(ValueError):
            lib.canonical_json({"a": "café"})

    def test_sign_verify_tamper(self):
        m = lib.sign_manifest({"format": "solis-codesets/1", "serial": 5, "files": []}, self.pem)
        lib.verify_manifest(m, self.keys)
        lib.verify_manifest(json.loads(json.dumps(m, indent=3)), self.keys)  # whitespace does not matter
        bad = {**m, "serial": 6}
        with self.assertRaises(ValueError):
            lib.verify_manifest(bad, self.keys)
        with self.assertRaises(ValueError):
            lib.verify_manifest(m, lib.load_public_keys(HERE / "public_key.txt"))  # production key differs

    def test_dart_fixture_verifies(self):
        m = json.loads((HERE / "dart" / "test" / "fixtures" / "manifest_v1.json").read_text())
        lib.verify_manifest(m, self.keys)

    def test_production_public_key_file(self):
        keys = lib.load_public_keys(HERE / "public_key.txt")
        self.assertEqual(len(keys), 1)
        kid, raw = next(iter(keys.items()))
        self.assertEqual(kid, lib.key_id_for(raw))


class Gates(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_spec_and_denylist(self):
        self.assertEqual(lib.spec_for("icd10cm_2028.tsv.gz")["edition"], "2028")
        self.assertEqual(lib.spec_for("icd10cm_index_2027.tsv.gz")["set"], "icd10cm_index")
        self.assertIsNone(lib.spec_for("ptp_practitioner.tsv.gz"))
        self.assertIsNone(lib.spec_for("cpt_descriptors.tsv.gz"))
        rep = lib.validate_file(write_gz(self.tmp / "ptp_practitioner.tsv.gz", [["99213", "99211"]]), None, None)
        self.assertIn("allowlist:ptp_practitioner.tsv.gz", rep["problems"])

    def test_hcpcs_formats_counts_and_diff(self):
        rows = [[f"A{i:04d}", "Short", "Long description"] for i in range(6000)]
        base = write_gz(self.tmp / "base.tsv.gz", rows)
        new_rows = rows[:-10] + [["J9999", "Short", "Long"]] + [["A0000", "Short", "Changed"]]
        new_rows = [r for r in new_rows if r != ["A0000", "Short", "Long description"]]
        new = write_gz(self.tmp / "hcpcs.tsv.gz", new_rows)
        rep = lib.validate_file(new, base, "published")
        self.assertEqual(rep["problems"], {})
        self.assertEqual((rep["diff"]["added"], rep["diff"]["removed"], rep["diff"]["changed"]), (1, 10, 1))
        bad = write_gz(self.tmp / "hcpcs.tsv.gz", rows[:5000] + [["99213", "x", "y"]])
        rep = lib.validate_file(bad, base, "published")
        self.assertIn("format:hcpcs.tsv.gz", rep["problems"])
        self.assertIn("rows:hcpcs.tsv.gz", rep["problems"])
        self.assertIn("change:hcpcs.tsv.gz", rep["problems"])

    def test_cpt_free_text_is_refused(self):
        rows = [[f"{90000 + i}", "1", "2"] for i in range(12000)]
        rows[5] = ["99213", "Office visit", "2"]
        rep = lib.validate_file(write_gz(self.tmp / "mue_practitioner.tsv.gz", rows), None, None)
        self.assertIn("cpt-text:mue_practitioner.tsv.gz", rep["problems"])

    def test_icd_codes_and_new_edition_baseline(self):
        rows = [[f"{chr(65 + i // 10000)}{i // 100 % 100:02d}.{i % 100:02d}", "1", "Something"] for i in range(90000)]
        rows.append(["QA0.0101", "1", "SCN2A-related neurodevelopmental disorder"])
        base = write_gz(self.tmp / "icd10cm_2027.tsv.gz", rows)
        nxt = write_gz(self.tmp / "icd10cm_2028.tsv.gz", rows[:-3000] + [["QA1.01", "1", "New code"]])
        rep = lib.validate_file(nxt, base, "previous-edition")
        self.assertEqual(rep["problems"], {}, "3.3% churn is fine for a new fiscal year")
        rep = lib.validate_file(nxt, base, "published")
        self.assertIn("change:icd10cm_2028.tsv.gz", rep["problems"], "but not within one edition")
        bad = write_gz(self.tmp / "icd10cm_2029.tsv.gz", rows + [["1234", "1", "x"]])
        self.assertIn("format:icd10cm_2029.tsv.gz", lib.validate_file(bad, None, None)["problems"])

    def test_guideline_citations(self):
        g = write_gz(self.tmp / "guidelines_fy2027.tsv.gz", [["I.A", "Conventions", "text"], ["IV.H", "Uncertain", "t"]])
        ok = write_gz(self.tmp / "rule_catalog.tsv.gz", [["R1", "t", "error", "c", "c", "r", "I.A,IV.H"]])
        self.assertEqual(lib.citation_problems(g, ok), [])
        bad = write_gz(self.tmp / "rule_catalog.tsv.gz", [["R1", "t", "error", "c", "c", "r", "IV.Z"]])
        self.assertEqual(len(lib.citation_problems(g, bad)), 1)

    def test_bundled_assets_pass_the_gates(self):
        codes = HERE.parent.parent / "assets" / "codes"
        for p in sorted(codes.glob("*.tsv.gz")):
            with self.subTest(p.name):
                rep = lib.validate_file(p, p, "bundled")
                self.assertEqual(rep["problems"], {})
                self.assertEqual(rep["diff"]["added"] + rep["diff"]["removed"] + rep["diff"]["changed"], 0)
        self.assertEqual(lib.citation_problems(codes / "guidelines_fy2027.tsv.gz", codes / "rule_catalog.tsv.gz"), [])


if __name__ == "__main__":
    unittest.main()
