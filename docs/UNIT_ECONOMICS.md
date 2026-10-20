# SOLIS unit economics

Prepared 2026-10-17. Every vendor price below was read from the source listed
in section 9 on that date. List prices only; volume contracts will be lower.
This is a planning model, not a quote. Re-run `econ.py` style math whenever a
price changes (the formulas are spelled out in each section).

## 1. The typical doctor (assumptions)

| Input | Value | Why |
| --- | --- | --- |
| Visits per day | 20 | Brief |
| Audio per visit | 15 min | Brief |
| Workdays per month | 21 | Brief |
| Visits per doctor-month | **420** | 20 x 21 |
| Audio minutes per doctor-month | **6,300** | 420 x 15 |
| Transcript tokens per minute | **600** | Assumption from the brief. Conversational speech is about 130 to 160 words per minute, roughly 200 to 250 tokens, so 600 is a deliberately high (about 2.5x) allowance that also covers speaker labels, timestamps and repeats. Real cost is likely lower. |
| Transcript tokens per visit | 9,000 | 15 x 600 |
| System prompt (rules, schema) | 2,000 tokens | Stable prefix, sent as a cache hit after the first call |
| Note output | 800 tokens | Brief |
| Thinking allowance | 1,200 tokens | Haiku 5.5 thinks by default (adaptive, effort medium) and thinking is billed as output. Modeled as a high case. |
| Eligibility checks | 1 per visit | Brief. In practice many practices check once per patient per month, so this is conservative. |
| Claims | 1 per visit | Brief |
| Claim status (276/277) | 1 per visit as a high case, about 0.3 in practice | Most claims are acknowledged by the free 277CA; status is only polled for aging claims |

## 2. Unit prices (list, 2026-10-17)

| Service | Price | Source |
| --- | --- | --- |
| Claude Haiku 5.5 (`claude-haiku-5-5`), prompts up to 100K tokens | $0.10 / MTok input, $0.50 / MTok output, cache hit $0.01 / MTok, 5-minute cache write $0.125 / MTok | [S1] |
| Claude Haiku 5.5, prompts over 100K tokens | $0.50 / $2.50 per MTok | [S1] |
| Batch API | 50% off input and output | [S1]. **Not usable for PHI**: batch processing is not an eligible feature under Anthropic's HIPAA-ready API organization [S2]. |
| US-only inference (`inference_geo: "us"`) | 1.1x on all token prices | [S1] |
| Claude Sonnet 5.5 / Opus 5.5 (for comparison) | $2 / $10 and $4 / $20 per MTok | [S1] |
| Deepgram Nova-3 Medical, streaming | $0.0077 / min (launch list price; the current pricing page lists only general Nova-3: $0.0048 PAYG promotional, $0.0042 Growth promotional, $0.0077 regular) | [S3], [S4] |
| Deepgram streaming diarization add-on | $0.0020 / min PAYG, $0.0017 Growth | [S3] |
| Stedi eligibility 270/271 | $0.30 (1 to 250 per month), $0.15 (to 3,500), $0.10 (to 10,000), $0.08 above. Each unit billed at its own tier. | [S5] |
| Stedi claim 837P | $0.30 (1 to 500), $0.20 (to 2,500), $0.12 (to 10,000), $0.10 above | [S5] |
| Stedi claim status 276/277 | same tiers as eligibility | [S5] |
| Stedi other | No monthly minimum, no setup fee, 277CA free, signed BAA on pay-as-you-go, payer pass-through fees billed at cost | [S5] |
| Cloudflare Workers Paid | $5 / month; 10 M requests and 30 M CPU-ms included; then $0.30 / M requests and $0.02 / M CPU-ms; no egress charge | [S6] |
| Workers KV | 10 M reads, 1 M writes, 1 GB included; then $0.50 / M reads, $5 / M writes, $0.50 / GB-month | [S6] |
| D1 | 25 B rows read, 50 M rows written, 5 GB included; then $0.001 / M read, $1 / M written, $0.75 / GB-month. **10 GB max per database, cannot be raised; 50,000 databases per account; single-threaded per database.** | [S6], [S7] |
| R2 | $0.015 / GB-month, Class A $4.50 / M, Class B $0.36 / M, 10 GB + 1 M A + 10 M B free; **egress free** | [S8] |
| Pages | Static files up to 25 MiB; Functions requests count as Workers requests | [S9] |
| Cloudflare BAA | Only for Enterprise customers whose use involves PHI; older whitepaper says "minimum spending thresholds"; BAA must be signed before PHI flows | [S10], [S11] |
| Cloudflare Enterprise price | Not published. Third-party estimates: from about $5,000 / month; a Vendr-based median contract of about $21K / year. Treat as unknown until quoted. | [S12], [S13] |
| Google ML Kit (card reading) | On-device, works offline, input and output not sent to Google; no fee is published | [S14], [S15] |
| On-device speech models (Moonshine, pyannote, CAM++, Silero) | Open-source (MIT / Apache-2.0); free; about 150 MB one-time download | `docs/NATIVE_SPEECH.md` |
| Stripe (US) | Cards 2.9% + 30 cents; ACH Direct Debit 0.8% capped at $5; Stripe Billing +0.7% of billing volume | [S16] (third-party summaries; stripe.com served the India page to our fetcher, confirm on stripe.com/us/pricing) |

