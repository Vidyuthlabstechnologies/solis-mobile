# SOLIS mobile UX review

Prepared 2026-10-17. Reviewed as a US family physician seeing 20 to 25 visits a day (clinic, one nursing-home afternoon a week) and as a front-desk/billing person checking patients in. Sources: every render in `screenshots/out/` (01 to 21), `lib/screens/*.dart`, `lib/widgets/*.dart`, `lib/main.dart`, `docs/DESIGN.md`, `docs/BILLING.md`, `docs/ONBOARDING.md`, `docs/LAUNCH_COMPLIANCE.md`, `marketing/FACTS.md`.

Line numbers refer to the code as read on 2026-10-17. Another worker was editing `lib/` at the same time, so re-check line numbers before editing. The screenshots also lag the code in places: `01_sign_in.png` shows an "Organization code" field and a "Process notes on this device" switch that `lib/screens/login_screen.dart` does not have.

Tap counts are estimates from walking the code paths. In-scanner taps (Google ML Kit document scanner: shutter, add page, save) are estimated at about 2 per side.

---

## 1. Executive summary

The single-visit core works and looks calm: record, a draft note with Sources, a claim with checks and a Why for each one. The problems are everything around that core.

1. **Real accounts start with fictional data.** A clinician who signs up gets the demo provider "Sarah Lin, NPI 1982736450, EIN 84-1234567" (`provider_profile.dart:62-76`, `account_repository.dart:56`) and five demo patients (`main.dart:19`, `account_repository.dart:273`). Nothing asks them to set up their practice, so their first real claim would go out under a fictional NPI and tax ID. This is the most serious defect in the review.
2. **Some controls and indicators are not real.** The room noise filter and language/accent picker do nothing (`encounter_screen.dart:66-76, 1581-1599`). The recording level meter is a sine animation that moves even when the microphone hears nothing (`encounter_widgets.dart:210-245`). The note's "SIG-SHA256" seal is a constant plus a timestamp (`encounter_screen.dart:603`). All of these break the design rule against fabricated data, and the fake meter hides a dead microphone, which loses the visit.
3. **Each visit takes about 13 taps and 3 confirmation dialogs once recording ends** (sign, mark ready, send, orders). The physician also has to go looking for problems: "See Checks below" (`claim_tab.dart:78`) and the disabled "Fix 1 issue first" button (`encounter_screen.dart:2132`) say what is wrong but give no fix button.
4. **There is no day-level view.** The patient list shows only the last visit number (`patients_screen.dart:449-493`). Nothing lists unsigned notes, claims ready to send, rejected claims or denied claims. Claim status is one button per visit (`encounter_screen.dart:506`). Ten patients means about 60 taps at the end of the day just to check status.
5. **Setting changes are manual every visit.** Place of service is picked in a dialog at every visit start (`patient_chart_screen.dart:60-113`). The location fix is taken but never used. In every screenshot the location chip stays on "Locating". The note engine resets to cloud on every visit (`encounter_screen.dart:74`). Nursing-home rounds and EMS cost about 3x the taps of a clinic visit.
6. **EMS claims cannot pass a payer.** The 837P builder writes no ambulance CR1 segment and no pickup or drop-off loops (`x12_837p.dart`). Mileage defaults to 1 unit, which only raises a warning (`clinical_coder.dart:496`, `claim_scrubber.dart:605`).
7. **The front desk cannot share data with the physician.** Patients and visits live only on one phone (`AccountRepository` local files). A front-desk person scanning cards on a second device cannot hand the patient to the physician's phone. No layout serves billers either: the app is portrait-only (`main.dart:30-33`), has no two-pane screens and no keyboard shortcuts.
8. **Accessibility gaps:** the 96dp record button may not respond to TalkBack (`encounter_widgets.dart:185-189`). Several rows do not reflow at 200% text size. The theme ignores the system light/dark setting.

The top 10 items in section 3 remove the false-data risks and cut a clinic visit from about 13 taps after recording to about 6. A 10-patient nursing-home round drops from about 160 taps to about 64.

---

## 2. Journeys: taps now vs proposed

"Typed" counts text fields filled by hand. "Decisions" counts choices the user must make that the app could default.

| # | Journey | Now: taps / typed / decisions / dialogs | Proposed: taps / typed / decisions / dialogs | Main changes (item numbers in section 3) |
| --- | --- | --- | --- | --- |
| 1 | First launch and setup, real clinician | about 20 / 14 / 10 / 0, and nothing prompts it | about 7 / 2 / 3 / 0 | 1, 2, 9, 10 |
| 2 | New patient walks in: scan cards, create account, start visit 1 | about 12 + 3 scrolls / 1 / 2 / 1 | about 6 / 0 / 0 / 0 | 11, 12, 13, 14, 16 |
| 3 | Full visit: consent, record, stop, review, claim, fix, sign, send claim, orders | 13 / 0 / 4 / 3 | 6 / 0 / 1 / 1 | 17, 18, 20, 25 |
| 4 | Returning patient, visit 2 | 16 + search typing / 0 / 4 / 4 | 7 / 0 / 1 / 1 | 14, 16, 28, 31 |
| 5 | End of day, 10 visits: unsent claims, status, denials | about 60 (open every patient) / 0 / 10 / 0 | about 3, plus 3 per denial | 28, 29, 30, 32 |
| 6 | Nursing-home rounds, 10 residents | about 160 / 0 / 30 / 30 | about 64 / 0 / 2 / 11 | 14, 15, 22, Big idea C |
| 7 | Ambulance/EMS, patient without a card | about 22 / 6 / 5 / 3, and the claim is still incomplete | about 10 / 0-1 / 2 / 1 | 8, 15, 34 |
| 8 | Offline visit (no signal in the building) | +2 taps per visit (engine toggle) and +4 per claim later (resend by hand) | 0 extra | 21, 33 |

