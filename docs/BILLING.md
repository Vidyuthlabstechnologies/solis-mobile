# SOLIS billing pipeline

From the patient's card to a claim a billing system can ingest.

## Flow

1. **Scan a card** (Patients, Scan card). Insurance card: on-device OCR reads payer, member ID, group, Rx BIN/PCN, payer ID and copays. Driver's license: the PDF417 barcode on the back gives exact name, date of birth, sex and address. Social Security card: name, plus the last 4 digits only; the full SSN is never stored.
2. **Account number.** Each patient gets one account, `SOL-` plus a sequence and a Luhn check digit (CMS-1500 box 26). A scan that matches an existing member ID, or the same name and date of birth, is offered to that account instead of creating a duplicate.
3. **Visits.** Each date of service is Visit 1, 2, 3 under the account, with its place of service. Claim ID is `<account>-V<n>`.
4. **Conversation.** Consent first, then recording. Live speech has no speaker labels, so each sentence is assigned to doctor or patient from how it is phrased.
5. **Coding** (`lib/services/coding/clinical_coder.dart`).
   - The patient's own words become symptom codes ("my feet burn at night" is R20.2).
   - Physician diagnoses are coded only when stated without hedging. Under ICD-10-CM outpatient guideline IV.H, "sounds like", "suspicious for", "consistent with" and similar mean the symptoms are coded instead. The diagnosis waits on the Claim tab for one-tap confirmation.
   - Symptoms that are part of a confirmed diagnosis are not coded separately (chest pain with STEMI).
   - The E/M code comes from the place of service (office, ED, inpatient, nursing facility, home, telehealth), new vs established (from the visit history), and medical decision making.
   - Ambulance (POS 41, 42) bills HCPCS A0427/A0429 plus A0425 mileage, never an E/M.
   - An EKG read in a facility bills 93010 (interpretation only); in the office, 93000. Tests that are only ordered are not billed by this provider.
6. **Claim checks** (`claim_scrubber.dart`). Errors block "Mark ready to bill":
   - every service line must link to a diagnosis in a compatible body system (a headache diagnosis cannot support an upper GI endoscopy)
   - sex conflicts (pregnancy codes on a male, prostate procedures on a female)
   - age conflicts (maternity 9 to 64, newborn codes, preventive visit age bands)
   - E/M family must match the place of service
   - missing DOB, sex, member ID, NPI or tax ID; unsigned note
   - Warnings: out-of-network payer, new-patient code on a return visit, telehealth modifier 95, missing charge, unspecified primary diagnosis.
7. **Export** (`claim_builder.dart`). The Claim tab's JSON button copies one document with CMS-1500 (02/12) boxes and the matching X12 837P loops (2010AA, 2010BA, 2010BB, 2300 CLM and HI, 2400 SV1 and DTP). Diagnosis pointers (box 24E, SV107) are filled in.

## Provider profile

Name, credentials, individual NPI (checked with the CMS Luhn rule), group NPI, EIN, specialty with NUCC taxonomy, practice address, usual place of service, accepted payers and fee schedule. Patients whose payer is not in the accepted list are flagged before billing.

## What the claim checks enforce

`ClaimScrubber.check` runs every rule of `knowledge/rules/rule_catalog.json`
that public CMS/CDC data supports (59 of 63 rules fully, see
`knowledge/GAP_REPORT.md`), offline, from the assets in `assets/codes/`.
Every finding carries a rule id and an official citation; the claim tab's
"Why" button shows the rule in plain English, its sources and the guideline
text. Each check is skipped silently when its data is not loaded.

- Code validity: edition for the date of service, full characters, 7th
  characters and placeholder X, duplicates.
- Tabular conventions: Excludes1 (error, with the "unrelated" exception),
  code first and manifestation sequencing, use additional code and code
  also suggestions, combination codes from the Alphabetic Index "with" and
  "acute and chronic" entries, acute before chronic, laterality (bilateral
  codes and the MCE edit 20 unspecified-side list), sequela order.
- Sequencing: external causes, secondary-only codes, first-listed-only Z
  codes, severe sepsis, symptoms before a related diagnosis or a malignancy,
  history codes first, preoperative (Z01.81-) and chemotherapy or radiation
  (Z51.-) encounters, pregnancy (Chapter 15 first, Z34 not with O codes, Z3A
  after the O code), poisoning, adverse effect and underdosing.
- Chapter rules: hypertension with heart failure or CKD (I11-I13), ESRD,
  diabetes Z79 drug codes, current cancer versus Z85 history, status Z codes
  already included in a complication code, injury aftercare and A versus D
  on follow-up visits, external cause place and status codes.
- MCE v44: age (newborn, pediatric, maternity, adult), manifestation not
  principal, unacceptable principal (error on hospital inpatient visits).
- NCCI: MUE per line and per date of service, add-on codes and their
  primaries, E/M with minor procedures (25), major procedures (57), XXX
  procedures with physician work (25), postoperative global periods using the
  patient's visit history (24), modifier 59 and XE/XS/XP/XU rules, the PFS
  bilateral indicator (modifier 50 and units), and repeated lab tests (91).
- Claim form data: signed note, patient, payer, NPI, tax ID, place of
  service, new versus established patient, telehealth, ambulance, charges.

The coder (`ClinicalCoder`) applies the same knowledge: Z79 drug codes from
documented medications, 7th character D for an injury already coded on an
earlier visit, combination codes, O codes first, code-first ordering,
Z01.81- for preoperative evaluations, and symptoms folded into a confirmed
diagnosis when an Excludes1 note says so.

## Known limits

- NCCI procedure-to-procedure and mutually exclusive edits (NCCI-PTP-01,
  NCCI-MUTEX-01), and the rules that depend on them (NCCI-FAMILY-01 and lab
  panel composition in NCCI-LAB-01), are license-blocked: CMS serves the PTP
  table only after the AMA CPT license click-through, so it is not bundled.
  `ClaimScrubber.ptpIssues` runs whenever `ReferenceData.ptp` is loaded (local
  internal-use build, or a shipped table once the owner holds an AMA CPT
  distribution license; build with `--ship-ptp`).
- Professional (837P) claims only. MCE edits are inpatient institutional
  edits; the app applies them to hospital inpatient visits of a professional
  claim. No POA indicators, no 837I.
- Sex edits are payer-configurable (warning by default, error with
  `enforceSexEdits`), because MCE v44 no longer publishes sex lists.
- Amounts are national Medicare PFS amounts (no GPCI, no multiple procedure
  or bilateral payment adjustment). Payer-specific edits (LCD/NCD coverage,
  commercial payer policies, frequency limits) are not bundled.
- The coder recognizes a fixed clinical vocabulary plus the Alphabetic Index;
  uncertain and index-suggested diagnoses always wait for the physician. Any
  other code is added from the offline ICD-10-CM search on the Claim tab,
  which shows the code's official notes.
- Card reading is tested against representative OCR text and AAMVA barcode
  data, not yet a wide set of real card photos; every field stays editable.
- Speaker separation for live speech is text-based; true voice diarization
  needs an audio-level model.
- The default fee schedule is a placeholder; set the practice's own charges.
- CPT descriptions in the app are short paraphrases, not AMA descriptors.