## 3. Cost per visit, one doctor in isolation

Formulas (per visit):

- Notes (Haiku 5.5): `9,000 x $0.10/M + 2,000 x $0.01/M (cache hit) + 800 x $0.50/M` = **$0.0013**.
  High case with 1,200 thinking tokens and US-only inference (1.1x): **$0.0021**.
- Cloud transcription: `15 min x ($0.0077 + $0.0020)` = **$0.1455** (list). At the promotional
  general Nova-3 rate: `15 x ($0.0048 + $0.0020)` = $0.102.
- Clearinghouse (one doctor alone, 420 per month, tiered): eligibility $100.50 + claims $126.00 =
  $226.50 per month = **$0.539 per visit**; with a status check on every visit $0.779.
- Cloudflare: the $5 base dominates for one doctor; usage is cents (section 5).

The clearinghouse is the largest cost by far, and it drops quickly with
pooled volume because SOLIS (one Stedi account) is the customer, not each
doctor:

| Doctors on SOLIS | Stedi cost per visit (elig + claim) | With status on every visit |
| --- | --- | --- |
| 1 | $0.539 | $0.779 |
| 10 | $0.330 | $0.481 |
| 1,000 | $0.182 | $0.263 |
| 100,000 and up | $0.180 (the top tiers: $0.08 + $0.10) | $0.260 |

## 4. Cost per visit and per doctor-month by mode (at 1,000+ doctors)

Thinking and US-only inference included (high case). Status checks on 30% of
claims (realistic) shown in the last column.

| Mode | What runs where | AI and speech per visit | Clearinghouse per visit | **Total per visit** | **Per doctor-month** | Per doctor-month, status on 30% |
| --- | --- | --- | --- | --- | --- | --- |
| (a) On-device capture, Claude notes | Audio and transcript on the phone; transcript text to Haiku 5.5 through the Worker | $0.0021 | $0.182 | **$0.184** | **$77.43** | $87.6 |
| (b) Cloud mode | Deepgram Nova-3 Medical with diarization, Haiku 5.5 notes | $0.1476 | $0.182 | **$0.330** | **$138.54** | $148.7 |
| (c) Fully on-device incl. notes | No AI vendor cost | $0 | $0.182 | **$0.182** | **$76.54** | $86.7 |

Documentation only (the practice exports CMS-1500 / 837P to its own billing
system and does not send claims through SOLIS):