### 2.1 Journey 1: first launch and setup
Now (code path):
1. Login (`login_screen.dart`). "Request access" leads to sign-up (`sign_up_screen.dart`): name, email, password, NPI (optional), then Create account. This lands directly on Patients (`sign_up_screen.dart:568`).
2. The Patients screen shows five fictional patients. The avatar shows "SL" (Sarah Lin, the demo provider). No banner asks for practice setup.
3. To fix the identity: tap the avatar, replace the demo NPI, tap "Look up" (manual, `provider_profile_screen.dart:193`), then fill in tax ID, practice name (an individual-NPI lookup does not fill it), specialty dropdown, usual place of service dropdown, about 5 payer chips and the screenshot-blocking switch, scroll down and tap Save.
4. Open the menu, then Integrations: paste a Stedi API key and type submitter name, submitter ID, receiver ID, contact and phone (`integrations_screen.dart:121-158`), then Save. A physician does not know what an ISA receiver ID is.
5. The demo patients cannot be deleted. There is no delete-account action for patients in `account_repository.dart`.

Friction: the setup is hidden, the defaults are fictional, and the jargon is billing staff's, not a physician's. Error risk: claims sent with the demo NPI, EIN and address (box 24J, 25, 33).

Proposed: the sign-up NPI drives an automatic NPPES lookup. Show a one-screen "Your practice" form, prefilled from NPPES, before Patients is reachable. Integrations come from the SOLIS server (practice key vault). Demo data appears only in demo mode.

### 2.2 Journey 2: new patient walks in
Now:
1. "Scan card" FAB.
2. Choose the "Insurance" segment, tap Scan, then front and back in the scanner (about 4 taps).
3. Switch to the "License" segment, tap Scan, scan the back (about 2 taps).
4. Scroll a 25-field form (`03_scan_review.png`). Type the phone number.
5. "Create account" is at the bottom of the ListView (`scan_card_screen.dart:437-446`).
6. On the chart, tap "Start today's visit", then "Start visit" in the dialog (date and POS).

Error risk: if a duplicate patient is found, Save shows a snackbar asking the user to choose (`scan_card_screen.dart:201-204`) but does not scroll to the choice. Eligibility runs only after "Start visit", silently, and its result appears only on the chart (`patient_chart_screen.dart:117`), not on the visit. The front desk misses copay collection.

### 2.3 Journey 3: a full visit
Now (connected clearinghouse, no edits, one uncertain diagnosis, `encounter_screen.dart`):

| Step | Taps | Notes |
| --- | --- | --- |
| Record (96dp button) | 1 | `06_ready.png` |
| Consent sheet: "Patient agreed, start recording" | 1 | `16_consent.png` |
| Finish and write note | 1 | `07_recording.png` |
| Wait: "Writing the note" spinner, no cancel or timeout | 0 | `encounter_screen.dart:2031-2052` |
| Review 4 SOAP cards (scroll) | 0 | `08_note.png` |
| Sign note, then confirm dialog | 2 | `encounter_screen.dart:1397-1411` |
| Claim tab | 1 | |
| Scroll to "Waiting for your confirmation", Confirm diagnosis | 1 | `10_claim_checks.png` |
| Mark ready to bill | 1 | `encounter_screen.dart:2129-2133` |
| Send claim, then confirm dialog | 2 | `encounter_screen.dart:452-466` |
| Orders tab, Send N orders, confirm | 3 | `17_orders.png` |
| **Total** | **13 taps, 3 dialogs** | |

Proposed: Record, Agreed, Finish. The on-device draft appears at once and the cloud version replaces it when ready. Confirm the diagnosis inline from the note's coding summary. One "Sign and send" sheet covers the attestation, claim total, codes, check result and a "Mark N orders as sent" checkbox. That makes 6 taps and 1 dialog.

### 2.4 Journey 4: returning patient
Now: type in the search box, tap the patient, "Start today's visit", the dialog's "Start visit", then journey 3. The ready screen shows nothing about the last visit (diagnoses, medications, plan, pending tests). Eligibility is not rechecked unless a clearinghouse is set up and the visit is started. Proposed: a Today list on the home screen, no start dialog, and a "Since last visit" card on the ready screen.

### 2.5 Journey 5: end of day
Now: no queue. For each patient: open the chart, open the visit, Claim tab, "Check claim status", back twice. That is about 6 taps per visit. Status matching takes the first claim for the date of service (`encounter_screen.dart:512-523`), which can pick the wrong claim when two visits share a date. A denial shows a free-text status only (`encounter_screen.dart:550-561`). Proposed: a Billing tab that groups visits by state and polls status automatically, with notifications and batch send.

### 2.6 Journey 6: nursing-home rounds (10 residents)
Now, per resident: find the patient (2), Start visit (1), change POS 11 to 31/32 in the dropdown (2; changing the profile default instead breaks clinic days), Start (1), Record (1), consent (1; a representative signature adds about 4), Finish (1), Sign plus confirm (2), Claim tab (1), Mark ready (1), Send plus confirm (2). That is about 16 taps per resident and about 160 in total. Leaving the screen while recording is blocked (`encounter_screen.dart:1690`), so the next resident cannot be queued. Proposed: Rounds mode (Big idea C).

### 2.7 Journey 7: ambulance/EMS
Now: the patient often has no card, so "Add patient without a card" means typing first name, last name, DOB and sex. Then POS 41 has to be picked from the dropdown. After recording, the A0425 line has units = 1 and the miles must be typed by hand. No origin/destination modifiers exist and pickup/drop-off addresses are not captured, so the 837P lacks the CR1 segment and loops 2310E/2310F. The GPS fix the app already takes is not used for mileage.

