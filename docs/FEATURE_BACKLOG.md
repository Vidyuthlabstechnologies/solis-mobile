# SOLIS feature backlog: 200 missing features

Prepared 2026-11-06 against `solis-mobile` at 1.0.2+3 (commit 8c153ff), the
docs in `docs/`, and `docs/UX_REVIEW.md`. Items the 1.0.1 and 1.0.2 releases
already shipped (practice setup, demo-only sample data, Today/Billing tabs,
offline claim queue, ambulance 837P, real level meter, TalkBack record
button, declined consent, note seal, one-tap fixes, E/M one-tap change) are
not listed again.

**Priority.** P0 = wrong data, compliance or lost work. P1 = large time
saving or a gap a paying practice will hit in week one. P2 = polish,
access, reach. P3 = larger bets.
**Effort.** S = under a day, M = 1 to 4 days, L = more than a week.
**Needs.** `app` = can be built in this repo alone. `worker` = needs the
SOLIS Worker (separate repo). `vendor` = needs a vendor account or contract.
`license` = needs a data license (for example AMA CPT).

**Status.** `B1`, `B2`, ... = the build batch that shipped it. Blank = open.

Build order: P0 `app` items first, then P1 `app` items by journey (visit,
end of day, check-in), then the `worker` items once the Worker repo is in
scope. Items needing a vendor contract, a BAA or a license wait on the
owner.

---

## A. Correctness and compliance (18)

| # | Feature | Pri | Eff | Needs | Status |
| --- | --- | --- | --- | --- | --- |
| 1 | In-app version label read from the build (About says 1.0.0 on 1.0.2) | P0 | S | app | B1 |
| 2 | Correct the CMS CR 14429 transmittal named in code comments (R13967OTN to R13977OTN) | P0 | S | app | B1 |
| 3 | Corrected and void claims: CLM05-3 frequency code 7/8 with REF*F8 payer claim number | P0 | M | app | B1 |
| 4 | Void a sent claim from the visit (frequency 8) | P1 | S | app | B2 |
| 5 | Timely-filing warning (Medicare 12 months from date of service; payer-configurable) | P0 | S | app | B1 |
| 6 | Date-of-service sanity checks: no future DOS, no DOS before birth date | P0 | S | app | B1 |
| 7 | Patient age vs code checks surfaced at visit start, not only in the scrubber | P1 | S | app | |
| 8 | NCCI PTP edits once a CPT license is in place (4 open catalog rules) | P1 | M | license | |
| 9 | Medically Unlikely Edit per-day vs per-line distinction shown in Why | P2 | S | app | |
| 10 | LCD/NCD coverage hints for common Medicare tests | P2 | L | app | |
| 11 | ABN (Advance Beneficiary Notice) prompt and GA/GZ modifiers | P1 | M | app | |
| 12 | Telehealth: POS 02/10 and modifier 95/93 chosen from the visit mode | P1 | M | app | |
| 13 | Rendering vs billing vs supervising provider (incident-to) on the claim | P1 | M | app | |
| 14 | Referring provider NPI (2310A) for specialties and tests that need it | P1 | S | app | B5 |
| 15 | Prior authorization number field (REF*G1) on the claim | P1 | S | app | B5 |
| 16 | CLIA number (REF*X4) for in-office lab lines | P2 | S | app | |
| 17 | Attestation text versioned and stored with every signature | P1 | S | app | B7 |
| 18 | Retention policy: records kept per state rules, with a purge report | P2 | M | app | |

## B. Visit capture and recording (17)

