# SOLIS LinkedIn post series (5 posts)

Claims come only from `marketing/FACTS.md`. Statistics carry their source in
the post. Suggested cadence: one post every 3 to 4 days. Attach the matching
carousel slide (`marketing/kit/carousel/`) or the full carousel on post 1.
No hashtag walls; two or three at most.

---

## Post 1. The problem, in published numbers

For every hour a physician spends face to face with patients, about two more go to the EHR and desk work. Then another 1 to 2 hours at night.

That is not a feeling. It is from a time-and-motion study of 57 physicians in four specialties (Sinsky et al., Annals of Internal Medicine, 2016, doi.org/10.7326/M16-0961).

We built SOLIS for the physicians and small practices who end up doing that work themselves, including the coding.

SOLIS listens to the visit, writes the note, and builds a clean claim, on the doctor's phone.

It is an Android app in its pilot stage. If your practice does not have a big billing department, we would like to hear from you: solis-health.pages.dev

#physicians #primarycare

---

## Post 2. Consent first

The first screen of every SOLIS visit is not the record button.

It is a short script the patient hears, in English or Spanish. The patient agrees out loud or signs on the phone, and the time and location are saved with the visit. If the patient declines, nothing is recorded.

Several states require all-party consent to record a conversation. We would rather ask every time than guess.

Join the pilot: solis-health.pages.dev

---

## Post 3. "My feet burn at night"

A patient says: "My feet burn at night."

Many tools would jump to a diagnosis. SOLIS codes it as a symptom until the doctor confirms a diagnosis, which is what the official outpatient coding rule says (ICD-10-CM Guidelines, section IV.H). If the doctor says "sounds like" or "consistent with", the diagnosis waits on the Claim tab for a one-tap confirmation.

Every diagnosis in SOLIS links to the words it came from, so checking it takes a glance, not a search through a transcript.

solis-health.pages.dev

---

## Post 4. Every check explains itself

Before a claim goes out, SOLIS checks it against the official CMS code sets for the date of service: ICD-10-CM FY2026 and FY2027, HCPCS October 2026, the 2026 physician fee schedule, NCCI medically unlikely and add-on edits, and Medicare Code Editor v44.

59 of 63 official coding rules are fully enforced, each citing its guideline section. The other 4 need the AMA CPT license, and they are not in the app. We would rather say that than imply they are checked.

Tap Why on any check and you see the rule in plain English, what it means on this claim, its official citation and the guideline text. It works offline.

Why it matters: in an MGMA Stat poll (March 5, 2024, 235 responses), 60% of medical group leaders said their denial rates rose in early 2024 compared with the same period in 2023.

solis-health.pages.dev

---

## Post 5. Your practice decides where the audio goes

Two engines, one choice for the practice:

On-device. Speech recognition and speaker separation run on the phone. No audio leaves the device, and it works offline after a one-time download of about 150 MB. Useful on nursing-home rounds and in an ambulance, away from Wi-Fi.

Cloud. The Deepgram medical model transcribes and Claude writes the note, only when the practice turns it on.

Either way, vendor keys never ship inside the app, card photos are deleted after reading, and only the last 4 digits of an SSN are kept. SOLIS is built for HIPAA workflows, and a Business Associate Agreement template is available.

We are inviting practices to the Android pilot now: solis-health.pages.dev/get-started