### 2.8 Journey 8: offline
Now: the engine defaults to Cloud on every visit (`encounter_screen.dart:74`). When offline, the cloud call fails and a snackbar says the note was written on the phone (`encounter_screen.dart:651`). That works, but it costs a wait and a message. "Send claim" fails with "Could not reach the clearinghouse" (`encounter_screen.dart:499`) and nothing queues it. NPI lookup and silent eligibility also fail. Sign-in restore works offline (`main.dart:24-26`).

---

## 3. Ranked changes

Priority: P0 = wrong data or lost work; P1 = large time savings; P2 = polish and access. Effort: S (under 1 day), M (1 to 4 days), L (more than 1 week). "Backend" = needs work on the SOLIS Worker or a vendor.

### P0: correctness, false data, lost visits

**1. Real accounts must not inherit the demo provider identity**
- Screen/file: `lib/services/account_repository.dart:56, 136`; `lib/models/provider_profile.dart:62-76`; `lib/screens/sign_up_screen.dart:561-568`; `lib/screens/login_screen.dart:50`.
- Problem: `_provider = ProviderProfile.demo()` is the starting profile for everyone. Sign-up sends the NPI to the server but never fills the local profile. `05_provider.png` shows "Sarah Lin, 1982736450, 84-1234567, Bayview Family Medicine" as editable defaults. Every claim box 24J, 25 and 33 would carry fictional data.
- Change:
  - Add `ProviderProfile.empty()` and `bool get isComplete` (valid NPI, valid EIN, practice name, address, ZIP).
  - Use `demo()` only from `AuthService.startDemo()`.
  - After `register()` or `login()`, if `!provider.isComplete`, push `ProviderProfileScreen(firstRun: true)`. It has no back button and its title is "Set up your practice", and it gates `/patients`.
  - If the signed-up NPI exists, call `NpiRegistry().lookup` on open and prefill.
  - Add a scrubber error `CLAIM-PROVIDER-01` when `provider.npi == ProviderProfile.demo().npi` outside demo mode.
- Effort: M. Risk: low. Backend: optional (`PUT /api/v2/practice` from ONBOARDING step 4, to restore the profile on a new phone).

**2. Seed demo patients only in demo mode, and label them**
- Screen/file: `lib/main.dart:19`; `lib/services/account_repository.dart:273-300`; `lib/screens/scan_card_screen.dart:560-568` ("Try a sample card"); `encounter_screen.dart:1905-1914` ("Sample conversation").
- Problem: `seedDemoIfEmpty()` runs before auth is known, so a real clinician's list (`02_patients.png`) starts with five fictional patients, and none of them can be deleted.
- Change:
  - Move seeding into `AuthService.startDemo()`.
  - Add `bool isSample` to `PatientAccount` and set it for seeded accounts.
  - Show a neutral `StatusTag(label: 'Sample')` on the tile and chart.
  - Make the scrubber raise an error ("Sample patient, cannot be billed") for sample accounts outside demo mode.
  - Hide "Try a sample card" unless in demo mode.
  - Add "Delete patient" to the chart overflow menu (confirm dialog, as DESIGN requires for destructive steps).
- Effort: S. Risk: low. Backend: no.

**3. Remove or wire the fake controls, and drive the level meter from real audio**
- Screen/file: `lib/screens/encounter_screen.dart:66-76` (`_languageModes`, `_isNoiseFilterActive`), `1581-1599` (Session details); `lib/widgets/encounter_widgets.dart:210-245` (`LevelMeter`).
- Problem: grep shows `_isNoiseFilterActive` and `_selectedLanguageMode` are only read by their own switches. "Indian English / Accent" and "Southern / Regional US" change nothing. `LevelMeter` animates fixed sine peaks whenever `active`, so a muted or failed microphone still looks like it is recording (`07_recording.png`). The physician finds out after a 15-minute visit.
- Change:
  - Delete the noise filter switch and the language list. Alternatively, wire "Spanish + English" to the Deepgram `language=multi` parameter and Android `localeId: 'es-US'`, and delete the rest.
  - Feed `LevelMeter` a `ValueListenable<double>` level: `speech_to_text` `onSoundLevelChange` in `_listen()` (`encounter_screen.dart:853`), and an `amplitude` stream from `TranscriptionProvider` for the Deepgram and on-device engines.
  - If the level stays under the noise floor and no transcript arrives for 10 s, show `StatusTag('No sound', warning, Icons.mic_off)`, a haptic `HapticFeedback.heavyImpact()` and the text "SOLIS hears nothing. Check the microphone."
- Effort: M. Risk: medium (needs a plugin API for amplitude on the native engine). Backend: no.

**4. Make the record button work with TalkBack**
- Screen/file: `lib/widgets/encounter_widgets.dart:185-189`.
- Problem: `Semantics(button: true, label: 'Start recording', excludeSemantics: true)` drops the InkWell's tap action and gives no `onTap` of its own. A TalkBack double-tap is likely to do nothing; verify on a device.
- Change: add `onTap: onPressed` to the `Semantics`. Add a widget test with `tester.semantics` and `SemanticsAction.tap`.
- Effort: S. Risk: none. Backend: no.

**5. Save order changes, and make "checked" mean one thing**
- Screen/file: `lib/screens/encounter_screen.dart:2450, 2458` (row tap and checkbox), `2481` ("Sent" tag), `1423-1463` (Send N orders).
- Problem: ticking an order calls `setState` without `_persist()`, so it is lost on leaving the screen. A tick also instantly labels the order "Sent" with no confirmation, while the bottom button asks for one. Two paths with different meanings sit on one screen (`17_orders.png`).
- Change:
  - Checkbox means "include in this send". Store `included` on `ClinicalActionItem`, default true for STAT and urgent orders.
  - The bottom button marks the included orders as sent, persists, and shows a snackbar "4 orders marked as sent" with an Undo action.
  - The row tag reads "Marked sent" (FACTS.md: there is no integration).
  - Call `_persist()` after every change.