| # | Feature | Pri | Eff | Needs | Status |
| --- | --- | --- | --- | --- | --- |
| 19 | Leave the visit screen while recording (RecordingController, UX item 22) | P1 | L | app | |
| 20 | Reminder when a recording stays paused for more than 5 minutes | P2 | S | app | |
| 21 | Voice commands: start, pause, finish (UX item 24) | P2 | M | app | |
| 22 | Haptic cues on start, stop and "no sound" | P2 | S | app | |
| 23 | Remember microphone settings (noise suppression, language) between visits | P2 | S | app | |
| 24 | Show the on-device draft at once, replace with the cloud note when ready (UX item 25) | P1 | M | app | |
| 25 | Stop waiting for the cloud note and use the on-device draft | P1 | S | app | B4 |
| 26 | Replace the hard-coded small-talk filter with a configurable list (UX item 27) | P2 | S | app | |
| 27 | Upload an audio file recorded elsewhere (dictation) | P2 | M | app | |
| 28 | Dictation mode for a note without a patient conversation | P1 | M | app | |
| 29 | Interpreter as a third speaker role | P2 | S | app | |
| 30 | More consent languages (Vietnamese, Chinese, Tagalog, Arabic) | P2 | M | app | |
| 31 | Read the consent script aloud to the patient (UX item 37) | P2 | M | app | |
| 32 | Transcript search and jump-to-time | P2 | S | app | |
| 33 | Recording length and battery estimate before a long visit | P3 | S | app | |
| 34 | Bluetooth / external microphone picker | P2 | M | app | |
| 35 | Auto-stop after a configurable silence (for example 3 minutes) | P2 | S | app | |

## C. Notes and documentation (22)

| # | Feature | Pri | Eff | Needs | Status |
| --- | --- | --- | --- | --- | --- |
| 36 | Addendum after signing, sealed separately (UX item 26) | P0 | M | app | B5 |
| 37 | Share the signed note to another app (Android share sheet) | P1 | S | app | |
| 38 | Share the note as PDF | P1 | M | app | |
| 39 | Note templates per visit type (annual, follow-up, procedure, telehealth) | P1 | M | app | |
| 40 | Personal phrases / smart text (dot phrases) | P1 | M | app | |
| 41 | Specialty note styles (SOAP, APSO, H&P, procedure note) | P2 | M | worker | |
| 42 | Patient-friendly after-visit summary from the plan | P1 | M | app | |
| 43 | After-visit summary in Spanish | P2 | M | worker | |
| 44 | Structured ROS and exam checklists with "normal" defaults | P2 | M | app | |
| 45 | Problem list carried across visits | P1 | M | app | |
| 46 | Medication list carried across visits, with changes per visit | P1 | M | app | |
| 47 | Allergy list with "no known allergies" as an explicit state | P1 | S | app | B4 |
| 48 | Vitals trend view (BP, weight, BMI) | P2 | M | app | |
| 49 | Time-based documentation: total time on date of service, for E/M by time | P1 | S | app | B2 |
| 50 | Co-signature workflow for NPs and PAs | P2 | M | worker | |
| 51 | Scribe-edit history: who changed what in the draft | P2 | M | app | |
| 52 | Inline "unsupported statement" flags where a note line has no source | P1 | M | app | |
| 53 | Edit-to-teach: remember a clinician's frequent corrections | P3 | L | worker | |
| 54 | Pre-charting: draft the HPI from the last visit before the patient arrives | P2 | M | app | |
| 55 | Work/school excuse letter from the visit | P3 | S | app | |
| 56 | Procedure note fields (site, laterality, consent, complications) | P2 | M | app | |
| 57 | Word count and reading time on the note, to spot bloat | P3 | S | app | |

## D. Coding (19)

