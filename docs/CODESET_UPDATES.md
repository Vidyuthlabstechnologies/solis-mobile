# Code-set auto-updates

The official code sets in `assets/codes/` (ICD-10-CM, HCPCS Level II, PFS
RVU, NCCI MUE and add-on edits, MCE lists, Tabular notes, guidelines, rule
catalog) change on CMS's schedule, not ours. This service gets new releases to
installed apps without an app release, at close to zero cost.

```
 daily cron                weekly (GitHub Actions / Task Scheduler)            every app, at most daily
 ----------                ----------------------------------------            ------------------------
 solis-codesets-worker     tool/codeset_updater/update.py                      CodesetUpdateClient (Dart)
  reads CMS pages  ----->   GET /v1/releases (what is pending)                  GET manifest.json (R2)
  stores releases in KV     downloads zips from www.cms.gov                     verify Ed25519 signature
  webhook on new release    build_knowledge_base.py + build_code_assets.py      download changed files
  reads R2 manifest.json    gates, diff, sign manifest                          verify sha256, atomic switch
                            upload to R2 bucket solis-codesets  -------------->  keep previous for rollback
```

The Worker only detects; it never parses data files (10 MB XML and PDF parsing
do not fit Worker CPU limits). The build runs where Python and PyMuPDF are.
Apps never call the Worker: they read static files from R2.

## Live endpoints

| What | URL |
| --- | --- |
| Release monitor Worker | https://solis-codesets-worker.cbvarshini1.workers.dev |
| Pending releases | https://solis-codesets-worker.cbvarshini1.workers.dev/v1/releases |
| Detection history | https://solis-codesets-worker.cbvarshini1.workers.dev/v1/history |
| CMS transmittals | https://solis-codesets-worker.cbvarshini1.workers.dev/v1/transmittals (`?relevant=1`, `&current=1`, `&limit=N` up to 600, `&year=YYYY`) |
| Manual check (admin) | `POST /v1/check`, header `Authorization: Bearer <secrets/codesets_worker_admin_token.txt>`, at most every 10 minutes |
| Public bucket (r2.dev) | https://pub-c522aa6f22b14c29b715aff2d857c424.r2.dev |
| Manifest | https://pub-c522aa6f22b14c29b715aff2d857c424.r2.dev/manifest.json |

Cloudflare resources: Worker `solis-codesets-worker` (cron `17 6 * * *`, daily
06:17 UTC), KV namespace `solis-codesets-state`
(`87516a8ad98a409ea08700c21397afd3`), R2 bucket `solis-codesets` with public
r2.dev access. Source: `C:\Users\varsh\solis-codesets-worker\`.

## What is tracked

Each tracked item has an id and a version string. A version that differs from
`sources[id]` in the published manifest is "pending".

| id | CMS page | Version example | Cadence |
| --- | --- | --- | --- |
| `icd10cm-<FY>` | ICD-10 codes page | `2026-10-01` (release effective date; an April 1 update supersedes October) | Oct 1 yearly, April 1 updates |
| `icd10cm-guidelines` | ICD-10 codes page | `fy-2027-icd-10-cm-coding-guidelines` | yearly |
| `hcpcs` | HCPCS quarterly update | `october-2026-alpha-numeric-hcpcs-file` | quarterly |
| `pfs-rvu` | PFS relative value files, then the newest RVUyyX page | `rvu26d-updated-08-26-2026` | quarterly, plus re-posts |
| `mue-practitioner` | NCCI MUE page | `medicare-ncci-2026-q4-practitioner-services-mue-table` | quarterly |
| `ncci-addon` | NCCI add-on code edits page | `add-code-edits-medicare-effective-10012026` | quarterly |
| `mce` | MS-DRG classifications and software | `fy2027-fr-definition-mce-v44` (final rule only; proposed-rule files ignored) | yearly, occasional April vN.1 |
| `ncci-manual` | NCCI policy manual page | `2026-ncci-medicare-policy-manual-all-chapters` | yearly (chapter titles only are used) |

ICD editions are reported from the previous fiscal year onward (claims are
filed within a year of the date of service), so in FY2027 both FY2026 and
FY2027 are published, and FY2028 appears as soon as CMS posts it (usually June
to August), before it takes effect. Only `https://www.cms.gov` links are ever
used. PTP edits are never tracked or published (AMA license).

