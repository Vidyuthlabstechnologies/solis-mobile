# SOLIS

SOLIS is a Flutter app for US physicians and small practices. It records a
patient visit (after consent), writes a SOAP note, codes the visit with
ICD-10-CM and HCPCS/CPT codes, checks the claim against official CMS code sets
for the date of service, and sends it to a clearinghouse as an X12 837P, all
from the clinician's phone.

Status: Android pilot. Current version `1.0.2+3` (`pubspec.yaml`). iOS is not
released. The app is not yet on Google Play (see [docs/PLAY_STORE.md](docs/PLAY_STORE.md)).
The rules for what may be claimed about SOLIS publicly are in
[marketing/FACTS.md](marketing/FACTS.md).

## Features

- **Consent first.** A short consent script (English or Spanish) before
  recording; verbal or signed consent is saved with time and location. A
  declined consent is recorded too.
- **Two transcription engines** behind one `TranscriptionProvider` interface
  (`lib/services/transcription/`):
  - On-device: sherpa-onnx engine with speaker separation; audio stays on the
    phone; models are downloaded once and verified by SHA-256
    ([docs/NATIVE_SPEECH.md](docs/NATIVE_SPEECH.md)).
  - Cloud: Deepgram streaming (`nova-3-medical`) with diarization, using a
    short-lived token minted by the SOLIS Worker
    ([docs/TRANSCRIPTION.md](docs/TRANSCRIPTION.md)).
  - Recording runs in an Android foreground service with a Stop action in
    the notification; the level meter shows the real microphone level and a
    silent microphone is reported.
