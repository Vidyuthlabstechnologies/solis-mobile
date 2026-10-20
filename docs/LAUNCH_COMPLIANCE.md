# SOLIS launch and compliance checklist (US, Google Play and Apple App Store)

Checked 2026-10-16, statuses updated 2026-10-17. Not legal advice: have a healthcare attorney confirm the
regulatory and HIPAA items before real patient data flows.

## 1. There is no "HIPAA certificate"

HIPAA has no government certification or license. What a buyer (a clinic)
will ask for, and what you must actually have:

| Item | Required? | Status |
| --- | --- | --- |
| HIPAA Security Rule risk analysis (45 CFR 164.308(a)(1)) | Required | To do |
| Written security policies and procedures, workforce training, breach response plan | Required | To do |
| Business Associate Agreement (BAA) with each clinic | Required | Template drafted (have counsel review) |
| BAA with every vendor that touches PHI (subcontractors) | Required | See section 2 |
| SOC 2 Type I, then Type II | Not legally required; most practices and every hospital will ask | Optional, plan for it |
| HITRUST | Optional; hospitals and payers sometimes ask | Later |

Do not say "HIPAA compliant" or "HIPAA certified" in the stores or on the site
until the items above are done. "Built for HIPAA workflows. BAA available."
is the current wording.

## 2. Vendor BAAs (blocking before real patient data)

| Vendor | What it handles | BAA |
| --- | --- | --- |
| Cloudflare (Worker backend, Pages, KV) | Transcripts, notes, claims pass through the Worker | Cloudflare signs a BAA only for Enterprise customers with a minimum spend, and only for listed services. Get written confirmation that Workers is covered, or move the PHI path to a BAA-covered host. |
| Anthropic (Claude notes) | Transcript text | Needs a signed BAA plus a HIPAA-ready (or zero-data-retention) configuration on the API org. Request through Anthropic sales; confirm the model in use (Haiku) is eligible. |
| Deepgram (cloud voice separation) | Audio | BAA available on request. |
| Stedi (eligibility, claims) | Claims and eligibility data | BAA available on request. |
| Google ML Kit, on-device engine | Runs on the phone | No PHI leaves the device. |

Until those BAAs are signed, pilot only with demo or de-identified data, or in
on-device mode.

## 3. FDA

- Documentation (ambient scribe) and billing/coding software are generally
  treated as administrative support or EHR-type functions excluded from the
  device definition by FD&C Act section 520(o)(1)(A) and (E). No clearance is
  needed for SOLIS as it is today.
- Stay on that side of the line: SOLIS only codes what the clinician said and
  asks the clinician to confirm uncertain diagnoses; it does not diagnose,
  recommend treatment, or generate findings the clinician did not state. Keep
  marketing claims to documentation and billing.
- FDA published a GenAI-enabled device discussion paper in August 2026
  (comments due 2026-10-19, docket FDA-2026-N-7874). Not binding; watch it.

## 4. Other US rules

- Recording consent: several states require all-party consent. SOLIS already
  asks and records consent (verbal or signature, time, location) before every
  recording.
- AMA CPT license: required to sell software that uses CPT codes (descriptors
  and the NCCI PTP table). Apply at ama-assn.org/go/cpt.
- Stedi / payer enrollment: the practice must be enrolled with each payer for
  electronic claims (EDI enrollment); Stedi handles most of this.

## 5. Google Play