The detection logic exists twice, in `src/detect.ts` (Worker) and in
`tool/codeset_updater/codeset_lib.py` (fallback when the Worker is
unreachable). Both are tested against the same page fixtures and the same
expected result (`test/fixtures/expected_releases.json`, copied to
`tool/codeset_updater/testdata/`). After changing either parser, run
`npm run test:snapshot` in the Worker, copy the fixtures to `testdata/`, and
run the Python tests.

A page that fails (HTTP error, layout change) is recorded in `errors` and its
previous detection is kept, so an outage never looks like a removal. With
`NOTIFY_WEBHOOK_URL` set (`wrangler secret put NOTIFY_WEBHOOK_URL`) the Worker
posts `{text, content, releases}` (Slack, Discord and Teams style) when a new
version appears. An email hook is marked in `notify()` in `src/index.ts`
(bind `send_email` from Email Routing to enable it).

## CMS transmittals

The same daily run reads the CMS transmittal RSS feed (newest 30, full
subjects) and the yearly listing (newest 100, shortened subjects) for this
year and next (plus last year in January), stores every transmittal in KV
(`transmittals:v1`, newest 600), and completes up to six shortened subjects a
day from the detail pages (claim-relevant first), which also gives the PDF
link. Each transmittal is tagged by keyword (`src/transmittals.ts`, `TOPICS`):
ICD-10, HCPCS, physician fee schedule/MPFSDB, NCCI, MUE, CCEM/code sets, EDI
front end, 837, 276/277 and claim status, 835, place of service, modifier,
telehealth, ambulance. `relevant` is true when any tag matched. A later
transmittal of the same CR marks the earlier one `replaced_by` (CMS replaces
rather than edits: R13977OTN replaced R13967OTN for CR 14429). The webhook
payload gains `transmittals` (new relevant ones) and the text lists them with
CR, implementation date and link; `/v1/history` entries carry them too. The
first run is a baseline and notifies nothing. The app shows the newest five
relevant, current ones in Integrations, Code sets, "Recent CMS updates"
(`lib/widgets/cms_updates_section.dart`), loaded only when opened.

## Build and validation (update.py)

```
python -P tool/codeset_updater/update.py              # publish if anything is pending
python -P tool/codeset_updater/update.py --dry-run    # build, gate, sign; no upload
python -P tool/codeset_updater/update.py --force      # rebuild and publish anyway
python -P tool/codeset_updater/update.py --local-detect   # skip the Worker
python -P tool/codeset_updater/update.py --allow change:pfs_rvu.tsv.gz   # accept a reviewed gate
python -P tool/codeset_updater/verify_published.py    # check the public copy like the app does
python -P tool/codeset_updater/test_update.py         # unit tests
```

Use `-P`, not `-I`: PyMuPDF and cryptography are user site packages. Set
`TEMP=D:\temp` for heavy runs; pass `--cache` (or `SOLIS_CODESETS_CACHE`) to
reuse `%LOCALAPPDATA%\Temp\solis_codesets`.

1. Releases: `GET /v1/releases` (or local detection). Exit 0 if nothing is
   pending.
2. Downloads: official zips and PDFs into the cache, HTTPS from `www.cms.gov`
   only, HTML responses (license pages) refused.
3. Build into a staging folder (`%TEMP%\solis_codeset_staging\<timestamp>`).
   `build_knowledge_base.py` runs with `--out <staging>/knowledge`;
   `build_code_assets.py` is loaded as a module with its source URLs replaced
   by the detected ones and its `__file__` pointed at a shadow tree, so the
   generated `rule_citations.g.dart` also lands in staging. Nothing in
   `assets/`, `knowledge/` or `lib/` is written. Builds are reproducible
   (gzip mtime 0): the current run produced files byte-identical to the
   bundled assets.