- Effort: S. Risk: low. Backend: no.

**6. Record a declined consent**
- Screen/file: `lib/screens/encounter_screen.dart:1070, 1131-1134`.
- Problem: "Patient declined" closes the sheet and saves nothing. The visit audit trail cannot show that the patient was asked and refused, and the next tap on Record asks again.
- Change:
  - Pop with `ConsentRecord(method: 'declined', atUtc, language, location)` and save it.
  - The Ready screen then shows the icon `Icons.do_not_disturb_on_outlined` with "Patient declined recording at 10:42", makes "Type instead" the primary FilledButton, and hides the record button behind "Ask again".
- Effort: S. Risk: low. Backend: no.

**7. Keep the consent signature pad from scrolling or dismissing the sheet**
- Screen/file: `lib/screens/encounter_screen.dart:1013-1025` (bottom sheet with `SingleChildScrollView`, drag enabled); `lib/widgets/signature_pad.dart`.
- Problem: vertical pen strokes compete with the sheet's scroll view and drag-to-dismiss. A downward stroke can close the sheet and lose the signature. Verify on a device. No "Clear" control is visible next to the pad.
- Change:
  - `showModalBottomSheet(enableDrag: !signing, isDismissible: !signing, ...)`.
  - While signing, wrap the pad in a widget that claims vertical drags (for example `RawGestureDetector` with an eager `VerticalDragGestureRecognizer`), or use `physics: NeverScrollableScrollPhysics()`.
  - Add `TextButton.icon(Icons.refresh, 'Clear')` wired to the existing `clear()`.
- Effort: S. Risk: low. Backend: no.

**8. Make ambulance claims complete**
- Screen/file: `lib/services/billing/x12_837p.dart` (no CR1, CRC or NM1*PW/NM1*45 loops); `lib/services/coding/clinical_coder.dart:496`; `lib/services/coding/claim_scrubber.dart:605`; Claim tab.
- Problem: payers reject ground ambulance 837P claims without CR1 (transport reason, loaded miles), the pickup loop 2310E and the drop-off loop 2310F, and origin/destination modifiers (for example RH, HR) on A0427/A0429. Mileage defaults to 1 unit with only a warning.
- Change:
  - For POS 41/42, add a "Transport" SectionCard to `ClaimTab`: origin and destination code (two dropdowns of the CMS one-letter codes, combined into the modifier), pickup address, drop-off address and loaded miles.
  - Prefill the addresses from the GPS reverse-geocoded address at record start and at Finish (`_currentGps['address']`). Prefill miles from a GPS track sampled every 15 s while recording (sum of segment distances, rounded up to 0.1 mile); every value stays editable.
  - Make missing miles or addresses an error.
  - Emit CR1 and loops 2310E and 2310F.
- Effort: L. Risk: medium (837P conformance; test against the Stedi validator). Backend: no.

### P1: fewer taps, more automation

**9. Look up the NPI automatically**
- Screen/file: `lib/screens/provider_profile_screen.dart:182-196`.
- Problem: a valid NPI still needs a tap on "Look up". A practice name is not filled for an individual NPI.
- Change: in `onChanged`, when `isValidNpi` becomes true, debounce 400 ms and call `_lookupNpi()`. Keep the button as "Look up again". After an individual lookup, if the NPPES response has an organization affiliation or the practice location name, fill `practiceName`. Otherwise focus the field.
- Effort: S. Risk: low. Backend: no (or use the `/api/npi` proxy from ONBOARDING).

**10. Take clearinghouse setup off the physician's phone**
- Screen/file: `lib/screens/integrations_screen.dart:121-158` (API key, submitter name/ID, receiver ID, contact, phone), `129` and `183` ("Remove key" with no confirm), `131-138` (Production switch with no confirm).
- Problem: a physician cannot know an ISA receiver ID. Raw keys on phones contradict FACTS.md ("Keys never ship inside the app; vendor keys live on the SOLIS server"). Removing a key or switching to Production is one stray tap.
- Change:
  - The phone shows `Clearinghouse: Connected through your practice` or `Not set up. Your practice admin connects it.`
  - Calls go through the Worker, which holds the key and submitter config per practice.
  - Keep the local key form behind an "Advanced, single-clinician pilot" ExpansionTile.
  - "Remove key" shows a SnackBar with Undo (keep the old key in memory for 5 s).
  - Switching to Production opens a confirm dialog: "Claims will go to payers for payment. Payer enrollment complete?"
- Effort: M. Risk: medium. Backend: yes (claims, eligibility and status proxied by the practice).

**11. One scanner session for all cards, with automatic card type**
- Screen/file: `lib/screens/scan_card_screen.dart:281-289, 510-531`; `lib/services/card_scanner.dart:139-145` (`pageLimit: 2`, type chosen first).
- Problem: the user must pick Insurance, scan, then pick License, then scan again.
- Change:
  - The FAB opens the ML Kit document scanner immediately with `pageLimit: 4`.
  - Classify each page: a PDF417 barcode decoded means a license (authoritative). OCR containing "SOCIAL SECURITY" means an SSN card. Otherwise it is insurance; pair front and back by the presence of "Rx BIN|PCN|Payer ID" on the back.
  - Keep the segmented control only as "Rescan one card" on the review screen.
  - Show a `StatusTag` per source, as today.
- Effort: M. Risk: medium (classification errors; every field stays editable). Backend: no.