| # | Feature | Pri | Eff | Needs | Status |
| --- | --- | --- | --- | --- | --- |
| 58 | G2211 visit-complexity add-on suggestion for longitudinal care | P1 | S | app | B2 |
| 59 | E/M by total time (99202-99215 time thresholds) alongside MDM | P1 | S | app | B2 |
| 60 | Prolonged services (99417 / G2212) when time exceeds the top level | P1 | S | app | B2 |
| 61 | Preventive visits (99381-99397) and the modifier 25 split with a problem visit | P1 | M | app | |
| 62 | Medicare Annual Wellness Visit (G0438/G0439) and its required elements | P1 | M | app | |
| 63 | Chronic care management (99490, 99491) monthly time tracking | P2 | L | app | |
| 64 | Transitional care management (99495/99496) after discharge | P2 | M | app | |
| 65 | HCC / risk adjustment flags for chronic conditions not coded this year | P2 | M | app | |
| 66 | Favorite codes per clinician | P1 | S | app | B7 |
| 67 | Recent codes list on code search | P1 | S | app | B1 |
| 68 | Laterality and 7th-character pickers in code search | P2 | S | app | |
| 69 | Show why the E/M level was picked, element by element (UX item 20 remainder) | P1 | S | app | B7 |
| 70 | Coding notes filtered to the codes on this claim (UX item 40) | P2 | S | app | |
| 71 | Vaccine and injection admin codes paired with product codes | P2 | M | app | |
| 72 | In-office lab and POCT codes with QW modifier | P2 | S | app | |
| 73 | Modifier helper (25, 59, XS/XU, 76, 77, LT/RT) with plain-language reasons | P1 | M | app | |
| 74 | Social determinants Z codes (Z55-Z65) suggested from the conversation | P2 | S | app | |
| 75 | Specialty code packs (urgent care, pediatrics, behavioral health) | P3 | L | app | |
| 76 | Coding confidence shown per code | P2 | S | app | |

## E. Claims and billing (22)

| # | Feature | Pri | Eff | Needs | Status |
| --- | --- | --- | --- | --- | --- |
| 77 | Secondary and tertiary claims (COB loop 2320/2330) after primary pays | P1 | L | app | |
| 78 | Payer list with payer IDs (search, not typed by hand) | P1 | M | vendor | |
| 79 | Per-payer fee schedules (not only Medicare PFS) | P1 | M | app | |
| 80 | Practice charge master: the practice's own prices per code | P1 | S | app | B5 |
| 81 | Patient responsibility estimate (copay, deductible) at check-out | P1 | M | app | |
| 82 | Superbill PDF for self-pay or out-of-network patients | P1 | M | app | |
| 83 | Self-pay visits that skip the claim | P1 | S | app | |
| 84 | Status refresh every few hours while the app stays open | P2 | S | app | B4 |
| 85 | Automatic status polling with notifications (UX item 30) | P1 | M | app | |
| 86 | 277CA acknowledgement handling through webhooks (Big idea D) | P1 | L | worker | |
| 87 | 835 ERA posting: paid amount, adjustments, patient responsibility | P1 | L | worker | |
| 88 | Payment posting by hand for paper EOBs | P2 | M | app | |
| 89 | Claim history timeline per visit (built, sent, accepted, paid) | P1 | S | app | B3 |
| 90 | Plain-language 277 status category explanations | P1 | S | app | B1 |
| 91 | Claim notes: a free-text note on a claim for the biller | P2 | S | app | |
| 92 | Workers' comp and auto claims (property and casualty fields) | P3 | L | app | |
| 93 | Place-of-service facility address (2310C) from saved places | P1 | S | app | B6 |
| 94 | Line-item date of service for multi-day services | P2 | S | app | |
| 95 | Claim print preview as CMS-1500 PDF | P2 | M | app | |
| 96 | Accounts receivable aging (0-30, 31-60, 61-90, 90+) | P1 | M | app | B3 |
| 97 | Daily and monthly billed vs paid totals | P2 | S | app | B3 |
| 98 | CSV export of claims for an outside biller | P1 | S | app | B1 |

## F. Denials and revenue cycle (12)

| # | Feature | Pri | Eff | Needs | Status |
| --- | --- | --- | --- | --- | --- |
| 99 | Plain-language CARC denial reasons with the likely fix (UX item 31); shown once 835 posting (87) lands | P1 | M | app | B1 |
| 100 | Denial work queue on the Billing tab, oldest first | P1 | S | app | B3 |
| 101 | Corrected-claim flow from a denial (pre-filled, frequency 7) | P1 | M | app | B2 |
| 102 | Appeal letter draft from the denial and the note | P2 | M | worker | |
| 103 | Denial trends by payer and reason | P2 | M | app | |
| 104 | Eligibility recheck before resubmitting a denial for coverage | P1 | S | app | |
| 105 | Write-off with a reason code and approval | P2 | S | app | |
| 106 | Patient statements (text or email link) | P2 | L | vendor | |
| 107 | Online patient payment link | P3 | L | vendor | |
| 108 | Collection reminders for unpaid patient balances | P3 | M | vendor | |
| 109 | Rejected-claim auto-fix where no clinical judgment is needed | P1 | M | app | |
| 110 | Payer-specific rejection tips learned from past rejections | P3 | M | app | |