4. Gates. Any problem stops the run with exit code 2 and `report.json`:
   - allow-list of asset names; anything matching `ptp` or `cpt` is refused;
   - row count bounds per set (for example ICD-10-CM 85,000 to 115,000);
   - every row format-valid (ICD-10-CM code pattern including `QA0.0101`,
     HCPCS `A0000`, 5-character CPT/HCPCS numbers, RVU numerics, MUE
     indicator 1 to 3, add-on types, 7th character lists, note kinds, rule
     severities), unique keys, exact column counts;
   - CPT-bearing sets (RVU, MUE, add-on) must have no lowercase text or
     spaces in any cell, so a descriptor can never slip in;
   - diff against the published file (else the bundled asset, else for a new
     ICD edition the previous edition): added, removed and changed counts
     with limits per set, for example ICD-10-CM 3% added or removed within an
     edition and 6% for a new fiscal year; RVU values may all change (annual
     A release) but codes may not churn more than 10%;
   - guideline citation check: every guideline section cited by
     `rule_catalog.tsv.gz` exists in `guidelines_fy*.tsv.gz`, and the
     knowledge-base build report has no citation problems;
   - required assets present (each ICD edition with its index, HCPCS, RVU,
     MUE and all knowledge assets).
5. Manifest, signed with Ed25519 (format below).
6. Upload with wrangler: new files first (content addressed, so unchanged
   files are skipped), then `reports/<serial>.json`, `manifests/<serial>.json`
   and last `manifest.json`. Then `verify_published.py` downloads everything
   from the public URL and checks signature and hashes.

### Knowledge-base items pinned to the builder edition

`build_knowledge_base.py` and the knowledge part of `build_code_assets.py`
are written for one ICD fiscal year (`EDITION`, file names such as
`icd_notes_2027`). The updater adopts new quarterly files (HCPCS, RVU, MUE,
add-on edits) and new ICD code and index editions automatically. For a new
guidelines year, MCE major version or NCCI manual year it keeps the
configured source, records it in `sources` (so the Worker keeps showing it as
pending) and prints a note. To adopt it: update `EDITION`/`SOURCES` in
`build_knowledge_base.py`, the `_2027`/`v44` names in `build_code_assets.py`
and `SOURCES.md`, run `update.py --dry-run`, review, then publish. The app
side needs no change for this if it looks files up by set (below).

## Manifest format (`solis-codesets/1`)

```json
{
 "format": "solis-codesets/1",
 "serial": 2026101701,
 "generated_at": "2026-10-17T13:20:05Z",
 "previous_serial": null,
 "publisher": "SOLIS code-set updater",
 "license_note": "Public-domain US government data (CMS, NCHS). No CPT descriptors.",
 "sources": {"hcpcs": "october-2026-alpha-numeric-hcpcs-file", "icd10cm-2027": "2026-10-01", "...": "..."},
 "releases": [{"id": "icd10cm-2027", "version": "2026-10-01", "label": "ICD-10-CM FY2027",
               "effective_from": "2026-10-01", "effective_to": "2027-09-30", "page": "https://www.cms.gov/...",
               "urls": {"descriptions": "https://www.cms.gov/files/zip/...", "tables_index": "..."}}],
 "files": [{"name": "icd10cm_2027.tsv.gz", "set": "icd10cm", "release": "icd10cm-2027", "edition": "FY2027",
            "effective_from": "2026-10-01", "effective_to": "2027-09-30", "select": "date_of_service",
            "sha256": "3a279ef8...", "size": 702951, "rows": 98403,
            "path": "files/3a279ef8.../icd10cm_2027.tsv.gz",
            "changes": {"added": 0, "removed": 0, "changed": 0, "baseline": "bundled"}}],
 "signature": {"alg": "Ed25519", "key_id": "solis-codesets-ad12fdbd", "value": "<base64>"}
}
```

