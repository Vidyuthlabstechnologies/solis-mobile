# CMS HIPAA EDI front-end edits, October 2026 (CR 14429)

What changed in the Medicare front-end (CCEM) edits for October 2026, which of
them SOLIS's 837P and 276 could violate, and what SOLIS does about each.

Re-checked 2026-10-21 against the live watcher (`GET /v1/transmittals?relevant=1&current=1`,
last CMS check 2026-10-20 06:17 UTC): R13977OTN is still the current transmittal for CR 14429.
Implemented in app 1.0.2 (`lib/services/billing/cms_edi_edits.dart`, tests in
`test/cms_edi_oct2026_test.dart`).

## The transmittal

| | |
| --- | --- |
| Change request | CR 14429, "Health Insurance Portability and Accountability Act (HIPAA) Electronic Data Interchange (EDI) Front End Updates for October 2026" (Pub. 100-20, One-Time Notification) |
| Effective | October 1, 2026 (date of service unless an edit says otherwise) |
| Implementation | October 5, 2026 |
| Current transmittal | **R13977OTN**, September 28, 2026: https://www.cms.gov/medicare/regulations-guidance/transmittals/2026-transmittals/r13977otn (PDF https://www.cms.gov/files/document/r13977otn.pdf, spreadsheets https://www.cms.gov/files/zip/r13977otn-1-6.zip) |
| Replaced | R13865OTN (July 10), R13934OTN (August 27), **R13967OTN** (September 18; fixed two typos in the 276/277 edits spreadsheet). R13977OTN rescinds and replaces R13967OTN "to update the 276/277 flat file attachment. All other information remains the same." |

The founder's note named R13967OTN; it has since been replaced by R13977OTN.
Both were read for this review: the 625-page R13967OTN PDF (the edits
spreadsheets are printed in it) and the six spreadsheets of R13977OTN. The
837P change logs and every row with an October 2026 date are identical in the
two.

### What the attachments are, and who runs them

The spreadsheets are instructions to the Medicare Administrative Contractors
(Part A/B MACs, through their translators and the Combined Common Edits /
Enhancements Module) and to CEDI, the DME MAC front end. They apply to files
**received by Medicare**. Commercial payers and Medicare Advantage plans do
not run them. Through a clearinghouse (Stedi), the clearinghouse re-envelopes
the claim before it reaches the MAC, so the envelope edits apply to the
clearinghouse's file, not to ours; the claim-content edits still apply to
what we send. SOLIS applies the relevant ones to **Medicare Part B claims**
(claim filing indicator MB, `CmsEdiEdits.isMedicarePartB`).

| File in r13977otn-1-6.zip | Content | Relevant to SOLIS |
| --- | --- | --- |
| R13977_OTN1.xlsx | 837P edits, Part A/B MACs (version EB20264V01): 837-P, Change Log, Edit Rules | Yes: SOLIS sends 837P to Part B |
| R13977_OTN4.xlsx | 837P edits, CEDI (DME MACs, version CE20264V01) | Only for DMEPOS supplier claims, which SOLIS does not send |
| R13977_OTN2.xlsx | 276/277 edits (version ECS202604V01) | Yes: SOLIS sends 276 claim status requests |
| R13977_OTN6.xlsx | 276/277 flat file layout (MAC translator to CCEM) | No: internal MAC layout |
| R13977_OTN3.xlsx, R13977_OTN5.xlsx | 837I flat file layout (institutional) | No: institutional only |

The 837I edits spreadsheet (version EA20264V01) is printed in the R13967OTN
PDF (pages 179 to 332). There are no 270/271, 835 or standalone 999
spreadsheets in this CR; TA1 and 999 acknowledgment behavior is defined inside
each edits spreadsheet (the "TA1/999/277CA" and "Disposition / Error Code"
columns).

## 837P (Part A/B MAC) edits new or changed this release

Edit ids are CMS's (`X222.<TR3 page>.<loop>.<segment/element>.<edit number>`).
All are "Revised 10/5/2026" except the deactivations. Rule ids in SOLIS are
`CMS-EDI-<edit id>` with citation "CMS CR 14429 (R13977OTN)".

