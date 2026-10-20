# SOLIS pricing proposal

Prepared 2026-10-17. Proposal for the founder; nothing here is live billing.
Costs come from `docs/UNIT_ECONOMICS.md` (list prices, 1,000+ doctors unless
stated). Competitor prices are what the vendors or third parties publish
today and are often incomplete; see section 6 for how sure each one is.

## 1. Principles

1. **Flat price per clinician, not a percentage of collections.** Billing
   services charge a share of what the practice collects (section 2). SOLIS
   prepares and sends the claim but does not work denials or appeals, so a
   flat fee is both honest and easy to compare.
2. **On-device first.** On-device capture and notes cost SOLIS almost nothing
   (under $1 per doctor-month), so every plan includes them without limits.
3. **Meter what costs money.** Clearinghouse transactions (about $0.20 per
   visit at volume) and cloud transcription (about $0.15 per 15-minute visit)
   are included up to a cap, then metered.
4. **Bill outside the app stores.** Practices pay on the website (Stripe), the
   app is a free download with sign-in only (section 5).

## 2. The market today

| Product | Published price | Notes |
| --- | --- | --- |
| Freed | Starter $39 / clinician / month (40 notes); Core $59 or $79 (unlimited notes); Premier $119 monthly or $104 annual (adds ICD-10 and CPT coding, EHR push); Groups custom; 7-day trial | Official page, prices partly ambiguous [P1] |
| Heidi | Free tier (unlimited transcription, no coding); Clinician, Practice, Enterprise: "Talk to us", 14-day trial | Official page [P2] |
| Tali | Personal free; paid plans CA$50 to CA$150 / month (two price sets shown) | Official page, Canadian dollars [P3] |
| Nabla | About $99 to $399 / provider / month | Third-party estimates; official pricing page returned 404 [P4], [P5] |
| Abridge | About $200 to $400 (some sources up to $600) / provider / month, enterprise contracts | Third-party estimates, not published by the vendor [P4], [P5] |
| Suki | About $200 to $400 / provider / month | Third-party estimates [P4], [P5] |
| DeepScribe | About $200 to $400 / provider / month | Single third-party estimate [P5] |
| Microsoft Dragon Copilot (Nuance DAX Copilot) | About $200 to $600+ / provider / month; Epic-integrated bundles reported at $150 to $350 | Third-party estimates, wide range [P4], [P5] |
| Outsourced billing / RCM services | Usually 4% to 8% of net collections for straightforward practices, up to 10% or more; solo practices pay at the high end (6.5% to 8.5%) | Third-party guides; the often-quoted "MGMA" attribution could not be confirmed [P6], [P7], [P8] |

Reading the market: ambient scribes cluster at $99 to $400 per clinician per
month for notes, with coding only in upper tiers. None of the published plan
descriptions above mention sending the claim to a clearinghouse. Billing services do the claim but charge a
share of revenue. SOLIS sits between them: note, codes, checks and the claim
for one flat price.

## 3. Proposed plans

Prices are per clinician (MD, DO, NP, PA) per month. Front-desk and billing
staff seats are free on every plan.

| | **Solo** | **Practice** | **Enterprise** |
| --- | --- | --- | --- |
| Who | One clinician, own billing | 2 to 20 clinicians | 20+ clinicians, groups, EMS, nursing-home rounding |
| Billed annually | **$129** | **$299** | Custom |
| Billed monthly | **$149** | **$349** | Custom |
| On-device capture and notes | Unlimited | Unlimited | Unlimited |
| Cloud note writing (Claude) | Included | Included | Included |
| Cloud transcription (Deepgram medical, speaker separation) | Add-on: $39 per 2,000 min | 3,000 min / clinician / month, pooled | Volume |
| Diagnosis and procedure coding, claim checks with Why, coding notes | Included | Included | Included |
| Card scanning, accounts, visits, orders list | Included | Included | Included |
| CMS-1500 data and 837P export | Unlimited | Unlimited | Unlimited |
| Claim visits (eligibility + 837P claim + status, through Stedi) | 200 / month | 450 / clinician / month, pooled | Volume |
| Extra claim visits | $0.45 each | $0.40 each | Contract |
| Staff seats | Free | Free | Free |
| BAA | Click-through (counsel-reviewed template) | Click-through | Negotiated |
| Support | Email, guide | Priority email, onboarding call | Named contact, security review packet |

"Claim visit" means one date of service: the eligibility check, the claim and
its status checks. Test-mode claims are free and unlimited.

### Pilot and trial

- **Pilot (now, invitation):** no charge during the pilot (demo data, test-mode
  claims; real claims only after the vendor BAAs in
  `docs/LAUNCH_COMPLIANCE.md` are signed). Pilot practices then get **50% off
  the first 12 months** and the launch price locked for 24 months.
- **Free trial (at general availability):** 14 days, no card. Demo patients,
  the sample card, and unlimited test-mode claims. Real claims start when a
  plan is chosen.
- **Annual discount:** about 13% (Solo) and 14% (Practice) versus monthly.

## 4. Margins

Cost lines: Haiku 5.5 notes (high case) $0.89 per doctor-month; claim visit
$0.204 at volume (eligibility $0.08 + claim $0.10 + status on 30% of claims);
cloud minutes $0.0097; Cloudflare $0.10; Stripe (card 3.6% + 30 cents on Solo,
ACH 0.8% capped at $5 per invoice plus Billing 0.7% on Practice); support
$8 (Solo) and $10 (Practice) per clinician per month (founder estimate).