| Mode | Per visit | Per doctor-month |
| --- | --- | --- |
| (a) On-device capture, Claude notes | $0.0023 | **about $0.97** |
| (b) Cloud mode | $0.148 | **about $62.10** |
| (c) Fully on-device | about $0.0002 (Worker requests and storage only) | **about $0.08** |

What this says:

1. **AI for notes is not the cost.** Haiku 5.5 costs under a dollar per doctor
   per month even with a 2.5x token allowance and thinking. The Worker uses
   `claude-haiku-5-5` (switched 2026-10-16 at the founder's request; a live
   note test returned a correct, quote-backed note). For comparison, the same
   workload on Opus 5.5 is $0.084 per visit, $35.30 per doctor-month; on
   Sonnet 5.5, $0.042 and $17.74.
2. **Cloud speech is the main variable cost** in cloud mode, about $61 per
   doctor-month at list. On-device mode removes it entirely. That is the
   single biggest lever in the product.
3. **Claims are a pass-through.** At list price the clearinghouse is about $76
   per doctor-month at 420 claims. It does not go away in any mode, but it
   scales down with pooled volume and can be negotiated. Pricing must either
   include a capped number of claims or meter them (see `docs/PRICING.md`).
4. With on-device capture and notes, and claims exported rather than sent,
   **the marginal cost of a doctor is cents per month**. Everything else is
   fixed cost (compliance, support, Cloudflare Enterprise).

## 5. Infrastructure per doctor (Cloudflare)

Assumptions per visit: 30 Worker requests (sign-in refresh, sync, note,
Deepgram token, eligibility, claim, status, and app polling), 10 ms CPU each,
50 D1 rows written, 20 KB stored (note, claim JSON, audit log; no audio).

Per doctor-month: 12,600 requests, 126,000 CPU-ms, 21,000 rows written,
8.4 MB stored (about 100 MB per doctor-year).

| Doctors | Requests per month | Workers usage cost | D1 rows written cost | D1 storage after 1 year | Infra per doctor-month |
| --- | --- | --- | --- | --- | --- |
| 1,000 | 12.6 M | about $0.80 + $1.90 CPU | $0 (inside 50 M) | 100 GB, $71 | about $0.08 |
| 100,000 | 1.26 B | about $375 + $250 CPU | about $2,050 | 10 TB, about $7,500 | about $0.10 |
| 1,000,000 | 12.6 B | about $3,780 + $2,520 CPU | about $21,000 | 100 TB, about $75,000 | about $0.10 |

R2 serves the 150 MB APK with free egress; at 1M installs that is about 150 TB
of transfer at $0 egress and about $0.36 in Class B operations per million
downloads. The on-device speech models (about 150 MB per phone) are fetched
today from GitHub release URLs (`docs/NATIVE_SPEECH.md`); at scale, mirror them
to R2 (same SHA-256 checks) so a third-party rate limit cannot block
onboarding.

## 6. Scale: 1,000 / 100,000 / 1,000,000 doctors

Variable cost per month (list prices, mode mix shown separately):

| Doctors | (a) On-device + Claude notes | (b) Cloud mode | (c) Fully on-device | (c) without claims through SOLIS |
| --- | --- | --- | --- | --- |
| 1,000 | $77K | $139K | $77K | about $80 |
| 100,000 | $7.66M | $13.77M | $7.57M | about $10K |
| 1,000,000 | $76.6M | $137.7M | $75.7M | about $103K |

Fixed and semi-fixed costs (estimates, not quotes):