| Edit | Loop / element | Rule (as of 10/5/2026) | Ack / error code | SOLIS |
| --- | --- | --- | --- | --- |
| X222.079.1000B.NM109.060 | 1000B NM109 receiver ID | 1000B.NM109 must equal GS03; now rejected at the translator instead of later in the CEM | 999 R, IK403 = I12 | **Checked.** `Claim837PGenerator.build` refuses a Medicare claim when a receiver ID is configured (direct-to-MAC setup) and it differs from GS03. Through a clearinghouse (no receiver ID: 1000B carries the payer ID, as Stedi requires) the clearinghouse's envelope is what the MAC checks. Test: `cms_edi_oct2026_test.dart` |
| X222.157.2300.CLM Loop.010 | 2300 loop | Only 100 iterations of the 2300 loop per transaction (number format fixed) | 999 R, IK304 = 4 | Not violable: SOLIS sends one claim per interchange |
| X222.157.2300.CLM11-2.010 | CLM11-2 related causes | If CLM11-2 is present, CLM11-1 must be present | 999 R, IK403 = 2 | Not violable: SOLIS never sends CLM11 (test asserts CLM ends at CLM09) |
| X222.226.2300.HI01.010, X222.239.2300.HI01.010, X222.242.2300.HI01.010 | 2300 HI | Deactivated (edit was invalid: no accept/reject or error code) | none | Nothing to do. The diagnosis HI edits that remain (ABK present once, no periods, principal not V/W/X/Y, no duplicates) were already met: periods stripped, codes de-duplicated, ICD-EXTCAUSE-01 blocks an external cause first |
| X222.272.2310C.N3.010, X222.273.2310C.N4.010 | 2310C service facility address | If 2310C NM1 is present, N3 and N4 must be (loop reference corrected) | 999 R, IK304 = I6 | Not violable: SOLIS does not send 2310C |
| X222.299.2320.CAS01.010 / .020 | 2320 CAS01 (other payer adjustments) | CAS01 present and a valid group code (error code corrected) | 999 R, IK403 = 1 / 7 | Not violable: SOLIS sends no secondary-payer (2320) loops |
| X222.313.2330A.NM103.010, X222.319.2330A.REF01.020 | 2330A other subscriber | NM103 present; REF01 must be "SY" (loop reference corrected) | 999 R | Not violable: no 2330A |
| X222.351.2400.SV101-7.020 | 2400 SV101-7 description | SV101-7 must be present when the procedure code is on the CMS table of codes that require a description | 277CA C, CSCC A8, CSC 306 | **Checked and generated.** `CmsEdiEdits.requiresServiceDescription`: unlisted CPT codes (ending in 99, plus 99429) and HCPCS codes whose official descriptor says not otherwise classified, NOS, unclassified, unlisted or miscellaneous (182 HCPCS codes in the October 2026 file). The generator sends the line description as SV101-7 (X12 basic characters, at most 80, edit .030). Medicare claim with no description: scrubber error `CMS-EDI-X222.351.2400.SV101-7.020` (fix: "Describe the service" opens the line editor, which now has a "What was done" field for these codes) and the generator refuses to build; a description that only repeats the code's wording is a warning. Other payers: generator warning only. CMS does not publish its table; this is the published-descriptor approximation |
| X222.415.2400.PS101.020 | 2400 PS1 purchased service | PS101 must equal 2420B NM109 or REF02 (VA MRA bypass note added) | 999 R, IK403 = I12 | Not violable: no PS1 / 2420B |
| X222.434.2420A.REF04-2.020, X222.452.2420D.REF04-2.020 | 2420A/2420D REF04-2 | Must equal 2330B NM109 (format) | 999 R, IK403 = I12 | Not violable: no 2420x loops |
| X222.449.2420D.NM1.020, X222.465.2420F.NM1.020, X222.470.2420G.NM1.020, X222.475.2420H.NM1.020 | 2420D/F/G/H NM1 | If the line-level loop is present, the matching claim-level loop (2310D/A/E/F) must be | 999 R, IK304 = I6 | Not violable: no 2420x loops (ambulance pick-up and drop-off are sent once at claim level, 2310E/2310F) |
| X222.460.2420E.REF01.010, X222.468.2420F.REF01.020 | 2420E/2420F REF01 | REF01 must be "1G" (Medicare) | 277 T | Not violable: no 2420E/F |
| X222.480.2430.SVD03-4/-5/-6.010, X222.480.2430.SVD06.030 | 2430 line adjudication | Modifier order; SVD06 1-6 digits | 999 R / 999 E | Not violable: no 2430 (secondary claims) |
| X222.492.2440.LQ.010 | 2440 form identification | Deactivated | none | Nothing to do |

The "not violable" rows are guarded by a test (`never sends the loops whose
edits changed this quarter but SOLIS does not use`): no CAS, SVD, LQ, FRM,
PS1, OI or MOA segment, one SBR, no NM1*77/DN/DK/DQ/QB on an office claim, and
CLM ends at CLM09. If SOLIS later adds secondary billing (2320/2330/2430),
referring or ordering providers (2310A/2420E-F) or a service facility (2310C),
these edits must be enforced then.

### Existing Medicare 837P edit also enforced now

| Edit | Rule | SOLIS |
| --- | --- | --- |
| X222.121.2010BA.NM109.020 | For Medicare, 2010BA NM109 must be an MBI (11 characters, C A AN N A AN N A A N N; no S, L, O, I, B, Z) | Scrubber error `CMS-EDI-X222.121.2010BA.NM109.020` on Medicare Part B claims (fix: rescan the Medicare card). Dashes printed on the card are ignored |

## 837P edits for CEDI (DME MACs) only

These are in R13977_OTN4.xlsx and apply to DMEPOS supplier claims sent to
the DME MACs. SOLIS bills professional services to Part B MACs, not DME, so
they are listed for completeness and not enforced:

