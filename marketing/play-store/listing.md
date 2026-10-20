# SOLIS: Google Play store listing

Play Console > Grow users > Store presence > Main store listing. Language: English (United States) - en-US.
Every claim below comes from `marketing/FACTS.md`. Character counts were checked with a script
(Play limits: app name 30, short description 80, full description 4000).

## App details

| Field | Value | Count |
| --- | --- | --- |
| App name | `SOLIS: Visit Notes and Claims` | 29 / 30 |
| Short description | `Records the visit with consent, drafts the note and builds a checked claim.` | 75 / 80 |

Notes:
- The launcher label in the APK is "SOLIS Clinical OS". Play does not require the store name to match the
  launcher label, but reviewers flag listings that look like a different product. "SOLIS" leads both, which is fine.
- Short description rules (Play): no emojis, no ALL CAPS, no "best", "#1", "free", "new", no calls to action like "download now".

## Full description (paste exactly, between the lines)

---
SOLIS is a documentation and billing assistant for US physicians and small practices: primary care, urgent care, specialty clinics, nursing-home rounds and ambulance/EMS. It listens to the visit, writes the note, and builds a clean claim, on the doctor's phone.

SOLIS helps clinicians document and bill. It is not a medical device and does not diagnose or treat. The clinician reviews and signs every note.

CONSENT FIRST
Before anything is recorded, the patient hears a short script in English or Spanish and agrees out loud or signs on the phone. The time and location are saved with the visit. If the patient declines, nothing is recorded and you can type the note instead.

AMBIENT CAPTURE WITH SPEAKER SEPARATION
SOLIS tells the doctor's voice from the patient's. Your practice chooses the engine: on-device, where audio stays on the phone after a one-time download of about 150 MB, or cloud, using the Deepgram medical model, only when the practice turns it on.

THE NOTE WRITES ITSELF
A concise SOAP note for your review. Nothing is invented: no vitals or exam findings that were not said. Every diagnosis links to the words it came from.

DIAGNOSIS CODES FROM THE PATIENT'S OWN WORDS
"My feet burn at night" is coded as a symptom until you confirm a diagnosis (ICD-10-CM outpatient guideline IV.H). Uncertain wording waits for one-tap confirmation.

PROCEDURE CODES THAT MATCH
The E/M level is picked from place of service, new or established patient, and medical decision making.

CHECKS BEFORE THE CLAIM GOES OUT
Claims are checked against the official CMS code sets for the date of service: ICD-10-CM, HCPCS, the physician fee schedule, NCCI medically unlikely edits and add-on edits, Medicare Code Editor age, maternity and manifestation lists, and ICD-10-CM Excludes1 and 7th-character rules. 59 of 63 official coding rules are fully enforced. The other 4 (NCCI procedure-to-procedure pairs, mutually exclusive pairs, most comprehensive code and lab panels) need the AMA CPT license and are not in the app.

A WHY ON EVERY CHECK
Each check shows the rule in plain English, what it means on this claim, its official citation and the guideline text. Works offline.

OFFICIAL CODING NOTES
Excludes1, Excludes2, Code first, Use additional code, Code also and 7th-character notes from ICD-10-CM, shown under each diagnosis.

ORDERS FROM THE CONVERSATION
Labs, imaging, prescriptions, referrals and prior authorizations said in the visit are listed for review. You check them and mark them as sent. SOLIS does not connect to an EHR, lab or pharmacy.

SCAN THE CARDS
Insurance card, driver's license (reads the barcode) and SSN card are read on the phone with Google ML Kit. Photos are deleted after reading. Only the last 4 SSN digits are kept.

ONE ACCOUNT PER PATIENT
Each patient has one account number with a check digit, and visits by date, each with its own place of service.

ELIGIBILITY AND CLAIMS
Eligibility at check-in, 837P claims and claim status through the Stedi clearinghouse. Export as CMS-1500 data and 837P. Your practice must be enrolled with each payer for electronic claims.

PROVIDER PROFILE
Name, NPI (looked up in the national NPI registry), tax ID, specialty and insurers accepted.