## G. Patients and check-in (18)

| # | Feature | Pri | Eff | Needs | Status |
| --- | --- | --- | --- | --- | --- |
| 111 | One scanner session for all cards with automatic card type (UX item 11) | P1 | M | app | |
| 112 | Short review form and a fixed Save button (UX item 12) | P1 | S | app | |
| 113 | Pre-select the matching patient and scroll to the choice (UX item 13) | P1 | S | app | B6 |
| 114 | Quick "unidentified patient" for EMS and ED (UX item 34) | P1 | S | app | B2 |
| 115 | Merge two patient accounts | P1 | M | app | B6 |
| 116 | Patient list sorting (name, last visit) and filters (status, payer) | P1 | S | app | B1 |
| 117 | Patient photo for identity check | P2 | S | app | |
| 118 | Guarantor / responsible party when the patient is a minor | P1 | M | app | B6 |
| 119 | Emergency contact | P2 | S | app | |
| 120 | Preferred language and interpreter-needed flag | P1 | S | app | B5 |
| 121 | Pronouns and preferred name | P2 | S | app | |
| 122 | Address validation and ZIP+4 | P2 | S | app | |
| 123 | Phone and email validation with tap-to-call | P2 | S | app | |
| 124 | Patient self check-in by QR code on a lobby tablet | P3 | L | worker | |
| 125 | Insurance card expiry / plan year reminder | P2 | S | app | |
| 126 | Patient intake questionnaire (PHQ-9, GAD-7) scored in the app | P2 | M | app | |
| 127 | Bulk restore and permanent delete in Recently deleted | P3 | S | app | |
| 128 | Patient-level documents (referrals, outside records) attached by photo | P2 | M | app | |

## H. Day workflow and scheduling (12)

| # | Feature | Pri | Eff | Needs | Status |
| --- | --- | --- | --- | --- | --- |
| 129 | Appointment schedule (time slots) feeding the Today list | P1 | L | app | |
| 130 | Calendar import (Google or ICS) for appointments | P2 | M | app | |
| 131 | Rounds mode for nursing homes and hospitals (Big idea C) | P1 | L | app | |
| 132 | "Finish and next patient" in rounds | P1 | M | app | |
| 133 | Geofence prompt: "At Sunrise SNF. Start rounds?" (Big idea B) | P2 | M | app | |
| 134 | End-of-day summary: unsigned notes, unsent claims, open orders | P1 | S | app | B3 |
| 135 | Unsigned-note reminder notification | P1 | S | app | |
| 136 | Orders follow-up: results expected, overdue | P2 | M | app | |
| 137 | Task list for the clinician (call patient, review lab) | P2 | M | app | |
| 138 | Search across all visits by diagnosis, code or text | P2 | M | app | |
| 139 | Visit duration analytics per visit type | P3 | S | app | |
| 140 | Home-screen widget showing today's count and unsigned notes | P3 | M | app | |

## I. Practice, team and sync (12)

| # | Feature | Pri | Eff | Needs | Status |
| --- | --- | --- | --- | --- | --- |
| 141 | Encrypted practice sync across devices (Big idea E) | P1 | L | worker | |
| 142 | Roles: physician, front desk, biller | P1 | L | worker | |
| 143 | Invite a team member by email | P1 | M | worker | |
| 144 | Multiple clinicians per practice, each with their own NPI | P1 | M | app | |
| 145 | Multiple practice locations | P2 | M | app | |
| 146 | Clearinghouse setup held by the practice, not the phone (UX item 10) | P1 | M | worker | |
| 147 | Confirm before switching the clearinghouse to Production | P0 | S | app | B1 |
| 148 | Confirm before removing a key on Integrations | P1 | S | app | B1 |
| 149 | Restore the practice profile on a new phone (PUT /api/v2/practice) | P1 | M | worker | |
| 150 | Subscription and billing page inside the app (see PRICING.md) | P2 | M | worker | |
| 151 | Usage meter: visits this month vs plan | P2 | S | worker | |
| 152 | Practice-level settings (default consent method, note style) | P2 | S | app | |