**12. Short review and a fixed save button**
- Screen/file: `lib/screens/scan_card_screen.dart:302-447` (about 25 fields in one ListView, save at the end), `03_scan_review.png`.
- Problem: the front desk scrolls past fields the scan already filled to reach "Create account". Missing required data (DOB, sex, member ID, payer ID) is not called out.
- Change:
  - Put the primary action in `bottomNavigationBar`: "Create account and start visit". Add a secondary "Create account".
  - Top of the form: a "Needs attention" card listing missing or low-confidence fields (DOB, sex, payer ID, member ID), each tapping to focus its field.
  - Collapse "Pharmacy (Rx)" and "Identity documents" into ExpansionTiles that start closed when they are filled.
  - Use `TextInputType.phone` with the US mask `(###) ###-####`.
- Effort: M. Risk: low. Backend: no.

**13. Pre-select the matching patient and scroll to the choice**
- Screen/file: `lib/screens/scan_card_screen.dart:200-204, 303-309`.
- Problem: Save with a possible duplicate only shows a snackbar.
- Change:
  - If exactly one match has the same member ID or the same name and DOB, set `_matchChoice` to it on scan. The panel stays visible and reads "Add to Margaret Vance (selected)".
  - On Save without a choice, `Scrollable.ensureVisible` the match panel and give a light haptic.
- Effort: S. Risk: low (still visible and changeable). Backend: no.

**14. Start a visit without the dialog**
- Screen/file: `lib/screens/patient_chart_screen.dart:58-118`.
- Problem: every visit opens an AlertDialog for date and place of service, both usually defaults.
- Change:
  - "Start today's visit" creates the visit immediately with today's date and POS chosen in this order: (a) a saved Place matching the GPS fix (item 15), (b) this patient's last visit POS if it was within 30 days, (c) the profile default.
  - On the Ready screen, show the POS as an `ActionChip(Icons.place_outlined, 'Office (11)')` that opens the existing POS sheet (`claim_tab.dart:274`).
  - Move "Visit for another date" to the chart overflow menu.
- Effort: S. Risk: low (POS still shown and changeable before the claim). Backend: no.

**15. Saved places set POS and facility, and the location chip resolves**
- Screen/file: `lib/screens/encounter_screen.dart:149, 153-164` ("Locating" forever when no fix arrives, as in every screenshot); `provider_profile_screen.dart` (only one "Usual place of service").
- Change:
  - Add `List<SavedPlace>` to `ProviderProfile`: name, address, POS, lat, lng, radius (default 150 m), plus a facility NPI for SNFs.
  - "Save this place" appears in Session details when a fix exists.
  - On visit open, if the fix is inside a place, set POS and the service facility (2310C).
  - Time out "Locating" after 15 s to "No location" (still `available: false`, no guessed value).
- Effort: M. Risk: low (location only suggests; the user sees the POS chip). Backend: no.

**16. Run eligibility automatically and show it on the visit**
- Screen/file: `lib/screens/patient_chart_screen.dart:117, 125-170, 187-237`; `04_chart.png` ("Connect a clearinghouse in Integrations").
- Problem: the check runs only on "Start visit", silently. The result is shown on the chart, not on the visit or claim. Expired coverage is found after the claim is denied.
- Change:
  - Run `_checkEligibility(silent: true)` when an account is created or a card is rescanned, and when the chart opens if the last check is older than 24 h.
  - Move the function to a service (`EligibilityService`) so the encounter can call it.
  - Show one line on the Ready screen and in the Claim tab "Visit" card: `Icons.verified_outlined Active, copay $25 to collect`.
  - Add a scrubber warning "Coverage not verified for this date" and an error when `active == false`.
- Effort: M. Risk: low. Backend: the item 10 proxy if keys move to the server.

**17. Merge sign, ready and send into one step**
- Screen/file: `lib/screens/encounter_screen.dart:2114-2152` (four primary-button states), `564-569` (Mark ready), `1391-1421` (sign dialog), `452-466` (send dialog).
- Problem: three confirmations and a "Mark ready to bill" state that does nothing when a clearinghouse is connected.
- Change:
  - On the Note tab, the primary button is "Review and sign" when there are 0 claim errors. It opens one bottom sheet with:
    - the attestation text (`encounter_screen.dart:1403`);
    - the claim summary (claim ID, primary diagnosis, services, total);
    - the check result;
    - a CheckboxListTile "Mark 4 orders as sent";
    - one FilledButton: "Sign and send claim" when connected, or "Sign and mark ready" when not.
  - When there are claim errors, the primary is "Sign note" and the sheet ends by jumping to the Claim tab.
  - Keep the separate sign confirmation for that path; DESIGN requires confirmation for sign and send, and one sheet satisfies both.
- Effort: M. Risk: medium (must not hide warnings: list them in the sheet with their Why). Backend: no.

**18. Give every check a fix button**
- Screen/file: `lib/models/claim_models.dart:184-197` (`ClaimIssue` has no action); `lib/screens/claim_tab.dart:72-86` ("See Checks below"), `237-243` (checks last); `lib/screens/encounter_screen.dart:2130-2132` (disabled "Fix 1 issue first"). Screens `09_claim_uncertain.png` and `10_claim_checks.png` show the issue below the fold.
- Change:
  - Add `IssueFix? fix` to `ClaimIssue`, with the variants `signNote`, `confirmDx(code)`, `choosePos`, `editPatient(field)`, `editLine(index)`, `openProfile(field)`, `addMiles`. Set it in `claim_scrubber.dart` where each issue is created.
  - `_IssueRow` shows a TonalButton with the fix label ("Sign note", "Add member ID") next to Why.
  - When errors > 0, render the Checks card first.
  - Make the banner tappable to scroll to Checks.
  - Replace the disabled bottom button with an enabled `FilledButton.tonal("Show 1 issue")` that scrolls to the first error.