- **SOAP note.** Written by the SOLIS Worker (Claude, with Workers AI as the
  Worker's fallback) or by the on-device engine
  (`lib/services/local_clinical_engine.dart`). Signed notes carry a SHA-256
  seal (`note_seal.dart`).
- **Coding** (`lib/services/coding/clinical_coder.dart`): patient wording
  becomes symptom codes; hedged diagnoses wait for one-tap confirmation
  (ICD-10-CM guideline IV.H); E/M level from place of service, new vs
  established patient and medical decision making; ambulance (POS 41/42)
  billed with HCPCS transport and mileage codes. Code search on the Claim
  tab uses the NLM Clinical Tables ICD-10-CM API with an offline fallback.
- **Claim checks** (`claim_scrubber.dart`), offline, against bundled CMS
  data: ICD-10-CM FY2026 and FY2027 (chosen by the visit's date of service,
  including Tabular notes, Excludes1 and 7th characters), HCPCS, PFS RVU,
  NCCI MUE and add-on edits, MCE v44. 59 of 63 catalog rules are fully
  enforced (`knowledge/GAP_REPORT.md`); every finding has a rule id, a
  citation and a "Why" sheet. The other 4 depend on NCCI PTP data that needs
  an AMA CPT license (see Licensing). Medicare Part B claims also get the CMS
  CR 14429 (October 2026) EDI front-end edits
  ([docs/CMS_EDI_OCT2026.md](docs/CMS_EDI_OCT2026.md)).
- **Billing** (`lib/services/billing/`): eligibility, 837P claims and 276
  claim status through Stedi; claims carry an idempotency key, are queued
  when offline and retried; status is matched by control number. A Billing
  tab groups visits by what they need next. CMS-1500 / 837P JSON export and
  a FHIR R4 bundle export. See [docs/BILLING.md](docs/BILLING.md).
- **Card scanning** with Google ML Kit: insurance card (OCR), driver's
  license (PDF417 barcode), Social Security card (last 4 digits only).
- **Patients and visits**: one account per patient (`SOL-` number with a Luhn
  check digit), visits by date with their own place of service; saved places
  set the place of service from GPS. Orders from the conversation are listed
  for review and marked sent by hand (there is no EHR, lab or pharmacy
  integration).
- **Clinician accounts** through the Worker (`/api/v2/auth/*`), practice
  setup with live NPI registry lookup, account deletion, and a demo mode with
  labeled sample data that can never be billed.
- **Code-set auto-update** and a **CMS watcher** (below).

## Architecture

```
SOLIS app (this repo)
  |-- Bearer SOLIS_APP_TOKEN + X-Solis-Session --> SOLIS Worker /api/v2/*  --> Anthropic, Stedi, Deepgram
  |                                                (repo cloudflare-healthcare-rcm-agentic-cloud)
  |-- GET manifest.json + files (signed) -------> R2 bucket solis-codesets (public)
  |-- GET /v1/transmittals ---------------------> solis-codesets-worker (repo solis-codesets-worker)
  `-- NPI registry (NPPES), NLM Clinical Tables
```

- The backend Worker lives in a separate repository. The app's base URL is
  set by `SOLIS_BACKEND_URL` (default in `lib/services/solis_backend.dart`);
  the routes and secrets are documented in [docs/KEYS.md](docs/KEYS.md).
- Connections to the SOLIS host are TLS-pinned to the root CAs Cloudflare
  issues from (`lib/services/net/`, `tool/make_tls_pins.ps1`). Sign-in and
  sign-up carry Play Integrity headers when the build has a Google Cloud
  project number.

`lib/` layout:

| Path | Contents |
| --- | --- |
| `main.dart` | Startup: local store, session restore, code-set load, routes |
| `screens/` | Login, sign-up, practice setup, patients (Today / Patients / Billing), chart, encounter, claim tab, card scan, integrations |
| `widgets/` | Shared UI: encounter widgets, sign-and-send sheet, signature pad, code sets card, CMS updates, knowledge ("Why") widgets, brand |
| `models/` | Patient account, clinical, claim, provider profile, ambulance transport |
| `services/coding/` | Coder, claim scrubber, claim builder, place of service, generated rule citations |
| `services/codesets/` | Code-set loaders and parsers, `ReferenceData`, update client, CMS transmittals |
| `services/billing/` | Stedi client, 837P generator, CMS EDI edits, eligibility, submission, queue, settings |
| `services/transcription/` | Deepgram and on-device providers, engine selection, model manager, speaker roles |
| `services/net/`, `services/security/` | TLS pinning, Play Integrity |
| `theme/` | Material theme |

## Requirements

- Flutter 3.44.9 (Dart SDK `^3.12.2`), at `C:\tools\flutter` on the build machine.
- Android SDK; JDK 21 (the release script sets `JAVA_HOME` to Eclipse Adoptium 21).
- For releases: `secrets/keys.local.json` (from the key vault) and
  `android/key.properties` with the upload key. Neither is in the repo.
- For the code-set updater: Python 3 with PyMuPDF and cryptography, and
  Wrangler logged in to the Cloudflare account.

## Build, run, test

```
flutter pub get
flutter run                                   # debug; cloud calls need --dart-define=SOLIS_APP_TOKEN=...
flutter test                                  # 421 tests
```

On the build machine C: is nearly full, so point TEMP at D:

```
TEMP=D:/temp C:/tools/flutter/bin/flutter.bat test
```

Without an app token the app still runs in demo mode and on-device mode.

## Release

```
powershell -ExecutionPolicy Bypass -File tool\build_release.ps1            # APK + AAB
powershell -ExecutionPolicy Bypass -File tool\build_release.ps1 -SkipAab   # APK only
```

`tool/build_release.ps1`:

1. Reads `SOLIS_APP_TOKEN` (and `SOLIS_GCP_PROJECT_NUMBER` if present, which
   turns on Play Integrity) from `secrets/keys.local.json` and passes them
   through a temporary `--dart-define-from-file` JSON that is deleted after
   the build. Values are never printed or put on a command line.
2. Refuses to build without `android/key.properties` (a release would be
   debug-signed).
3. Builds with `--release --obfuscate --split-debug-info=D:\SOLIS-symbols\<version>`.
   Keep that folder: `flutter symbolize` needs it for crash stack traces.
4. Verifies signatures (apksigner, v2 scheme required; jarsigner for the AAB)
   and refuses a debug-signed build.
5. Copies `solis-<version>.apk` and `solis-<version>.aab` to `D:\Downloads`
   and `C:\Users\varsh\Downloads` and prints size and SHA-256.

Bump `version:` in `pubspec.yaml` before a release; the output names come from it.

## Code-set auto-update

Official code sets in `assets/codes/` change on CMS's schedule. Updates reach
installed apps without an app release
([docs/CODESET_UPDATES.md](docs/CODESET_UPDATES.md)):

- `solis-codesets-worker` (separate private repo, https://github.com/varshinicb1/solis-codesets-worker) checks CMS pages daily and serves
  `GET /v1/releases` (pending releases), `GET /v1/history` and
  `GET /v1/transmittals`; `POST /v1/check` is an admin-only manual check.
- `tool/codeset_updater/update.py` downloads the new CMS files, rebuilds the
  assets, runs validation gates (row counts, formats, churn, citations, no
  PTP, no CPT descriptor text), and publishes an Ed25519-signed manifest plus
  content-addressed files to the R2 bucket `solis-codesets`.
- The app (`lib/services/codesets/codeset_update_client.dart`,
  `codeset_updates.dart`) checks at most once a day, verifies the signature,
  serial and each file's SHA-256, and applies a new set on the next launch.
  It rolls back to the previous or bundled set if a file fails to parse, and
  Integrations > Code sets offers "Use built-in code sets".

## CMS watcher

The same Worker reads the CMS transmittals feed and listing daily, tags each
transmittal by claim-relevant topic, and marks rescinded ones with
`replaced_by`. The app shows the newest five relevant, current transmittals
under Integrations > Code sets > "Recent CMS updates"
(`lib/services/codesets/cms_transmittals.dart`,
`lib/widgets/cms_updates_section.dart`); only `https://www.cms.gov` links are
opened. The October 2026 HIPAA EDI front-end edits (CR 14429) are implemented
in `lib/services/billing/cms_edi_edits.dart` (rule ids `CMS-EDI-*`).

## Repository layout

| Path | Contents |
| --- | --- |
| `lib/` | App source |
| `test/` | Unit and widget tests (`test/codeset_update/` for the update client) |
| `assets/codes/` | Bundled code sets, built by `tool/build_code_assets.py` (sources in `assets/codes/SOURCES.md`) |
| `knowledge/` | Coding knowledge base from public CMS/NCHS sources, built by `tool/build_knowledge_base.py`; `GAP_REPORT.md` lists rules not fully enforced |
| `android/` | Android host: native speech engine, recording service, Play Integrity plugin (Kotlin) |
| `tool/` | Release build, key vault, code-set updater, asset and brand builders, TLS pin generator |
| `docs/` | Design and operations documents (below) |
| `marketing/site/` | Marketing site (Cloudflare Pages project `solis-health`, https://solis-health.pages.dev) |
| `marketing/play-store/` | Play Store listing, data safety answers, release checklist |
| `marketing/FACTS.md` | Source of truth for public claims |
| `screenshots/` | App renders with demo data |

Marketing site, from `marketing/site`:

```
node tools/build.mjs
npx wrangler pages deploy dist --project-name solis-health
```

## Documentation

| Doc | Topic |
| --- | --- |
| [BILLING](docs/BILLING.md) | Card-to-claim pipeline, claim checks, known limits |
| [BRAND](docs/BRAND.md) | Logo, color, brand assets |
| [CMS_EDI_OCT2026](docs/CMS_EDI_OCT2026.md) | CMS CR 14429 EDI front-end edits; ICD FY2027 by date of service |
| [CODESET_UPDATES](docs/CODESET_UPDATES.md) | Code-set auto-update service and CMS transmittals |
| [DESIGN](docs/DESIGN.md) | App design brief |
| [KEYS](docs/KEYS.md) | Keys and secrets, key vault, Worker API, accounts, Play Integrity, TLS pinning |
| [LAUNCH_COMPLIANCE](docs/LAUNCH_COMPLIANCE.md) | Launch and compliance checklist |
| [NATIVE_SPEECH](docs/NATIVE_SPEECH.md) | On-device speech and speaker separation |
| [ONBOARDING](docs/ONBOARDING.md) | Self-serve onboarding journey |
| [PLAY_STORE](docs/PLAY_STORE.md) | Publishing on Google Play (Organization account, D-U-N-S) |
| [PRICING](docs/PRICING.md) | Pricing proposal |
| [TRANSCRIPTION](docs/TRANSCRIPTION.md) | Deepgram streaming and speaker roles |
| [UNIT_ECONOMICS](docs/UNIT_ECONOMICS.md) | Cost model |
| [UX_REVIEW](docs/UX_REVIEW.md) | UX review and ranked changes |

## Licensing note: CPT and AMA

CPT codes and descriptors are owned by the American Medical Association. The
app does not ship CPT descriptor text, and the code-set updater's gates
refuse it. The NCCI procedure-to-procedure (PTP) table is served by CMS only
after the AMA CPT license click-through, so it is neither bundled nor
published; the PTP-based checks (`ClaimScrubber.ptpIssues`) run only when a
table is loaded locally. Licensed data is kept in `local_data/`, which is
git-ignored. Shipping PTP data requires an AMA CPT distribution license.
`knowledge/` and `assets/codes/` are built from public-domain CMS, NCHS and
CDC sources.

## Security

- No vendor keys (Anthropic, Deepgram, Stedi, AWS) are in the APK or in git.
  They are Cloudflare Worker secrets, managed with the key vault
  (`python tool\keyvault\keyvault.py`); see [docs/KEYS.md](docs/KEYS.md).
- The app token passed at build time is a revocable app identifier, not user
  authentication; clinicians authenticate with their own session.
- Optional per-phone Stedi or Deepgram keys entered on the Integrations
  screen are kept in Android Keystore-backed secure storage on that phone.
- `secrets/`, `local_data/`, signing keys, `key.properties`, `.env` and
  `.dev.vars` files and build outputs are git-ignored. Never commit them, and
  never paste key values into issues or chat.
- Card photos are deleted after reading; only the last 4 SSN digits are kept.
  Screenshots can be blocked from the provider profile.