## J. Security and privacy (14)

| # | Feature | Pri | Eff | Needs | Status |
| --- | --- | --- | --- | --- | --- |
| 153 | App lock with biometrics or device PIN | P0 | M | app | |
| 154 | Auto-lock after inactivity (default 5 minutes) | P0 | S | app | |
| 155 | Privacy mode: initials only on the Today and Patients lists | P2 | S | app | |
| 156 | Local data encrypted at rest with a key in the keystore | P0 | M | app | |
| 157 | Audit log viewer: who opened, edited, signed, sent | P1 | M | app | |
| 158 | Export the audit log for a HIPAA access request | P2 | S | app | |
| 159 | Patient record export (right of access) as PDF and FHIR | P1 | M | app | |
| 160 | Remote wipe of a lost phone | P2 | M | worker | |
| 161 | Session list and sign out other devices | P2 | M | worker | |
| 162 | Two-factor sign-in | P1 | M | worker | |
| 163 | Password reset in the app | P1 | S | worker | |
| 164 | Break-glass access log for a patient outside the clinician's panel | P3 | M | worker | |
| 165 | Redact SSN and other identifiers from transcripts before upload | P1 | S | app | B7 |
| 166 | Clear the clipboard after copying PHI (60 s) | P1 | S | app | B1 |

## K. Accessibility, layout and polish (14)

| # | Feature | Pri | Eff | Needs | Status |
| --- | --- | --- | --- | --- | --- |
| 167 | Follow the system light/dark theme and remember the choice (UX item 36) | P2 | S | app | B1 |
| 168 | Reflow at 200% text with golden tests (UX item 35) | P2 | M | app | |
| 169 | Tablet two-pane layout (UX item 39) | P2 | L | app | |
| 170 | Landscape support on tablets | P2 | S | app | |
| 171 | Keyboard shortcuts for front desk and billers | P3 | M | app | |
| 172 | High-contrast mode | P2 | S | app | |
| 173 | Reduce motion setting respected | P2 | S | app | |
| 174 | Screen reader labels on every status tag and chart chip | P2 | S | app | |
| 175 | Pull-to-refresh on Today and Billing | P2 | S | app | |
| 176 | Empty states with one clear next action on every list | P2 | S | app | |
| 177 | In-app help and glossary for billing terms (ISA, POS, MBI) | P2 | S | app | |
| 178 | First-run tour of the visit flow | P3 | S | app | |
| 179 | Spanish UI (app localization) | P2 | L | app | |
| 180 | What's new sheet after an update | P3 | S | app | |

## L. Reliability, offline and operations (10)

| # | Feature | Pri | Eff | Needs | Status |
| --- | --- | --- | --- | --- | --- |
| 181 | Local backup and restore (encrypted file) | P1 | M | app | |
| 182 | Crash reporting without PHI | P1 | M | vendor | |
| 183 | In-app "Send feedback" with device info and no PHI | P2 | S | app | |
| 184 | Diagnostics screen: code-set versions, engine, network, storage | P2 | S | app | |
| 185 | Recovery of a recording interrupted by a crash | P0 | M | app | |
| 186 | Retry with backoff for eligibility and NPI lookups when offline | P2 | S | app | |
| 187 | Storage cleanup of old audio and models | P2 | S | app | |
| 188 | Startup time budget and a loading screen while code sets load | P3 | S | app | |
| 189 | Continuous integration running analyze and tests on every PR | P1 | S | app | B1 |
| 190 | iOS build and TestFlight pipeline | P2 | L | vendor | |