| Requirement | Status |
| --- | --- |
| Developer account: organization account (needs a D-U-N-S number). A new personal account must run a closed test with 12+ testers for 14 continuous days before production. | To do: the current Play account is Personal; convert it to Organization (D-U-N-S) before submitting, see `docs/PLAY_STORE.md` |
| Signed release build (Play App Signing, upload key) | Done: `D:\Downloads\solis-1.0.0-play.aab`, signed with the upload key in `secrets/solis-upload.jks` (backup: `D:\SOLIS-signing-backup`). Upload key SHA-256 `9F:1C:69:C0:37:AF:93:4D:0F:99:BE:A6:CD:55:F9:1D:67:37:F9:DE:E6:30:07:00:31:23:15:FB:38:98:57:9F` |
| Target API level 36 (required from 2026-08-31) | Done (targetSdk 36) |
| Health apps declaration form (Policy > App content) | To do in Play Console: declare clinical documentation and billing; not a medical device |
| Privacy policy at a public URL (not a PDF) | Partly: https://solis-health.pages.dev/privacy is a summary; needs a full privacy policy (have counsel review) |
| Data safety form | To do: audio (processed, optionally sent to Deepgram), health info, location, photos (cards, deleted after reading), name/IDs; data encrypted in transit; deletion on request |
| Foreground service declaration (FOREGROUND_SERVICE_MICROPHONE) | To do in Play Console: explain recording a clinical visit the user started |
| Location permission declaration (foreground only) | To do: visit record location |
| App access for review | Done: "Use demo account" signs in with one tap; give reviewers that instruction |
| Disclaimer in the listing and app | In the app: done (sign-in, sign-up and About: "SOLIS helps clinicians document and bill. It is not a medical device and does not diagnose or treat. The clinician reviews and signs every note."). Listing: to do, same wording |
| Real user sign-in | Done: per-clinician accounts on the Worker (`/api/v2/auth/*`, D1 migration `0001_solis_app_users.sql`), session in the Keystore, sign out in the menu and provider profile. See docs/KEYS.md |
| Account deletion in the app (Play User Data policy) | Done: Provider profile > Account > Delete account, password confirmation, deletes the server account and sessions and erases this phone's data. Play also needs a web link for deletion requests: to do (a page on the site that explains the in-app path and takes email requests) |
| Play Integrity | Built, off until configured: app sends a Standard API token on sign-in and sign-up; the Worker verifies it when `GOOGLE_PLAY_INTEGRITY_SA_JSON` is set (report-only by default, `SOLIS_INTEGRITY_ENFORCE=true` to block). Keep report-only while the APK is sideloaded |
| Release hardening | Done: R8, Dart `--obfuscate --split-debug-info` (symbols in `D:\SOLIS-symbols`), signer verified by `tool\build_release.ps1`, TLS root pinning for the Worker host |

## 6. Apple App Store (iOS)

| Requirement | Status |
| --- | --- |
| Apple Developer Program as an organization: guideline 5.1.1(ix) requires healthcare apps to be submitted by a legal entity, not an individual | To do (needs D-U-N-S) |
| A Mac with Xcode to build, sign and upload | To do (cannot be done from this Windows PC; or use a cloud Mac / Codemagic) |
| iOS versions of the native parts: location, screen protection, wake lock and the on-device speech engine are Android code today | Gap: needs an iOS port (Swift). The Dart side already degrades on iOS without crashing: each call is caught and reports "unsupported" (no location on the consent record, screenshots not blockable, on-device speech off so the platform recognizer is used, card scanning uses the camera picker instead of the ML Kit document scanner) |
| Info.plist usage strings: microphone, speech recognition, camera, location, photo library | Done (plain wording of what each is used for) |
| Play Integrity equivalent (App Attest / DeviceCheck) | To do with the iOS port; the server treats a missing token as "skipped" |
| Privacy nutrition labels, privacy policy URL | To do |
| Account deletion in app (guideline 5.1.1(v)) | Done (same flow as Android) |
| Demo account for App Review | Done (one-tap demo) |
| Medical disclaimer, no diagnosis claims (guideline 1.4.1) | To do in listing |

## Recommended order

1. Form the legal entity's store accounts (Google organization account, Apple
   organization account; D-U-N-S number for both).
2. Sign BAAs (Anthropic, Deepgram, Stedi; Cloudflare Enterprise or move the
   PHI path), do the HIPAA risk analysis and policies.
3. Real sign-in, account deletion and in-app disclaimers are done; still to do: full privacy policy, web deletion-request page, store listing disclaimer.
4. Google Play internal testing -> closed testing with pilot clinics ->
   production.
5. iOS port of the native parts, then TestFlight -> App Store.
6. SOC 2 Type I once pilots convert to paying customers.
