# Changelog

All notable changes to the SOLIS app are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
`pubspec.yaml` (`version+build`). Dates are build dates (IST).

## [Unreleased]

### Added
- `README.md` and this changelog.
- `docs/PLAY_STORE.md`: publishing on Google Play, including the requirement
  for an Organization developer account with a D-U-N-S number.

### Changed
- `docs/CMS_EDI_OCT2026.md`: re-checked against the CMS watcher on
  2026-10-21; R13977OTN is still the current transmittal for CR 14429.
- `docs/LAUNCH_COMPLIANCE.md` updated for the Organization account
  requirement; Play Store pack in `marketing/play-store/` (release checklist,
  data safety, health declaration) revised.
- `tool/codeset_updater/update.py` updated after the 1.0.2 build (tooling
  only; no app change).
- Repository prepared for version control; `.gitignore` covers `secrets/`,
  `local_data/`, signing keys, `key.properties`, `.env`/`.dev.vars` files and
  build outputs.

## [1.0.2] - 2026-10-18 (build 3)

### Added
- CMS CR 14429 (October 2026) HIPAA EDI front-end edits for Medicare Part B
  claims (`lib/services/billing/cms_edi_edits.dart`, rule ids `CMS-EDI-*`,
  citation "CMS CR 14429 (R13977OTN)"):
  - 837P: SV101-7 service description required for unlisted CPT and NOC
    HCPCS codes (at most 80 characters, X12-safe), with a line editor fix;
    a Medicare claim with a NOC line and no description is not built.
  - 837P: 1000B NM109 must equal GS03 when a file goes straight to the MAC.
  - 2010BA NM109: a Medicare member ID must be in MBI format.
  - 276 claim status: provider NPI and name, subscriber names, MBI (sent
    without dashes), birth date, sex and service dates are checked before
    sending; `StediClient.claimStatus` returns the problems with their CMS
    edit ids without calling Stedi. The 276 body now sends the patient's sex
    and names the provider by the clinician when there is no practice name.
  - See `docs/CMS_EDI_OCT2026.md`.
- "Recent CMS updates" in Integrations > Code sets: the newest five relevant,
  current CMS transmittals from the code-set Worker, loaded only when opened
  (`lib/services/codesets/cms_transmittals.dart`,
  `lib/widgets/cms_updates_section.dart`). Links open in the browser through a
  native handler that accepts only `https://www.cms.gov/` URLs; if no browser
  opens, the link is copied.
- Bundled per-edition Tabular notes, Excludes1 and 7th-character assets for
  ICD-10-CM FY2026 (`icd_notes_2026`, `icd10cm_excludes1_2026`,
  `icd_7th_2026`) alongside FY2027.
- Tests: `cms_edi_oct2026_test.dart`, `cms_updates_test.dart`,
  `icd_fy_boundary_test.dart`.

### Changed
- Claim checks, coding and the coding-notes view now use the ICD-10-CM
  edition of the visit's date of service for Excludes1, Tabular notes and
  7th characters (`ReferenceData.atDateOfService`), not only for the code
  list and Index. A visit on 2026-09-30 is checked against FY2026 and one on
  2026-10-01 against FY2027.
- Rebuilt code assets (`guidelines_fy2027`, `icd_notes_2027`,
  `icd10cm_excludes1_2027`, `icd_7th_2027`, `mce_v44`, `ncci_addon`,
  `rule_catalog`) and regenerated `rule_citations.g.dart` with the new rules.

### Fixed
- Before this release, Excludes1, code-first notes and 7th characters were
  always taken from FY2027, so September 2026 visits could get FY2027 notes
  and conflicts.

## [1.0.1] - 2026-10-18 (build 2)

### Added
- Code-set auto-update client (`codeset_update_client.dart`,
  `codeset_updates.dart`): reads a signed manifest from R2 at most once a
  day, verifies the Ed25519 signature, serial and SHA-256 of each file,
  installs new sets for the next launch, rolls back on a parse failure, and
  offers "Use built-in code sets". Code sets card on the Integrations screen.
  See `docs/CODESET_UPDATES.md`.
- Code-set updater tooling in `tool/codeset_updater/` (update, verify,
  scheduled run, GitHub Actions workflow template) and
  `tool/codeset_live_check.dart`.