## M. Website, marketing and integrations (10)

| # | Feature | Pri | Eff | Needs | Status |
| --- | --- | --- | --- | --- | --- |
| 191 | Website: pricing page matching PRICING.md, with a plan comparison | P1 | S | app | |
| 192 | Website: security and HIPAA page (BAA, data flow) | P1 | S | app | |
| 193 | Website: pilot sign-up form | P1 | M | worker | |
| 194 | Website: changelog page generated from CHANGELOG.md | P3 | S | app | |
| 195 | FHIR R4 write to an EHR (Epic, athena) for signed notes | P2 | L | vendor | |
| 196 | e-Prescribing (Surescripts) | P3 | L | vendor | |
| 197 | Lab orders and results (HL7 / Quest, Labcorp) | P3 | L | vendor | |
| 198 | Fax referrals and records | P3 | M | vendor | |
| 199 | Zapier-style webhook when a claim is paid or denied | P3 | M | worker | |
| 200 | Public API for practices with their own EHR | P3 | L | worker | |

---

## Batch plan

- **B1** (shipped): 1, 2, 3, 5, 6, 67, 90, 98, 99, 116, 147, 148, 166, 167, 189.
- **B2** (shipped): 4, 49, 58, 59, 60, 101, 114.
- **B3** (shipped): 89, 96, 97, 100, 134.
- **B4** (shipped): 25, 47, 84.
- **B5** (shipped): 14, 15, 36, 80, 120.
- **B6** (shipped): 93, 113, 115, 118.
- **B7** (shipped): 17, 66, 69, 165.
- **B8** (shipped, next-version brief step 1): recordings saved every 5
  seconds and when the app leaves the foreground, with "Continue recording"
  after a kill or crash; every note sentence linked to its transcript line,
  and sentences with no source highlighted. See
  docs/NEXT_VERSION.md.
- **B9** (next-version brief step 2): the clinician must tick the E/M
  level and codes before a claim is billed, and any later code change needs
  a new confirmation (the send service blocks it). There is a per-visit
  audit trail (signed, confirmed, codes changed, sections edited, sent or
  rejected) that can be copied for an auditor, and one-tap fixes on rejected
  or denied claims.
- **B10** (next-version brief step 3): notes and visits are free and
  unlimited; the paywall appears only when a real claim is billed (Send,
  Mark ready, Sign and send, batch send; test claims stay free). The
  paywall leads with "Notes are free. SOLIS Pro sends the claim." and an
  example billing-service comparison. Settings shows the trial end or
  renewal date. 14-day trial, $149 / $1,548 confirmed.
- **B11** (next-version brief step 4): note style on the provider profile
  (template SOAP, primary care, urgent care or psychiatry; length brief,
  standard or detailed; abbreviations as written, spelled out or
  abbreviated), a Style chip on the note with "Rewrite this note". Urgent
  care adds return precautions as said; psychiatry quotes mood, sleep,
  appetite and concentration and reports safety questions as answered.
  Diagnoses removed from a psychiatry claim stay ruled out for the patient
  and are never coded again.
- **B12** (next-version brief step 5): "What SOLIS did for you" on Today
  (notes signed, claims sent and amount billed, today and the last 7 days,
  with an estimated time saved labeled as an estimate), and a plain-language
  patient summary from the signed note (what we found, medicines, what to
  do next, when to get help) to copy or text to the patient.
- **B13** (rest of the next-version brief): free front desk mode (staff
  scan cards and edit patient details on the clinician's phone, notes and
  billing hidden, PIN to leave, stays on across restarts), trial-ending
  reminder on Today in the last 3 days, Play listing and release notes for
  1.1.0, version 1.1.0+4. Trial email plan in docs/TRIAL_EMAIL.md (needs the
  Worker).
- **Next**: 7, 12, 61, 45, 46, 83, 104. 135 needs a local-notification
  plugin, and 153/154 (app lock) a biometric plugin; both are held for a
  decision.
- **B5 onward**: the remaining `app` items by priority; `worker`, `vendor`
  and `license` items once those are in place.