- Effort: M. Risk: low. Backend: no.

**19. Undo instead of silent removal on the claim**
- Screen/file: `lib/screens/claim_tab.dart:128-132` (remove diagnosis), `219` and `525` (remove service line).
- Problem: DESIGN.md says "Removing a code offers Undo instead"; the code removes with no undo. The X on a service line is easy to hit while scrolling (`11_claim_stemi_ed.png`).
- Change: pass the previous `ClaimDraft` to an `onClaimChanged(newClaim, {String? undoLabel})`. `_EncounterScreenState._onClaimChanged` shows `SnackBar(content: 'Removed 93010', action: SnackBarAction('Undo', restore))`.
- Effort: S. Risk: none. Backend: no.

**20. Show why the E/M level was picked and allow a one-tap change**
- Screen/file: `lib/services/coding/clinical_coder.dart:486` (evidence: POS, new/established, MDM); `lib/screens/claim_tab.dart:471-531` (`_LineRow` does not show `line.evidence`).
- Problem: the physician sees "99204" without the reason (`09_claim_uncertain.png`), and changing the level means removing the line and searching the catalog.
- Change:
  - Under E/M lines, show `line.evidence` in bodySmall.
  - Add a row of `ChoiceChip`s for the same family (99202 to 99205, or 99212 to 99215).
  - Selecting a chip replaces the code, keeps the pointers, sets `evidence: 'Level chosen by physician'`, and offers Undo.
- Effort: S. Risk: low (the scrubber still checks the POS family). Backend: no.

**21. Remember the note engine and switch automatically when offline**
- Screen/file: `lib/screens/encounter_screen.dart:74` (`_isOffline = false` each visit; the comment still says "Llama 3.3 70B"), `1559-1579`.
- Change:
  - Store `preferOnDevice` in `ProviderProfile` (or `IntegrationSettings`).
  - Use `connectivity_plus` at Record and Finish time: with no network, use on-device without asking.
  - The session strip shows `Icons.cloud_off_outlined Offline, on this phone` only in that state.
  - Fix the stale comment.
- Effort: S. Risk: low. Backend: no.

**22. Allow leaving the screen while recording**
- Screen/file: `lib/screens/encounter_screen.dart:1689-1695, 1725` (`PopScope(canPop: !_isRecording)`, back disabled).
- Problem: a physician cannot check the chart, last visit or insurance mid-visit. In rounds they cannot move on while the note writes.
- Change:
  - Move recording state into a singleton `RecordingController` (a ChangeNotifier holding the engine, timer and transcript).
  - Allow pop. Show a persistent `MaterialBanner` or bottom bar on every route: `Icons.mic Recording Margaret Vance 04:23` with Pause and Return buttons.
  - The Android foreground notification (already used for the wake lock) gets Pause and Finish actions.
- Effort: L. Risk: medium (lifecycle, engine ownership). Backend: no.

**23. Lock-screen and notification controls, plus haptic cues**
- Screen/file: `lib/services/security_and_background_service.dart` (wake lock), native foreground service.
- Change: add notification actions "Pause" and "Finish" to the microphone foreground service. Give a distinct haptic pattern on auto-fallback to basic recognition (`encounter_screen.dart:826`) and on "No sound" (item 3). Once the screen is locked, the physician has eye contact and no screen to check.
- Effort: M. Risk: low. Backend: no.

**24. Voice commands for start, pause and finish**
- Screen/file: `encounter_screen.dart:868-875` (speech results).
- Change:
  - While recording, match the exact phrases "SOLIS pause", "SOLIS resume" and "SOLIS finish visit" at the end of a final result.
  - Run the action and strip the phrase from the transcript.
  - Before acting, give a haptic and a 3 s SnackBar with Undo.
  - Starting by voice needs an always-on hotword, which is out of scope. Use a home-screen shortcut "Start visit for the last opened patient" (Android App Shortcuts) instead.
- Effort: M. Risk: medium (false triggers; keep the phrase prefix required). Backend: no.

**25. Show the on-device draft immediately; cloud improves it**
- Screen/file: `lib/screens/encounter_screen.dart:626-633` (the local note is built synchronously), `638-656` (cloud call with no timeout), `2031-2052` (spinner with no cancel).
- Change:
  - After Finish, set `_encounter = local` and show review at once with a NoteBanner "Improving the wording with the cloud model".
  - When the cloud answer arrives, replace only the SOAP text of sections the physician has not edited (track a `_editedSections` set), and keep the claim.
  - Add a 25 s timeout that keeps the local draft and says so.
- Effort: M. Risk: medium (text changing under the reader; keep a 1-line "Updated" note with Undo). Backend: no.

**26. Edits after sending become an addendum**
- Screen/file: `lib/screens/encounter_screen.dart:1379-1384`.
- Problem: editing a signed note silently unsigns it, even after the claim was submitted, so the record differs from what was billed with no trace.
- Change:
  - If `_afterReady != null` (submitted, paid or denied), the edit pencil opens "Add addendum": a text field saved as `{text, atUtc, by}` and shown below the section as "Addendum, Oct 15 4:10 PM".
  - Before that state, show a confirm dialog "Editing reopens the signed note" once per visit.
- Effort: M. Risk: low. Backend: no.

**27. Replace the hard-coded small-talk filter**
- Screen/file: `lib/screens/encounter_screen.dart:1673-1680` (the list contains 'basketball', 'warriors', 'overtime', 'pickup soccer').
- Problem: tuned to the demo conversations, so it fails on real visits (`12_talk.png`).
- Change: mark a turn as small talk when it contributed nothing. Use `_supportingTurns` (`encounter_screen.dart:1358`) against all four SOAP sections plus `ClaimDiagnosis.evidence`, and treat a turn with no overlap and no clinical term from the coder vocabulary as small talk. Label the chip "Hide turns not used in the note".
- Effort: S. Risk: low. Backend: no.