| Item | 1,000 | 100,000 | 1,000,000 | Note |
| --- | --- | --- | --- | --- |
| Cloudflare Enterprise (needed for the BAA, because transcripts and claims pass through Workers) | from about $5K / month | negotiated, likely $25K+ | negotiated | No public price [S12], [S13]. Alternative: move the PHI path to a host whose BAA comes with a standard account (for example AWS accepts its BAA through AWS Artifact [S17]; check that each service used is HIPAA-eligible). |
| Support | about $8 / doctor-month (1 person per about 600 doctors) | about $4 | about $2.50 | Founder estimate. Self-serve onboarding (`docs/ONBOARDING.md`) and the in-app guide are what drive this down. Device variety (Android phones, mic quality) is the main support driver. |
| Compliance (risk analysis, policies, SOC 2 Type I then II, pen test) | annual audit and tooling | same, plus HITRUST if hospitals ask | same | Not priced from a public source here; get quotes. |
| AMA CPT distribution license | per-user royalty | per-user royalty | per-user royalty | Required to ship CPT descriptors and the NCCI PTP table (`docs/LAUNCH_COMPLIANCE.md`). The royalty schedule is set in the AMA agreement; get the number before setting final prices. |

What changes with scale:

- **Workers request volume.** 1.26 B requests per month at 100K doctors is
  about 490 requests per second on average and a few thousand at clinic peaks.
  Workers handles that, and the cost stays about $0.10 per doctor. No change of
  platform needed for the stateless API.
- **D1 limits.** One D1 database is single-threaded (about 1,000 queries per
  second at 1 ms each) and capped at 10 GB. One shared database stops working
  long before 100K doctors (10 GB is about 100 doctor-years of data). Design
  now for **one database (or one SQLite Durable Object) per practice**, which
  also gives clean tenant isolation and per-practice deletion. 50,000 databases
  per account is the default, raisable on request [S7].
- **R2 egress is free**, so APK and model distribution cost nothing in
  bandwidth at any scale.
- **Vendor contracts.** At 100K doctors SOLIS would send about 42 M claims and
  42 M eligibility checks a month; Stedi list prices stop at $0.10 / $0.08 and
  an enterprise contract should be lower. Deepgram cloud mode at that scale is
  tens of thousands of concurrent streams and needs an Enterprise agreement
  (which is also where Deepgram signs a BAA [S3]). Anthropic rate limits for
  about 2 M notes per day need a negotiated tier.
- **BAA posture.** Before any real PHI: Anthropic (HIPAA-ready API org [S2]),
  Deepgram (Enterprise [S3]), Stedi (pay-as-you-go includes a signed BAA [S5]),
  and Cloudflare Enterprise or a different PHI host [S10].
- **Payments.** Stripe ACH (0.8%, capped at $5) is much cheaper than cards for
  practice invoices: on a $299 seat, card is about $9.00 and ACH $2.39, plus
  0.7% for Stripe Billing.

## 7. Where on-device processing makes marginal cost near zero

| Step | Cloud mode cost | On-device cost |
| --- | --- | --- |
| Capture and speaker separation | $0.1455 per visit (Deepgram + diarization) | $0 (Moonshine + pyannote + CAM++ on the phone) |
| Note writing | $0.0013 to $0.0021 (Haiku 5.5) | $0 (on-device engine) |
| Card reading | not offered in the cloud | $0 (ML Kit on the phone) |
| Code sets and claim checks | n/a | $0 (bundled, offline) |
| Eligibility, claim, status | $0.18 to $0.26 per visit | same (always through Stedi) |

So the doctor's phone does the expensive work for free, and the only
per-visit costs left are the clearinghouse transactions, which are optional
(export instead) and priced per use.

Risks of leaning on the phone:

- **Accuracy.** Moonshine Base is a general English model with no medical
  vocabulary biasing (`docs/NATIVE_SPEECH.md`). Drug names and rare terms will
  be missed more often than with Deepgram's medical model. The on-device note
  engine is simpler than Claude. Offer cloud mode as the upgrade path and
  measure word error rate on real visits before marketing either.
- **Devices.** About 290 MB of storage for the standard model set, CPU and
  battery load on long clinic days, older phones that cannot keep up, and no
  iOS version of the engine yet. Every slow phone becomes a support ticket.