- `serial`: `YYYYMMDDNN`, strictly increasing. Clients never accept a serial
  that is not greater than what they have.
- `files[].set`: the stable lookup key. Sets: `icd10cm`, `icd10cm_index`
  (`select: date_of_service`, one file per fiscal year) and `hcpcs`,
  `pfs_rvu`, `mue_practitioner`, `ncci_addon`, `mce`, `icd10cm_excludes1`,
  `icd_7th`, `icd_notes`, `guidelines`, `rule_catalog` (`select: latest`).
- `files[].path`: relative to the bucket URL; content addressed, immutable.
- File content format is exactly the bundled asset format (see
  `assets/codes/SOURCES.md`).

### Signature

The signature is Ed25519 over the canonical JSON of the manifest without its
`signature` member: keys sorted, no whitespace (`,` and `:` separators),
strings printable ASCII only (the updater refuses anything else), integers
only (no floats). Python `codeset_lib.canonical_json` and Dart
`canonicalJson` produce identical bytes; the Dart tests check this against a
Python-signed vector.

- Private key: `C:\Users\varsh\solis_mobile\secrets\codeset_signing_ed25519.pem`
  (PKCS8 PEM, git-ignored). In CI: secret `CODESET_SIGNING_KEY`. Back it up
  offline; losing it means shipping a new public key in an app release.
- Public key: `tool/codeset_updater/public_key.txt`, `key_id` =
  `solis-codesets-` + first 8 hex of sha256(raw key) =
  `solis-codesets-ad12fdbd`.
- Rotation: generate a new pair, add its line to `public_key.txt`, ship an app
  release trusting both, then sign with the new key; remove the old line a
  release later.

## R2 layout and caching

| Key | Cache-Control |
| --- | --- |
| `manifest.json` | `public, max-age=900` |
| `manifests/<serial>.json` (history, rollback) | immutable, 1 year |
| `files/<sha256>/<name>` | immutable, 1 year |
| `reports/<serial>.json` (gate and diff report) | 1 day |

Current publication: serial 2026101701, 14 files, 3,212,654 bytes (largest
`icd10cm_2027.tsv.gz` 702,951 B, `icd10cm_2026.tsv.gz` 701,352 B, index files
about 571 KB each, `hcpcs` 219,665 B, `icd_notes_2027` 168,122 B, `pfs_rvu`
103,046 B); manifest about 11.8 KB.

## Schedules