- X222.351.2400.SV104.070 / .080: capped rental DME or PEN pump units must be
  1 or 2; with 2 units the line needs RT and LT.
- X222.380.2400.DTP03.080 / .090: RD8 service date ranges with a future end
  date only for listed supply categories; first date equals second date unless
  E0935/E0936, glucose monitor supply or inexpensive supply. (SOLIS sends a
  single D8 date.)
- X222.423.2410.LIN03.040 and X222.426.2410.CTP05-1.030: an NDC must map to a
  HCPCS code categorized as oral anti-cancer, injectable or PEN
  immunosuppressive; CTP05-1 must be "UN". (SOLIS does not send 2410.)
- X222.468.2420F.REF01.010 / .020, the CEDI copies of the A/B changes above,
  and the 2440 LQ/FRM deactivations (several dated January 6, 2025).

## 837I (institutional) edits

Institutional only; SOLIS does not send 837I. Changed this release (R13967OTN
PDF, 837I spreadsheet): X223.068..BHT.020 and BHT01.020; X223.094.2010AB.NM101.010;
HI01.010 deactivations at X223.187/189/193/218/220/239/242/271/284/294/304,
X223.239.2300.HI01-2.025 and X223.258.2300.HI01-1.010 (deactivated);
X223.220.2300.HI09-2.030 (no period); X223.258.2300.HI03-3/HI04-3.010 (RD8);
X223.344.2310E.N3.010, X223.345.2310E.N4.010; X223.352.2310F.REF.030;
X223.390/392/393/394/395.2330B.REF (other payer references);
X223.471.2420D.NM109.050; X223.474.2420D.REF01.020;
X223.476.2430.SVD03-1/-4/-5/-6 and SVD06.040; X223.480.2430.CAS11.010.

## 276 claim status request

SOLIS sends 276 requests through Stedi's JSON API (`StediClient.claimStatusBody`);
Stedi writes the X12. The 276/277 spreadsheet changes this release are
corrections only (column and loop references for 2200D AMT01, 2200D REF01 for
BLT and 6P, 2200D REF 1K iterations, GE.020 and SE.020 error codes,
2100B NM104.050, and the 277 STC08/STC09 mapping that R13967OTN fixed). The
flat file layout changes in R13977OTN (2200D payer claim control number,
monetary filler fields) are internal to the MACs.

Checked against the full 276 edit set, SOLIS now:

| Edit | Rule | SOLIS |
| --- | --- | --- |
| X212.49/126.2100C.NM109.020 | Provider NPI valid by the NPI algorithm | Checked before sending (all payers) |
| X212.49/126.2100C.NM103.010 | Provider name present | Body sends the practice name, or the clinician's first and last name when there is no practice name |
| X212.56/135.2100D.NM103.010, NM104.010 | Subscriber last and first name (first name required by CMS) | Checked |
| X212.56/135.2100D.NM109.010 / .020 | Member ID present; for Medicare an MBI | Checked; dashes removed from the MBI in the body |
| X212.54/NA.2000D.DMG02.010 / .030 | Birth date present and not in the future (Medicare) | Checked |
| X212.54/NA.2000D.DMG03.010 | Gender present (Medicare) | Body now sends `gender`; checked for Medicare |
| X212.67/155.2200D.DTP03.020 / .040 | Valid service date; range end not before start | Checked |
| X212.60/150.2200D.REF.020 | REF*BLT (bill type) not allowed for Part B | Never sent |
| X212.66/NA.2200D.AMT01.020 | AMT01 must be T3 when AMT is sent | AMT not sent (optional) |

When any of these fails, `StediClient.claimStatus` returns the problems (each
with its CMS edit id and the citation) without calling Stedi.

## ICD-10-CM FY2027 by date of service

The same quarter brings ICD-10-CM FY2027 (effective October 1, 2026, by
date of service). SOLIS now bundles the Tabular-note assets of both editions
(`icd10cm_excludes1_<FY>`, `icd_7th_<FY>`, `icd_notes_<FY>`; FY2026 is parsed
from the April 1, 2026 code tables zip by `tool/build_code_assets.py`), and
every claim check, coding run and coding-notes view uses the edition of the
visit's date of service (`ReferenceData.atDateOfService`): 2026-09-30 is
checked against FY2026, 2026-10-01 against FY2027. Before this change only the
code list and Index followed the date; Excludes1, code-first notes and 7th
characters were always FY2027. Tests: `test/icd_fy_boundary_test.dart`
(T52.8X1A valid on 9/30 and ICD-VALID-01 on 10/1; I42.0 billable on 9/30 and
ICD-BILLABLE-01 naming I42.00/I42.01 on 10/1; R26.2 with R26.81 an Excludes1
conflict on 9/30 only).

## Watching for the next one

solis-codesets-worker polls the CMS transmittal listing and RSS feed daily and
tags claim-relevant transmittals (`GET /v1/transmittals?relevant=1&current=1`;
`replaced_by` marks rescinded ones). The Integrations Code sets card shows the
newest five under "Recent CMS updates". The next HIPAA EDI front-end CR is
expected in late October or November for January 2027.