PRIVACY
Vendor keys never ship inside the app; they live on the SOLIS server. On-device mode keeps audio on the phone. Card photos are deleted after reading and the full SSN is never stored. SOLIS is built for HIPAA workflows, and a Business Associate Agreement template is available for practices.

TRY IT WITHOUT AN ACCOUNT
Tap "Use demo account" on the sign-in screen to try every screen with fictional patients. The demo account stays on the phone.

PILOT STAGE
SOLIS 1.0.0 is in its pilot stage for US practices on Android 8 and later. CPT is a registered trademark of the American Medical Association.
---

Full description: 3,824 / 4,000 characters. It uses capitalized section headings because Play renders plain text;
no emojis, no "HIPAA compliant", no rankings or prices. The CPT trademark line is there because the checks paragraph
names CPT; keep or adjust it to match the AMA license terms once you have one.

## Category and tags

- App or game: **App**
- Category: **Medical**
- Tags (Play Console > Store settings > Manage tags, pick up to 5 from Google's list; choose the closest available):
  Medical records, Medical billing / Health administration, Doctors / Clinicians, Productivity tools for professionals, Speech to text.
  Google's tag list changes; pick only tags that describe what the app does. Do not pick consumer health tags (fitness, symptom checker).

## Contact details (Store settings > Store listing contact details)

| Field | Value |
| --- | --- |
| Email (required, shown publicly) | `[FOUNDER: support email, e.g. support@<your domain>]` |
| Phone (optional) | leave empty unless you want it public |
| Website | `https://solis-health.pages.dev` |

## Privacy policy (App content > Privacy policy)

`https://solis-health.pages.dev/privacy`

Gap: the page is a plain summary today. Play requires a policy that discloses what is collected, how it is used and
who it is shared with (types of third parties), how long it is kept, and how to request deletion. Before production,
expand it to cover: clinician account data on the SOLIS server (name, email, NPI, password hash, sessions), transcripts
sent to the SOLIS server and Anthropic in cloud mode, audio sent to Deepgram in cloud mode, claim and eligibility data
sent to Stedi and on to payers, location use, retention, and a link to `https://solis-health.pages.dev/delete-account`.
Have counsel review it.

## Graphics (files in `graphics/`)

| Asset | File | Spec checked |
| --- | --- | --- |
| App icon | `graphics/icon-512.png` | 512 x 512, 32-bit PNG with alpha (RGBA, fully opaque), 9.7 KB (limit 1024 KB). Full-bleed square; Play applies the rounded mask. |
| Feature graphic | `graphics/feature-graphic-1024x500.png` | 1024 x 500, 24-bit PNG, no alpha. Orchid background (not white, black or dark gray). Key elements inside the safe area. |
| Phone screenshots (8) | `graphics/phone/01_consent.png` ... `08_billing.png` | 1080 x 1920 (9:16), 24-bit PNG, no alpha. Caption band is 360 px = 18.75% of the height (Play limit for taglines: 20%). No calls to action. |
| 7-inch / 10-inch tablet | not supplied | Optional. Play wants real tablet UI; there are no tablet renders yet, and stretching phone screenshots is not recommended. |

Feature graphic alt text (max 140): `SOLIS logo and the line: The visit, the note and the claim, on your phone. A phone shows a draft SOAP note.`

Screenshot order and alt text (each max 140):

1. `01_consent.png`: Consent screen with the recording script in English or Spanish and buttons for verbal consent or a signature.
2. `02_recording.png`: A visit being recorded with a live transcript that separates the doctor and the patient.
3. `03_note.png`: Draft SOAP note for review, with a Sources button on each section.
4. `04_diagnosis-codes.png`: Claim tab with ICD-10-CM codes marked patient reported, each quoting the patient's words.
5. `05_claim-checks.png`: Claim checks listing an issue to fix before billing, each with a Why button.
6. `06_why.png`: The Why sheet for an uncertain-diagnosis rule, with its ICD-10-CM guideline citation.
7. `07_scan-cards.png`: Scanning an insurance card and driver's license to fill the patient details.
8. `08_billing.png`: Billing list grouped by needs signature, needs fixes and ready to send.

All screenshots are real app renders with fictional demo data (`screenshots/out`). To regenerate:
`python marketing/play-store/graphics/render.py` (needs Google Chrome and Pillow).