- Practice setup: a real account starts with an empty provider profile and
  must complete "Set up your practice" before patients; a valid NPI is looked
  up automatically and prefills the form; the demo NPI is refused.
- Home screen with Today, Patients and Billing tabs. Billing groups visits by
  what they need next and sends ready claims in one batch.
- Offline claim queue: a claim that cannot be sent is queued and retried
  later with the same file and idempotency key.
- Ground ambulance 837P: CR1, CRC, pick-up and drop-off loops and loaded
  miles in tenths; miles from a GPS track and addresses from the phone
  geocoder prefill the Transport section. Missing miles, addresses, reason
  or origin/destination modifiers are errors; miles never default to 1.
- Recording runs in an Android foreground service with a Stop action in the
  notification; without the service the screen keeps the wake lock.
- Real microphone level on the level meter, and a "No sound" warning when
  the microphone is silent for 10 seconds.
- Saved places set the place of service from a GPS fix; the ready screen
  shows the place of service and, for a returning patient, the last visit.
- One-tap fixes on claim checks, one-tap E/M level change, and Undo when a
  code is removed.
- Delete patient from the chart, with Undo; deleted patients are erased after
  30 days.
- `tool/build_release.ps1`: obfuscated, signature-verified APK and AAB
  builds with debug symbols kept in `D:\SOLIS-symbols\<version>`.

### Changed
- Demo patients are seeded only in demo mode, labeled "Sample", and claims
  for a sample patient or the demo provider are errors outside demo mode. A
  store saved by an older build with the demo provider loads as empty.
- Orders: the checkbox means "include in this send" (default on for STAT and
  urgent orders), ticks are saved, and "Mark as sent" persists with Undo.
- Claim status is matched by the claim's control number instead of the first
  claim on the date of service.
- "Spanish and English" switches Deepgram to multilingual Nova-3 and the
  Android recognizer to es-US.
- Sign-in opens practice setup first when the profile is incomplete; a
  double tap on Sign in sends one request.

### Fixed
- Removed session controls that had no effect (room noise filter, accent
  list) and the level meter animation that moved with a dead microphone.
- The note seal is now a real SHA-256 of the signed note, signer and time.
- A declined consent is recorded on the visit instead of being dropped.
- The record button works with TalkBack (semantic tap).
- A signature stroke in the consent sheet draws instead of scrolling or
  dismissing the sheet.

## [1.0.0] - 2026-10-17 (build 1)

First pilot build for Android, release-signed.

### Added
- Consent before recording (English or Spanish), verbal or signed, with time
  and location.
- Ambient capture with speaker separation: on-device engine (sherpa-onnx,
  one-time model download, verified) or Deepgram streaming through the SOLIS
  Worker.
- SOAP note from the Worker (Claude) or the on-device engine.
- Diagnosis coding from the patient's words (ICD-10-CM guideline IV.H for
  uncertain diagnoses), E/M selection by place of service, patient status and
  medical decision making.
- Offline claim checks against bundled CMS code sets (ICD-10-CM FY2026 and
  FY2027, HCPCS, PFS RVU, NCCI MUE and add-on edits, MCE v44), with a "Why"
  sheet and citation for every finding; 59 of 63 catalog rules fully
  enforced.
- Card scanning with Google ML Kit (insurance card, driver's license barcode,
  SSN card last 4 only); photos deleted after reading.
- Patient accounts with check-digit account numbers and visits by date.
- Eligibility, 837P claims and claim status through Stedi, with idempotency
  keys; CMS-1500 / 837P and FHIR R4 export.
- Clinician accounts through the Worker (`/api/v2/auth/*`), account deletion,
  demo mode.
- Provider profile with live NPI registry lookup.
- TLS pinning to Cloudflare's issuing root CAs and optional Play Integrity
  headers on sign-in and sign-up.

## Known issues

- `lib/widgets/medical_disclaimer.dart` still has `const solisVersion = '1.0.0'`,
  so the About dialog and the account section show "Version 1.0.0" in 1.0.1
  and 1.0.2 builds. It should follow `pubspec.yaml`.
- NCCI procedure-to-procedure, mutually exclusive, most-comprehensive-code and
  lab-panel checks are not active in shipped builds: the PTP table needs an
  AMA CPT license and is not bundled (`knowledge/GAP_REPORT.md`).
