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

Updated for version 1.1.0 (the next-version brief, docs/NEXT_VERSION.md).

---
SOLIS is a documentation and billing assistant for US physicians and small practices: primary care, urgent care, psychiatry, specialty clinics, nursing-home rounds and ambulance/EMS. It listens to the visit, writes the note, and builds a clean claim, on the doctor's phone.

SOLIS helps clinicians document and bill. It is not a medical device and does not diagnose or treat. The clinician reviews and signs every note.

CONSENT FIRST
Before anything is recorded, the patient hears a short script in English or Spanish and agrees out loud or signs on the phone.

A RECORDING THAT DOES NOT GET LOST
SOLIS tells the doctor's voice from the patient's. On-device mode keeps audio on the phone after a one-time download of about 150 MB; cloud mode uses the Deepgram medical model only when the practice turns it on. If a call or a dead battery cuts a visit off, SOLIS keeps what it heard and offers to resume.

EVERY SENTENCE SHOWS WHERE IT CAME FROM
Nothing is invented: no vitals or exam findings that were not said. Tap a sentence to see the words it came from. Sentences without a source are flagged.

YOUR TEMPLATE, YOUR LENGTH
SOAP, primary care, urgent care with return precautions, or psychiatry with mental status in the patient's words. Brief, standard or detailed, with abbreviations spelled out or kept.

DIAGNOSIS CODES FROM THE PATIENT'S OWN WORDS
"My feet burn at night" is coded as a symptom until you confirm a diagnosis (ICD-10-CM outpatient guideline IV.H). Diagnoses you ruled out stay out.

CODES YOU CONFIRM
The E/M level is picked from place of service, new or established patient, and medical decision making. Nothing is sent until you confirm the level and codes, and every signature, change and send goes into the visit's audit trail.

CHECKS BEFORE THE CLAIM GOES OUT
Claims are checked against the official CMS code sets for the date of service: ICD-10-CM, HCPCS, the physician fee schedule, NCCI medically unlikely and add-on edits, Medicare Code Editor lists, and ICD-10-CM Excludes1 and 7th-character rules. 59 of 63 official coding rules are fully enforced. The other 4 need the AMA CPT license and are not in the app. Each check has a Why with the rule in plain English and its official citation. Works offline.

CLAIMS THAT FOLLOW UP
Eligibility at check-in, 837P claims and claim status through the Stedi clearinghouse. Rejections come back with suggested fixes. Claims made without signal wait and go out when the phone is back online. Your practice must be enrolled with each payer for electronic claims.

SCAN THE CARDS, OR LET THE FRONT DESK DO IT
Insurance card, driver's license (reads the barcode) and SSN card are read on the phone with Google ML Kit. Photos are deleted after reading and only the last 4 SSN digits are kept. Front desk mode lets staff scan cards and update patient details on your phone while notes and billing stay hidden. It is free.

AFTER THE VISIT
A plain-language summary for the patient (what we found, medicines, what to do next, when to get help) to copy or text. Today shows notes signed, claims sent and an estimate of the time saved.

ORDERS FROM THE CONVERSATION
Labs, imaging, prescriptions and referrals said in the visit are listed for review. SOLIS does not connect to an EHR, lab or pharmacy.

PRIVACY
On-device mode keeps audio on the phone. Card photos are deleted after reading and the full SSN is never stored. SOLIS is built for HIPAA workflows, and a Business Associate Agreement template is available for practices.

PLANS
Notes on the phone are free and unlimited. SOLIS Pro is a Google Play subscription that sends claims, with a 14-day free trial. Cancel any time in Google Play.

TRY IT WITHOUT AN ACCOUNT
Tap "Use demo account" on the sign-in screen to try every screen with fictional patients.

SOLIS is in its pilot stage for US practices on Android 8 and later. CPT is a registered trademark of the American Medical Association.
---

Full description: 3,917 / 4,000 characters. It uses capitalized section headings because Play renders plain text;
no emojis, no "HIPAA compliant", no rankings. It names the free tier and the trial but no price, because the price
Google Play shows depends on the country; the price ($149 a month or $1,548 a year) is set in Play Console.
The CPT trademark line is there because the checks paragraph names CPT; keep or adjust it to match the AMA license
terms once you have one.

## Release notes for 1.1.0 (Play Console > the release > Release notes, en-US)

---
- A recording cut off by a call or a dead battery is kept and can resume.
- Tap any note sentence to see the words it came from.
- Templates for primary care, urgent care and psychiatry, plus note length.
- Confirm codes before sending, with an audit trail on every visit.
- Free front desk mode for scanning cards.
- Plain-language patient summary to copy or text.
- Notes are free; SOLIS Pro sends claims, with a 14-day free trial.
---

Release notes: 433 / 500 characters.

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

All screenshots are real app renders with fictional demo data (`screenshots/out`). They show version 1.0;
worth adding for 1.1: the sentence sources sheet, the note style sheet, the What SOLIS did for you card and
the patient summary. To regenerate:
`python marketing/play-store/graphics/render.py` (needs Google Chrome and Pillow).