**28. Home screen: Today list, statuses, Billing queue**
- Screen/file: `lib/screens/patients_screen.dart:325-436, 449-493`.
- Problem: the list shows only "Visit 3, Oct 15" or "No visits" (`02_patients.png`). Nothing says which notes are unsigned or which claims are rejected.
- Change:
  - Add a `NavigationBar` with Today, Patients and Billing. Today lists visits with today's date of service, sorted by status.
  - Each tile gets the same `StatusTag` as `_VisitTile` (`patient_chart_screen.dart:481-489`).
  - Billing groups all visits into sections: Needs signature, Needs fixes (scrubber errors), Ready to send, Sent awaiting payer, Rejected, Denied, Paid this week. Each header shows a count and its first action.
- Effort: M. Risk: low. Backend: no (local data).

**29. Batch send with one confirmation**
- Screen/file: new Billing tab; reuse `_submitClaimOnce` logic (`encounter_screen.dart:439-503`), moved to a `ClaimSubmissionService`.
- Change:
  - "Send 4 ready claims" opens one dialog listing claim ID, patient and total for each, then sends sequentially with the existing idempotency key (`claim_idempotency.dart`), showing a progress row per claim.
  - Signing stays per note: a visit can appear under "Ready to send" only after its note was opened and signed.
  - Send only claims with 0 errors. Claims with warnings need their row's "Review" first.
- Effort: M. Risk: medium (mass send; keep test/production in the dialog title). Backend: no.

**30. Automatic claim status, matched by claim, with notifications**
- Screen/file: `lib/screens/encounter_screen.dart:506-543`.
- Problem: status is manual, per visit, and `res.claims.first` is matched by date of service only.
- Change:
  - Match on `patientControlNumber` (already stored in `_submission`, `encounter_screen.dart:479`).
  - Add a WorkManager periodic task (every 6 h, network required) that checks every visit in `submitted`, updates its status and posts a local notification for rejected, denied and paid.
  - Long term, the Worker receives Stedi 277CA/835 webhooks and pushes the update.
- Effort: M (on-device polling), L (webhooks). Risk: low. Backend: yes for webhooks and push.

**31. Plain-language denials and corrected claims**
- Screen/file: `lib/screens/encounter_screen.dart:545-561` (`_submissionHeader` shows free text).
- Change:
  - Parse CARC/RARC codes from the 277/835 and show each one with a one-line plain meaning (bundle the public X12 CARC list), plus a fix where one maps: "CO-16 Missing information: Add member ID".
  - "Fix and resend" builds a corrected claim with frequency code 7 and the payer claim number (loop 2300 REF*F8).
- Effort: L. Risk: medium. Backend: yes (835 ERA retrieval).

**32. "Since last visit" card for returning patients**
- Screen/file: `lib/screens/encounter_screen.dart:1845-1923` (Ready screen); data in `account.visits[].claim` and `.encounter`.
- Change: on the Ready screen for an established patient, show a SectionCard with the last visit date and POS, its billable diagnoses (codes and descriptions), medications coded as Z79 from that visit, and plan lines containing "follow up", "recheck" or "pending". Use only stored data, no inference.
- Effort: S. Risk: low. Backend: no.

**33. Offline outbox**
- Screen/file: `lib/screens/encounter_screen.dart:498-499`; `patient_chart_screen.dart:165-166`.
- Change:
  - When the network is unavailable, "Send claim" enqueues the claim (`VisitStatus.queued`, a new state shown as `Icons.schedule_send_outlined Queued`).
  - A WorkManager one-off task with a network constraint sends it using the same idempotency key. Eligibility checks queue the same way.
  - The Billing tab shows the outbox count.
- Effort: M. Risk: low (the idempotency key prevents duplicates). Backend: no.

**34. Quick "unidentified patient" for EMS and ED**
- Screen/file: `lib/screens/patients_screen.dart:329-339`; `scan_card_screen.dart`.
- Change:
  - Long-press the FAB, or use a menu item, "Unidentified patient": create an account named "Unidentified, male/female, approx age" with one tap per field and start the visit immediately.
  - The scrubber blocks billing until name, DOB and payer are filled. The chart shows "Scan a card to identify".
  - Scanning a card later offers a merge into an existing account (reuse `_MatchPanel`).
- Effort: M. Risk: medium (merge correctness). Backend: no.

### P2: accessibility, layout and polish

**35. Reflow at 200% text**
- Screen/file:
  - `encounter_screen.dart:1817-1834`: the session strip uses `NeverScrollableScrollPhysics`, so items clip and cannot be reached.
  - `patients_screen.dart:482-493`: the right column of the tile is not Flexible and overflows.
  - `claim_tab.dart:252-271` and `patient_chart_screen.dart:428-441`: 120dp labels; the layout switches on width only.
  - `encounter_screen.dart:2064-2071`: the 4-segment tab bar truncates.
- Change:
  - Compute `final big = MediaQuery.textScalerOf(context).scale(16) > 22;` and stack label over value when `big || width < 330`.
  - Let the session strip wrap (`Wrap` with `runSpacing: 4`, and drop the fixed `height: 36` in favour of a `minHeight`).
  - Turn the right column into `Flexible` with ellipsis.
  - Below 360dp or when `big`, replace the review SegmentedButton with a `TabBar(isScrollable: true)`.
  - Add golden tests at `TextScaler.linear(2.0)` for screens 02, 04, 08 and 10 in `screenshots/screenshot_test.dart`.
- Effort: M. Risk: low. Backend: no.