- **PHI on the phone.** On-device mode moves risk to the device: lost phones,
  screen locks, backups. Needs device encryption checks, sign-out and remote
  revocation (part of real sign-in).
- **Model hosting.** Models are downloaded from GitHub today; mirror to R2.
- **Pricing pressure.** If marginal cost is near zero, competitors with free
  tiers (Heidi, Tali list free personal plans) set a low anchor; SOLIS earns
  its price on coding, claim checks and claims, not on transcription.
- **Vendor price changes.** Deepgram's current Nova-3 rates are labeled
  promotional; the Medical model has no line on today's pricing page.
- **Stedi tiers at small volume.** With 10 pilot doctors, Stedi costs $0.33 to
  $0.48 per visit, about double the at-scale figure. Early margins are thin
  unless claims are metered.

## 8. Uncertain numbers

- Deepgram Nova-3 Medical current streaming price (only the 2025 launch figure
  is published; confirm with Deepgram sales).
- Cloudflare Enterprise minimum and whether Workers, KV, D1 and R2 are listed
  services under its BAA (get it in writing).
- Real tokens per minute (measure with `count_tokens` on 20 real transcripts).
- Haiku 5.5 thinking tokens per note at effort `low` vs `medium`.
- AMA CPT per-user royalty.
- Support cost per doctor (no data until pilots run).
- Stripe US rates are from third-party summaries dated 2026; confirm on stripe.com.

## 9. Sources (all accessed 2026-10-17)

- [S1] Anthropic, Pricing: https://platform.claude.com/docs/en/about-claude/pricing
- [S2] Anthropic, API and data retention (HIPAA readiness, eligible features): https://platform.claude.com/docs/en/manage-claude/api-and-data-retention ; BAA for commercial customers: https://privacy.claude.com/en/articles/8114513-business-associate-agreements-baa-for-commercial-customers
- [S3] Deepgram, Pricing: https://deepgram.com/pricing
- [S4] Deepgram Nova-3 Medical launch press release (March 3, 2025), $0.0077 / min streaming: https://www.businesswire.com/news/home/20250303470439/en
- [S5] Stedi, Pricing: https://www.stedi.com/pricing
- [S6] Cloudflare Workers pricing (Workers, KV, D1, Durable Objects, R2): https://developers.cloudflare.com/workers/platform/pricing/
- [S7] Cloudflare D1 limits: https://developers.cloudflare.com/d1/platform/limits/
- [S8] Cloudflare R2 pricing: https://developers.cloudflare.com/r2/pricing/
- [S9] Cloudflare Pages limits: https://developers.cloudflare.com/pages/platform/limits/
- [S10] Cloudflare HIPAA FAQs: https://www.cloudflare.com/trust-hub/compliance-resources/hipaa/
- [S11] Cloudflare HIPAA whitepaper (2020): https://www.cloudflare.com/resources/assets/slt3lc6tev37/3PeVHvuZAh7p3tN77kIfhG/596a459dd1cfbc2ad6b1dbef36ff0eb1/BDES-1265_Privacy_Compliance_Whitepapers_HIPAA.pdf
- [S12] CostBench, Cloudflare plans and pricing (Vendr median): https://www.costbench.com/software/cdn-edge/cloudflare/
- [S13] Cloudways, Cloudflare Enterprise pricing: https://www.cloudways.com/blog/cloudflare-enterprise-pricing/
- [S14] Google ML Kit overview: https://developers.google.com/ml-kit
- [S15] Google ML Kit terms (data handling): https://developers.google.com/ml-kit/terms
- [S16] Stripe fee summaries (2026): https://flexprice.io/blog/stripe-pricing-breakdown-2026 , https://www.budgetforge.dev/tools/stripe-fees-2026 ; official page to confirm: https://stripe.com/us/pricing
- [S17] AWS HIPAA compliance (BAA via AWS Artifact): https://aws.amazon.com/compliance/hipaa-compliance/