| Job | When | Where |
| --- | --- | --- |
| Release detection | daily 06:17 UTC | Worker Cron Trigger |
| Build and publish | weekly, Tuesdays 07:41 UTC | `tool/codeset_updater/github-workflow.yml` (copy to `.github/workflows/codeset-update.yml`; secrets `CODESET_SIGNING_KEY`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`) |
| Interim build and publish | weekly, Tuesdays 09:00 local | Windows Task Scheduler, see below |
| App check | at most once per 24 h per device | `CodesetUpdateClient.checkForUpdate()` |

Interim scheduler on this computer (not registered yet; run once to register):

```
schtasks /Create /TN "SOLIS\Codeset update" /SC WEEKLY /D TUE /ST 09:00 /TR "C:\Users\varsh\solis_mobile\tool\codeset_updater\run_update.cmd"
```

`run_update.cmd` sets `TEMP=D:\temp`, uses the existing download cache and
appends to `D:\temp\solis_codeset_update.log`. Exit code 2 in the log means a
gate refused to publish: read the `report.json` path printed above it.

## Worker development

```
cd C:\Users\varsh\solis-codesets-worker
npm test                  # node test runner over src/detect.ts and the handlers (fixtures in test/fixtures)
npm run test:snapshot     # rewrite expected_releases.json after an intended parser change
npx tsc --noEmit
C:\Users\varsh\cloudflare-healthcare-rcm-agentic-cloud\node_modules\.bin\wrangler.cmd deploy
```

## Cost at one million users

- Worker: one cron run a day (8 CMS page fetches) plus a few updater calls.
  Free tier.
- R2 storage: about 3.2 MB per serial, a few serials a year. Free tier.
- Egress: free on R2.
- Manifest reads: one per device per day, about 30 M requests a month. On
  r2.dev every read is an R2 Class B operation (10 M free, then $0.36 per
  million: about $7 a month). r2.dev is also rate limited and meant for
  development, so before launch attach a custom domain (for example
  `codesets.<domain>`) to the bucket and add a Cache Rule "cache everything"
  for it: the 15-minute manifest and immutable files are then served from
  Cloudflare's cache and R2 sees only cache misses (near zero). Change the
  base URL in the app and in `update.py`/`verify_published.py` (constants
  `PUBLIC_BASE`/`DEFAULT_BASE`) when that happens; the signature makes the
  host irrelevant for integrity.
- File downloads: only changed files, about 0.4 MB per quarterly update and
  about 1.5 MB per new ICD edition per device; first install is 3.2 MB unless
  the bundled set already equals the published serial (it does today).

## App integration

Done in app 1.0.1+2. Where it lives:

- `lib/services/codesets/codeset_update_client.dart`: the client.
- `lib/services/codesets/codeset_updates.dart`: embedded key, base URL,
  `bundledCodesetSerial`, `UpdatedCodeSetSource` (downloaded first, looked up
  by set, ICD files by fiscal year and date; bundled fallback), startup,
  rollback on parse failure, the daily check, "Use built-in code sets".
  Two client instances: the one loaded at startup serves reads for the whole
  run; the checker installs new sets, which apply at the next start.
- `IcdEditions.available` is the bundled editions plus the downloaded ones.
- Integrations screen: "Code sets" card (`lib/widgets/code_sets_card.dart`).
- Tests: `test/codeset_update/` (fixtures from
  `python -P tool/codeset_updater/make_dart_fixtures.py`).
- Live check: `dart run tool/codeset_live_check.dart` (from the repo root).
- TLS: the r2.dev host is not pinned (public, signed data; see the comment
  at the top of `codeset_updates.dart`). Its chain (Let's Encrypt YE1, Root
  YE, cross-signed by ISRG Root X2 and X1) does verify against the pinned
  roots today; the live check prints this.

The original steps follow for reference.

1. Dependency: add `cryptography: ^2.7.0` to `pubspec.yaml` (Ed25519 verify
   and SHA-256, pure Dart; `crypto` has no Ed25519, and pointycastle is not
   needed). `http`, `crypto` and `path_provider` are already there.
2. Move `tool/codeset_updater/dart/codeset_update_client.dart` to
   `lib/services/codesets/codeset_update_client.dart` and
   `tool/codeset_updater/dart/test/` (test plus `fixtures/`) to
   `test/codeset_update/`; fix the import path and the fixture paths
   (`test/fixtures` and `../public_key.txt` in the test become the new
   locations). `dart test` in `tool/codeset_updater/dart` passes 13 tests
   today; `dart run tool/live_check.dart` installs the live set.
3. Trusted key: embed the line from `tool/codeset_updater/public_key.txt` as a
   constant and pass `parseTrustedKeys(thatConstant)`; never download keys.
4. Construct once at startup:

   ```dart
   final codesetUpdates = CodesetUpdateClient(
     root: Directory('${(await getApplicationSupportDirectory()).path}/codesets'),
     baseUrl: Uri.parse('https://pub-c522aa6f22b14c29b715aff2d857c424.r2.dev'),
     trustedKeys: parseTrustedKeys(codesetPublicKeys),
     httpGet: ioHttpGet(),          // or a package:http adapter; must throw on non-200
     bundledSerial: 2026101701,     // the bundled assets are byte-identical to this serial
   );
   await codesetUpdates.load();     // fast: reads current.json, verifies the stored manifest
   ```

   Bump `bundledSerial` whenever the bundled assets are rebuilt to match a
   newer published serial (compare sha256 values with the manifest).
5. Reading assets: the loader already reads through `CodeSetSource`. Add a
   layered source and install it before `ReferenceData.load()`:

   ```dart
   class UpdatedCodeSetSource implements CodeSetSource {
     UpdatedCodeSetSource(this.client, [this.fallback = const AssetCodeSetSource()]);
     final CodesetUpdateClient client;
     final CodeSetSource fallback;
     @override
     Future<List<int>?> readBytes(String fileName) async {
       final f = client.fileNamed(fileName);
       if (f != null) {
         try { return await f.readAsBytes(); } catch (_) {}
       }
       return fallback.readBytes(fileName);
     }
   }
   CodeSetLoader.useSource(UpdatedCodeSetSource(codesetUpdates));
   ```

   For names that can change across editions (`mce_v44`, `*_2027`), resolve by
   set: `client.fileForSet('mce')`, `client.fileForSet('icd_notes')`, and so
   on, falling back to the `CodeSetFiles` constant when null.
6. ICD-10-CM edition by date of service: `IcdEditions.available` must become
   the sorted union of the bundled editions (`[2026, 2027]`) and
   `client.icdEditions()`. For a date of service, take
   `client.fileForSet('icd10cm', dateOfService: dos)` (and `icd10cm_index`);
   when null, use the bundled `icd10cm_<FY>` for that FY, and when neither
   exists keep today's behaviour (`IcdEditions.resolve`). A future edition
   (FY2028 posted in summer) is installed ahead and used only for dates of
   service on or after its `effective_from`.
7. Checking: after the first frame, `unawaited(codesetUpdates.checkForUpdate())`
   with a random 0 to 30 s delay. The client enforces once per 24 h (state in
   `state.json`), verifies the signature and serial, downloads only files
   whose sha256 changed, verifies size and sha256 of each, assembles the new
   set in `sets/<serial>.partial`, renames it to `sets/<serial>` and switches
   by atomically replacing `current.json`. It never throws; it returns
   `updated`, `upToDate`, `throttled`, `incompatible` (format newer than the
   app understands: keep current) or `failed` (current set stays active).
   Apply an `updated` result on the next launch (or call
   `CodeSetLoader.reset()` and `ReferenceData.load()` when no claim is being
   edited) so a claim is never checked against two sets.
8. Rollback and fallback: if parsing a downloaded file throws, call
   `codesetUpdates.rollback()` (switches to the previous set or to bundled
   assets and blocks that serial) and reload from bundled. Offer the same in
   a diagnostics screen ("Use built-in code sets"). `load()` itself falls back
   to the previous set, then bundled, when a stored set is missing a file or
   fails verification.
9. Show provenance in About or Settings: `installed.serial` and the
   `releases[].label` values from `installed.raw` (for example "HCPCS Level II
   October 2026", "ICD-10-CM FY2027").
10. Network: the manifest is signed, so TLS pinning is not needed for
    integrity; if the app's pinning allow-list is strict, add the R2 host (or
    the later custom domain) to it or exempt it.
11. Rule citations: `lib/services/coding/rule_citations.g.dart` stays the
    compiled fallback; the downloaded `rule_catalog.tsv.gz` carries the
    current citations.

## Failure modes

| Situation | Result |
| --- | --- |
| CMS page down or redesigned | Worker keeps the previous detection for that page, `errors` shows it; parsers need an update if it persists |
| CMS blocks the Worker | `update.py` falls back to local detection |
| New file breaks a builder | build raises, nothing is published |
| Anomalous data (row counts, formats, churn, citations) | exit 2, `report.json`, nothing published; review and rerun with `--allow <gate>` |
| Upload interrupted | `manifest.json` is written last, so apps still see the old complete set |
| Bad set published | publish a fixed set with a higher serial (apps that rolled back accept it). Old files stay in R2 (content addressed), so an older file list from `manifests/<serial>.json` can be re-signed under a new serial; this needs a small script, `update.py` does not do it |
| Signing key lost | new key pair plus app release |
