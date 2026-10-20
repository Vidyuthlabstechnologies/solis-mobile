# Cold email templates for practice managers (3)

Rules: claims only from `marketing/FACTS.md`; no invented customers or
results; one clear ask; plain text, no tracking images. Send only to business
addresses, include the sender's physical mailing address and an opt-out line
(CAN-SPAM). Replace everything in [brackets].

---

## 1. The front desk and the claim

**Subject:** Notes and claims on one phone at [Practice name]

Hi [First name],

Do your physicians end up coding their own visits? SOLIS is an Android app that listens to the visit (after the patient agrees), writes the note, and builds the claim on the doctor's phone.

At the front desk, it reads the insurance card and the driver's license barcode, deletes the photos after reading, and checks eligibility through the Stedi clearinghouse. After the visit, the claim is checked against the official CMS code sets for the date of service and sent as an 837P in one tap, or exported as CMS-1500 data for your billing system.

We are in a pilot with an Android build, a demo account with fictional patients, and test-mode claims, so nothing is billed until your payer enrollment is done. Would a 20-minute look at the demo be useful for you and one of your physicians?

[Your name]
SOLIS, solis-health.pages.dev
[Mailing address]. Reply "no thanks" and I will not write again.

---

## 2. Denials

**Subject:** Catching claim problems before they leave

Hi [First name],

In an MGMA Stat poll (March 5, 2024, 235 responses), 60% of medical group leaders said claim denials rose in early 2024 compared with 2023.

SOLIS checks each claim before it goes out: sex and age conflicts, diagnoses that exclude each other, a missing 7th character, modifier 25, add-on codes without their primary, units over the daily limit, and more. 59 of 63 official coding rules are fully enforced, each with its citation; the 4 that need the AMA CPT license are not in the app, and we say so. A Why button on every check shows the rule and the guideline text, which helps when a coder and a physician disagree.

Could I send you the user guide, or show the Claim tab on a call with your billing lead?

[Your name]
SOLIS, solis-health.pages.dev
[Mailing address]. Reply "no thanks" and I will not write again.

---

## 3. Privacy-minded practices

**Subject:** An ambient scribe where the audio can stay on the phone

Hi [First name],

If recording visits has been a hard sell with your physicians or compliance lead, SOLIS has an on-device mode: speech recognition and speaker separation run on the phone, no audio leaves it, and it works offline. A cloud mode (Deepgram medical model and Claude) is there only if the practice turns it on.

Every recording starts with a consent script in English or Spanish, with the time and location saved. Vendor keys never ship in the app, and a Business Associate Agreement template is available. Our security page lists what is in place today and what is still in progress: solis-health.pages.dev/security

We are inviting a small number of practices to the Android pilot. Would you like the details?

[Your name]
SOLIS, solis-health.pages.dev
[Mailing address]. Reply "no thanks" and I will not write again.
