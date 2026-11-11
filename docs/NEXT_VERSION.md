# SOLIS next version: build brief from market research

Prepared 2026-11-11 from the report "SOLIS market and competitor research"
(https://claude.ai/artifact/L91iQk3zHqXpWHUsdnmmJz). Goal set by the owner:
the next version should give users superior value, nothing to reject, and
every reason to pay.

## The one-line strategy

Notes are becoming free (Doximity free, Commure core free, Heidi free tier).
Nobody in self-serve sends the claim. SOLIS wins as **note to claim in one
visit, on the phone, with every code explained**. Everything below serves
that.

Buyer: owner-clinician of an independent practice (1 to 10 clinicians) who
bills in-house. First specialties: primary care, mental health, urgent care,
mobile/rounding.

## 1. Remove every reason to reject (from what users hate in competitors)

| Rank | Complaint about competitors | What to build in SOLIS | Acceptance check |
| --- | --- | --- | --- |
| 1 | Invented or missing facts (about 3 errors per note in one study) | Every note sentence and every code links to the transcript lines it came from (extend claim "Why" to the note). Flag sentences with no source. Show "not discussed" instead of guessing. | Tap any sentence, see its source line; unsupported sentence is highlighted |
| 2 | Clinician liable for codes | Mandatory confirm on E/M level and codes before a claim can send; code rationale and an audit trail of who changed what | Claim cannot send without clinician confirm; audit log exportable |
| 3 | Lost recordings (app pauses, half a note lost) | On-device capture saved continuously; resume after call, app switch, lock screen, low battery; never discard audio until note is signed | Kill the app mid-visit and reopen: recording and partial note survive |
| 4 | Weak specialty notes | Templates for psych (timeline, ruled-out list kept ruled out), urgent care, primary care, SOAP, H&P | Psych template never re-adds a diagnosis the clinician ruled out |
| 5 | Bloated notes | Note length and style setting (brief, standard, detailed; abbreviations on or off) remembered per user | Setting persists and changes output |
| 6 | Tier gating and note caps | One paid plan with everything; no note caps; coding never locked | No paywall inside the visit flow |
| 7 | Cancel and refund trouble | Cancel via Play Billing in two taps; show renewal date and price in Settings; email a reminder before trial ends | Settings shows plan, renewal date, a Manage subscription link |
| 8 | Setup friction | First useful note in under 5 minutes with no setup; practice and payer setup deferred until the first real claim | New user records a demo visit before any form |

## 2. Superior value (what makes paying obvious)

1. **Time-to-value screen.** After each day: notes signed, claims sent, minutes
   saved, money sent to payers. A weekly summary of "what SOLIS did for you".
2. **Claim outcome loop.** Show claim status (accepted, rejected, paid) on the
   visit, and a one-tap fix for common rejections. This is the step no
   competitor does.
3. **Billing-service comparison** on the paywall: "A 6% billing service on
   $40,000 a month costs about $2,400; SOLIS is $149" (label as example).
4. **Patient-facing summary** (plain-language after-visit summary to share),
   which Freed and Heidi users value.
5. **Offline first.** Notes and the claim queue work without signal; sync later.
6. **Staff seats free** for front desk card scanning.

## 3. Pricing and paywall (owner still to confirm)

- Free: unlimited on-device notes (match Doximity so notes-only users stay).
- Pro: $149 a month or $1,548 a year (show as $129 a month), everything
  included: cloud notes, coding, claims, templates.
- Trial: 14 days recommended instead of 7, because a first real claim takes
  more than a week to come back. Trial includes the full Pro flow.
- Paywall appears only when the user tries to send a real claim or after the
  trial, never mid-recording.

## 4. Listing and website messages

"Home on time, claim already sent" / "Every code shows why" / "Works on your
phone, even offline" / "Staff seats free, cancel any time".

## 5. Suggested build order

1. Recording never lost (item 3) and sentence-level sources (item 1).
2. Code confirm and audit trail (item 2), claim status loop (value 2).
3. Free notes tier, Pro paywall at first real claim, 14-day trial (section 3).
4. Specialty templates and note length setting (items 4 and 5).
5. Daily value screen and patient summary (value 1 and 4).

Check each against docs/FEATURE_BACKLOG.md and reuse existing backlog items
where they already cover it.

## Decisions and progress

- 2026-11-11: owner approved the plan, the 14-day trial with the full Pro
  flow, Pro at $149 a month or $1,548 a year, and free on-device notes.
- B8: build-order step 1 (recording never lost, sentence-level sources).
- B9: step 2 (code confirm, audit trail, rejection fixes; claim status
  timeline already shipped in B3).
- B10: step 3 (free notes, paywall at the first real claim, 14-day trial,
  renewal date in Settings).
- B11: step 4 (templates, length and abbreviation setting, ruled-out list).