**36. Follow the system theme and remember the choice**
- Screen/file: `lib/main.dart:45` (`_isDark = false`, never `ThemeMode.system`).
- Change: use a tri-state `ThemeMode` (system default) persisted in `IntegrationSettings` or `SharedPreferences`. The menus offer "Use device setting" in addition to the light and dark options.
- Effort: S. Risk: none. Backend: no.

**37. Correct Spanish in the patient-facing consent, and read it aloud**
- Screen/file: `lib/screens/encounter_screen.dart:1000, 1038`.
- Problem: the patient reads "Espanol", "grabara", "medico", "despues" and "atencion" without accents. That is wrong Spanish on a legal notice. DESIGN's glyph rules cover bullets and dots, not letters.
- Change:
  - Fix the strings: "Español", "grabará", "médico", "grabación", "después", "atención".
  - Add `IconButton(Icons.volume_up_outlined, tooltip: 'Read aloud')` using `flutter_tts` with `es-US` or `en-US`, for patients with low vision or low literacy.
- Effort: S. Risk: none. Backend: no.

**38. Remove the fabricated seal**
- Screen/file: `lib/screens/encounter_screen.dart:603`; `lib/services/local_clinical_engine.dart:463`.
- Problem: `sha256Seal: 'SIG-SHA256: 8a4c092df4482eb1' + timestamp` looks like a hash and is not one.
- Change: at signing, compute `sha256` (package `crypto`) of the canonical formatted note (`_formattedNote()`) plus the signer NPI and time, and store it. Before signing, store null.
- Effort: S. Risk: none. Backend: no.

**39. Tablet and desktop layout with front-desk shortcuts**
- Screen/file: `lib/main.dart:30-33` (portrait only); every screen is single pane.
- Change:
  - Allow landscape when `shortestSide >= 600`.
  - Two panes at width 840 and up: Patients list with the chart, and the encounter Note tab with the Claim tab.
  - Keyboard `Shortcuts`/`Actions`: Ctrl+F focuses search, Ctrl+N opens a new patient, Ctrl+Enter runs the current primary action, Esc goes back.
  - In the scan screen, accept keyboard-wedge 2D scanners: a hidden focused `TextField` captures an AAMVA PDF417 string (starts with "@\n" and contains "ANSI ") and feeds it to the existing barcode parser in `card_parser.dart`.
- Effort: L. Risk: medium. Backend: no (shared data needs Big idea E).

**40. Show only the coding notes that matter on this claim**
- Screen/file: `lib/widgets/knowledge_widgets.dart` (`CodeNotesToggle`); `20_claim_coding_notes.png` shows about 15 Excludes and Use-additional lines for E11.
- Change: by default list only notes that reference a code on this claim or a code the scrubber suggested (for example "Use additional code Z79.84"). Put the full list behind "All notes (14)".
- Effort: S. Risk: low. Backend: no.

---

## 4. Bigger automation ideas

**A. Background visit pipeline, physician only signs.**
- When Finish is tapped, one pipeline runs without further taps: note, codes, checks, eligibility (if older than 24 h), auto-fixes that have no clinical judgment (POS from place, E/M family from POS, mileage from GPS, pointers).
- The physician's queue then holds three kinds of item: notes to sign, diagnoses to confirm, real errors.
- Clean visits wait in "Ready to send" for one batch send at the end of the day (items 17, 18, 28, 29).
- Target: no claim-tab visit for a clean claim.

**B. Location-aware context.**
- Saved Places (item 15) drive POS, the service facility, the default consent method (for example representative signature at an SNF) and EMS mileage.
- Entering a saved SNF geofence posts a notification: "At Sunrise SNF. Start rounds?" This uses the existing foreground location only, no background tracking without opt-in.

**C. Rounds mode (nursing home, hospital).**
- Pick a place, which locks POS 31/32 or 21 for the session. Multi-select residents from that place's roster (accounts tagged with the place).
- SOLIS shows the next resident's Ready screen with a big "Record" button. "Finish and next" stops capture, writes the note in the background (needs item 22's RecordingController) and advances.
- At the end, a review list: each note opens, is checked and signed (attestation per note), then one "Send N claims" covers all.
- Estimated 64 taps for 10 residents instead of about 160.

**D. Claim lifecycle on the server.**
- The Worker receives Stedi 277CA and 835 webhooks, updates the visit, and sends a push notification: "2 claims paid, 1 denied: CO-16 missing member ID".
- It also drafts the corrected claim. The phone applies the fix (item 31) and resends with frequency code 7.
- Removes all manual status checks (items 30, 31).

**E. Practice sync for front desk and billers (prerequisite for a real front-desk role).**
- Today all data is local to one phone (`AccountRepository` writes `solis_*.json` files).
- Add a practice-scoped encrypted sync on the Worker (D1 plus R2, per-practice key, BAA in place first per `LAUNCH_COMPLIANCE.md` section 2).
- Roles: physician (sign), front desk (patients, cards, eligibility, no notes), biller (claims, status, denials).
- The front desk scans cards on a tablet and the patient appears in the physician's Today list. The biller works the Billing queue on a desktop browser or tablet (item 39).
- Without this, the front-desk journeys above only work on the physician's own phone.

---

## 5. Suggested order

1. Items 1, 2, 3, 4, 6, 38: stop false data and lost visits (about 1 week).
2. Items 5, 7, 14, 17, 18, 19, 20, 21: the per-visit flow (about 1.5 weeks).
3. Items 28, 29, 30, 33, 16: the end-of-day queue (about 1.5 weeks).
4. Items 11, 12, 13, 9, 10: check-in and setup (about 1.5 weeks; item 10 needs the server).
5. Items 15, 22, 8, 34, then Big idea C: rounds and EMS.
6. P2 accessibility and layout alongside, with the 200% golden tests from item 35 added first so regressions show.
