# SOLIS facts sheet (source of truth for all marketing)

Every claim in the video, website, brochure and guide must come from this file
or from a cited public source. No invented numbers, customers, testimonials,
logos, awards, certifications, ratings or "trusted by" lines.

## One line
SOLIS listens to the visit, writes the note, and builds a clean claim, on the
doctor's phone.

## Who it is for
US physicians and small practices (primary care, urgent care, specialty
clinics, nursing-home rounds, ambulance/EMS), especially practices without a
big billing department.

## What it does (all real, shipped in v1.0.0)
- **Consent first.** Before recording, the patient hears a short script
  (English or Spanish) and agrees verbally or signs on the phone. Time and
  location are saved with the visit.
- **Ambient capture with speaker separation.** Tells the doctor's voice from the
  patient's. Two engines: on-device (no audio leaves the phone; one-time
  ~150 MB model download) or cloud (Deepgram medical model) when the practice
  turns it on.
- **The note writes itself.** Concise SOAP note. Claude writes it in cloud mode;
  an on-device engine works offline. Nothing is invented: no vitals or exam
  findings that were not said. Every diagnosis links to the words it came from.
- **Diagnosis codes from the patient's own words.** "My feet burn at night" is
  coded as a symptom until the doctor confirms a diagnosis (official
  outpatient rule IV.H). Uncertain wording waits for one-tap confirmation.
- **Procedure codes that match the diagnosis.** E/M level picked by place of
  service, new vs established patient and medical decision making.
- **Checks before the claim goes out**, against the official CMS code sets for
  the date of service (ICD-10-CM FY2026 and FY2027, HCPCS Oct 2026, 2026
  physician fee schedule, NCCI medically unlikely edits, NCCI add-on edits,
  Medicare Code Editor v44 age/maternity/manifestation lists, ICD-10-CM
  Excludes1 and 7th-character rules). 59 of 63 official coding rules fully
  enforced, each citing its guideline section. The other 4 (NCCI
  procedure-to-procedure pairs, NCCI mutually exclusive pairs, most
  comprehensive code, lab panels) need the AMA CPT license and are NOT in the
  app; say so plainly, never imply they are checked.
  Examples: sex and age conflicts, diagnoses that exclude each other
  (Excludes1), missing 7th character, external-cause codes listed first,
  modifier 25 needed, add-on code without its primary, units over the daily
  limit.
- **"Why" on every check.** Each claim check has a Why button that shows the
  rule in plain English, what it means on this claim, its official citation
  (e.g. ICD-10-CM Guidelines IV.H, Medicare Program Integrity Manual) and the
  official guideline text. Works offline (built into the app).
- **Official coding notes on each diagnosis.** Excludes1, Excludes2, Code
  first, Use additional code, Code also and 7th-character notes from
  ICD-10-CM, shown under the diagnosis with the code level they come from.
- **Orders from the conversation.** Labs, imaging, prescriptions, referrals
  and prior authorizations said in the visit are listed for review; the doctor
  checks them and marks them as sent. There is NO EHR, lab or pharmacy
  integration: never say orders are "sent to the EHR" or "sent to the
  pharmacy".
- **Scan the cards.** Insurance card, driver's license (reads the barcode) and
  SSN card, read on the phone with Google ML Kit. Photos are deleted after
  reading. Only the last 4 SSN digits are kept.
- **One account per patient, visits by date.** Account number with a check
  digit; Visit 1, 2, 3 each with its own date and place of service.
- **Eligibility at check-in and claims in one tap** through the Stedi
  clearinghouse (837P), plus claim status. Export as CMS-1500 data and 837P.
- **Real location** for the visit record (street address), never a fake one.
- **Provider profile:** name, NPI (looked up live in the national NPI
  registry), tax ID, specialty, insurers accepted.
- **Works offline** in on-device mode.

## Privacy and security (say exactly this, no more)
- Keys never ship inside the app; vendor keys live on the SOLIS server.
- Card photos deleted after reading; full SSN never stored.
- On-device mode keeps audio on the phone.
- A Business Associate Agreement (BAA) template is available for practices.
- Do NOT say "HIPAA certified", "HIPAA compliant", "SOC 2", "FDA", or
  "secure" as an absolute. Acceptable: "built for HIPAA workflows",
  "BAA available".

## Status (be honest)
- v1.0.0 Android app (Android 8+), pilot build, release-signed. iOS not yet released.
- APK download (public, R2): https://pub-a4cd4562d8434c128924f6e463c0e0a6.r2.dev/solis-1.0.0.apk
  version 1.0.0, 149,686,135 bytes (149.7 MB), SHA-256
  3c313f9c19e6af1aebf8e6a57cc4595157f2ca68600b6a89f86864e2f9a0c46a.
  Update marketing/site/tools/apk.json when a new build is uploaded.
- Pilot stage: say "Join the pilot" / "Request early access", not "used by".
- CPT descriptions require an AMA license; do not show CPT descriptor text
  as if licensed.

## Pain points you may cite (with the source, link on website/brochure)
Use only statistics you verify from the primary source at build time
(AMA, Annals of Internal Medicine, Health Affairs, MGMA, CMS, AAFP). Put the
source under the number. Examples to look up, not to quote blindly:
- Physicians spend about 2 hours on EHR/desk work for every hour of patient
  time (Sinsky et al., Annals of Internal Medicine, 2016).
- After-hours "pajama time" documentation (AMA / Annals studies).
- Claim denial rates and cost to rework a denied claim (verify a current
  source such as MGMA or a CMS/industry report).

## Brand
- Name: SOLIS (all caps in the wordmark).
- Color: SOLIS Orchid #980F86; deep #4E0044; container #FDE2F6;
  dark-mode accent #E5A3E8; near-white #FFF8FD. Avoid red/amber/green as
  brand colors (they mean status in the app).
- Logo: the Split Sun mark, files in assets/brand/ (svg and png).
- Type: Roboto in the app; for marketing use a clean grotesk (Inter or
  Manrope from Google Fonts) with Roboto Mono for codes.
- Voice: plain, confident, doctor-to-doctor. No hype words ("revolutionary",
  "magic"). Show, don't claim.

## App screenshots
Real renders of the app with demo data: screenshots/out/*.png
(412x915 logical at 2x). The demo patient on the sample cards is the
fictional Jordan A Rivera; the demo practice data is fictional.

## Links
- Backend: https://cloudflare-healthcare-rcm-agentic-cloud.cbvarshini1.workers.dev
- Contact / CTA: "Request early access" (form or mailto: vidyuthlabs@gmail.com
  only if the founder approves showing it; default to a form placeholder that
  says "Request early access").