| Plan (annual price) | Cost if every included unit is used | Gross margin, full use | Cost, typical use | Gross margin, typical |
| --- | --- | --- | --- | --- |
| Solo $129 | $54.70 (200 claim visits) | **58%** | $44.50 (150 claim visits) | **66%** |
| Practice $299 | $135 (450 claim visits, 3,000 cloud min) | **55%** | $85 (300 claim visits, 1,000 cloud min) | **72%** |
| Solo extra claim visit $0.45 | $0.204 | 55% | | |
| Practice extra claim visit $0.40 | $0.204 | 49% | | |
| Cloud minutes add-on $39 / 2,000 | $19.40 | 50% | | |
| Documentation-only use (exports, no claims sent) | about $10 (support dominates) | 92% (Solo) | | |

At pilot scale (about 10 doctors) Stedi charges more per transaction (about
$0.33 to $0.48 per claim visit, `docs/UNIT_ECONOMICS.md` section 3), so
Practice margin at full use drops to roughly 25% to 35%. That is acceptable
for a pilot at 50% off only because pilots are few; do not sell many
full-use Practice seats before volume reaches the cheaper Stedi tiers, or ask
Stedi for a committed-volume rate.

Fixed costs that are not in the margins above: Cloudflare Enterprise (or a
different BAA-covered PHI host), compliance work (risk analysis, SOC 2), the
AMA CPT per-user royalty (unknown until the license is signed; it may need to
be added per seat).

## 5. How billing is collected

- **Website, Stripe Checkout, B2B.** The practice owner or manager picks a
  plan on solis-health.pages.dev (after sign-up and BAA acceptance, see
  `docs/ONBOARDING.md`). Stripe Billing handles subscriptions and seats;
  prefer ACH Direct Debit for Practice (0.8%, capped at $5) over cards. Annual
  plans can also be invoiced.
- **The app sells nothing.** No prices, no purchase buttons, no "upgrade"
  links in the Android or iOS app. The app signs in to an account the
  practice already set up. This is the standard pattern for business software
  bought outside the store.
- **Google Play.** Play's payments policy requires Play Billing for in-app
  purchases of software and services, including business productivity
  software, and forbids leading users from the app to another payment method
  except through its enrolled alternative-billing or external-offers programs,
  which carry their own fees [P9]. Keep all purchase flows off the app and
  there is nothing for Play to bill. Play's own service fee is 10% (plus a 5%
  billing fee when Play bills) on the first $1M for subscriptions under the
  current US schedule [P10], [P11]; avoiding it matters less than staying
  compliant.
- **Apple App Store (when iOS ships).** Guideline 3.1.3(c) lets an app "sold
  directly by you to organizations or groups for their employees" give access
  to subscriptions bought elsewhere; "consumer, single user, or family sales
  must use in-app purchase" [P12]. Practice and Enterprise fit 3.1.3(c). **Solo
  is the risk**: a one-clinician purchase may be read as a single-user sale.
  Options: sell Solo to the practice entity (with its EIN and NPI, which SOLIS
  already collects), or, in the US storefront, Apple currently allows buttons
  and links to web purchase without an entitlement (3.1.1(a)) [P12]. Confirm
  with App Review before iOS launch. Healthcare apps must be submitted by a
  legal entity (5.1.1(ix)).
- **Sales tax.** SaaS is taxable in some states; turn on Stripe Tax before
  general availability (check the Stripe US price).

## 6. What is uncertain

- Competitor prices for Abridge, Suki, DeepScribe, Nabla and Dragon Copilot
  are not published by the vendors; the ranges come from comparison blogs and
  differ by 2x to 3x. Freed's page shows two prices for Core. Heidi does not
  list paid prices. Tali lists two sets of CAD prices.
- The 4% to 8% billing-service range is widely repeated but its MGMA source
  could not be found; the AAFP and HBMA figures we found are older.
- Support cost per clinician is a guess until pilots run.
- AMA CPT royalty and Cloudflare Enterprise price are unknown.
- Google's US fee schedule after the Epic settlement was reported
  inconsistently in 2026 [P11]; Apple's US link-out rules have changed several
  times. Recheck both before launch.

## 7. Sources (accessed 2026-10-17)

- [P1] Freed pricing: https://www.getfreed.ai/pricing
- [P2] Heidi pricing: https://www.heidihealth.com/pricing
- [P3] Tali pricing: https://tali.ai/pricing
- [P4] VoiceboxMD, AI medical scribe cost 2026 (12 vendors): https://voiceboxmd.com/ai-medical-scribe/pricing/
- [P5] EHR Source, ambient AI scribes comparison: https://www.ehrsource.com/articles/ambient-ai-scribes-comparison/ ; Glass Health, best ambient scribes 2026: https://glass.health/resources/best-ai-medical-scribe ; MedEquip Directory comparison: https://www.medequipdirectory.com/guides/ambient-ai-scribe-comparison-guide-2026-dax-abridge-nabla-deepscribe/
- [P6] Helpware, medical billing outsourcing cost: https://helpware.com/blog/medical-billing-outsourcing
- [P7] Beancount, billing company percentage of collections guide (2026-07-20): https://beancount.io/blog/2026/07/20/medical-billing-company-bookkeeping-percentage-of-collections-accounts-receivable-guide
- [P8] Physicians Practice, billing company charges (HBMA ranges): https://www.physicianspractice.com/view/billing-company-charges
- [P9] Google Play, Payments policy: https://support.google.com/googleplay/android-developer/answer/9858738
- [P10] Google Play, service fees: https://support.google.com/googleplay/android-developer/answer/112622
- [P11] Reporting on Google Play US external billing (June 2026): https://www.androidheadlines.com/2026/06/google-play-store-external-billing-fee-changes.html
- [P12] Apple App Store Review Guidelines (3.1.1(a), 3.1.3(c), 5.1.1(ix)): https://developer.apple.com/app-store/review/guidelines/
- Vendor costs: see `docs/UNIT_ECONOMICS.md` section 9.
