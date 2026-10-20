# SOLIS self-serve onboarding

Prepared 2026-10-17. The journey a practice takes from the website to its
first real visit, on desktop and on a phone, what exists today, and the
smallest amount of work needed for each missing step.

## 1. The journey at a glance

| # | Step | Desktop | Phone only | Exists today |
| --- | --- | --- | --- | --- |
| 1 | Land on the site, read pricing and security | /pricing, /security | same, 360 px layout | Yes (this release) |
| 2 | Sign up | Website form: name, work email, password | same | **No.** Only the early-access form (`/api/early-access`, stored in KV `LEADS`) |
| 3 | Verify email | Link in email, opens the site | Link opens the site in the phone browser | **No** |
| 4 | Practice profile | NPI typed, details auto-filled from NPPES | same | **Partly.** The app's provider profile already looks up the NPI live in the national registry (`lib/services/npi_registry.dart`); the website has nothing |
| 5 | BAA acceptance | Click-through on the website | same | **Partly.** BAA template drafted; needs counsel review and a click-through page |
| 6 | Plan and payment | Stripe Checkout | Stripe Checkout (works in a phone browser) | **No.** /pricing shows plans; "billing opens with general availability" |
| 7 | Get the app | QR code on screen, scan with the phone | Direct APK link (pilot) or Google Play (later) | **Yes** for the APK link and QR (/get-started); Play listing not yet |
| 8 | First run in the app | Sign in, profile prefilled, integrations, model download on Wi-Fi, sample card, sample visit | same | **Partly.** Demo mode, sample card scan, sample conversations, model download card ("Use Wi-Fi. Downloads resume if interrupted.") exist; real sign-in is being built now |
| 9 | First real visit | Consent, record, note, claim (test mode until enrollment) | same | **Yes** in the app; real claims wait on vendor BAAs and payer enrollment |

## 2. Step by step

### Step 2. Sign up (website)

Fields: full name, work email, password (12+ characters), role, agree to
Terms and Privacy Policy. Turnstile on the form. One account is the practice
owner (admin); others are invited later.

Minimal work:
- Website: `/signup` page (same form styles as the early-access form).
- Backend (Worker, owned by the other worker's auth build):
  `POST /api/v2/auth/register` already planned. Add `email_verified_at` and
  `role` columns; send the verification email (Cloudflare Email Service or a
  transactional email vendor; no PHI in email).
- Pages Function `functions/api/signup.js` that forwards to the Worker so the
  website keeps `connect-src 'self'` in its CSP.

### Step 3. Verify email

Signed, single-use link valid for 24 hours: `/verify?token=...`. On success,
the browser gets a session cookie (HttpOnly, Secure, SameSite=Lax) and goes to
the practice profile. Resend link with rate limit (3 per hour).

Minimal work:
- Backend: `POST /api/v2/auth/verify` (token in body, never in logs) and
  `POST /api/v2/auth/resend`. Tokens stored as SHA-256 hashes with expiry.
- Website: `/verify` page that posts the token and shows the next step.

### Step 4. Practice profile with NPI lookup

The user types an NPI (individual NPI-1 or organization NPI-2). SOLIS calls the
NPPES NPI Registry API (`https://npiregistry.cms.hhs.gov/api/?version=2.1&number=<NPI>`,
public, no key) and fills: name, credential, primary taxonomy and specialty,
practice location address and phone. The user adds tax ID (EIN), place of
service usually used, accepted payers. Luhn check on the NPI before calling.

Minimal work:
- Pages Function `GET /api/npi?number=` that validates the 10 digits and the
  Luhn check, calls NPPES server-side, returns only the fields above, caches
  for 24 hours in KV. (Server-side avoids depending on NPPES CORS headers.)
- Backend: `PUT /api/v2/practice` storing the profile on the account. The app
  reads it at sign-in (step 8), so the provider profile is prefilled.
- Reuse the field list and validation from `lib/services/npi_registry.dart`
  so web and app agree.

### Step 5. BAA click-through (draft, counsel review required)

Show the full BAA text on the page, with a summary above it. The signer
confirms authority to sign for the practice, types full name and title, and
clicks "Accept". Store: BAA version and SHA-256 of the exact text, signer name,
title, practice legal name, EIN, timestamp, IP hash, user agent. Email a PDF
copy to the signer.

Rules:
- The template is a draft until a healthcare attorney reviews it
  (`docs/LAUNCH_COMPLIANCE.md` section 1). Until then the page says "Draft for
  pilot use" and real PHI does not flow.
- Downstream vendor BAAs (Anthropic, Deepgram, Stedi, Cloudflare or another
  PHI host) must be signed before SOLIS accepts real PHI, whatever the
  practice signs.

Minimal work:
- Website: `/baa` page.
- Backend: `POST /api/v2/practice/baa` (append-only acceptance record) and
  `GET /api/v2/practice/baa` (status for the app and the plan step). PDF can be
  rendered once per BAA version and stored in R2; the acceptance record links
  to it.

### Step 6. Plan and payment (Stripe Checkout)

The admin picks Solo or Practice, monthly or annual, and the number of
clinician seats. SOLIS creates a Stripe Checkout Session in subscription mode
and redirects. ACH Direct Debit and cards. On return, the webhook marks the
practice active.

Rules:
- Payment happens only on the website, never in the app
  (`docs/PRICING.md` section 5).
- Until general availability, /pricing says "billing opens with general
  availability" and the buttons lead to the early-access form.

Minimal work:
- Backend: `POST /api/v2/billing/checkout` (creates the session with
  `client_reference_id = practice id`), `POST /api/v2/billing/webhook`
  (verifies the Stripe signature; handles `checkout.session.completed`,
  `customer.subscription.updated` and `.deleted`, `invoice.payment_failed`),
  `POST /api/v2/billing/portal` (Stripe customer portal for seats, invoices,
  cancel). Store plan, seats, status and included-unit counters on the
  practice.
- Metering: count claim visits and cloud minutes per practice per month; send
  overage to Stripe as usage records at period end.
- Website: `/account` page with plan status and "Manage billing".

### Step 7. Get the app

- **Desktop:** /get-started shows a QR code that opens the APK download on the
  phone, plus the version, size and SHA-256 (from `tools/apk.json`). Later the
  QR points to the Google Play listing.
- **Phone:** the same page shows the direct "Download for Android" button and
  install steps (allow installs from this source). iPhone: "iOS not yet
  released".

Exists today: APK on R2, download card on the home page, QR on /get-started
(this release).

Later: Google Play internal testing, then closed testing with pilot practices,
then production (`docs/LAUNCH_COMPLIANCE.md` section 5).

### Step 8. First run in the app

1. **Sign in** with the website account (`/api/v2/auth/login`, being built by
   the other worker; `me`, `logout` and `delete-account` with it). "Try the
   demo" stays for reviewers and trials.
2. **Provider profile prefilled** from step 4 (`GET /api/v2/practice` and the
   signed-in user's own NPI). The user only confirms.
3. **Integrations:** shows what is on for the practice: Stedi (test or
   production), cloud transcription (on or off), cloud notes. Read from
   `GET /api/v2/health` plus the practice plan. Nothing to type.
4. **On-device model download** (about 150 MB): offer it on the first
   Wi-Fi connection; resumable; show size and free space first. The download
   card already exists (`lib/widgets/on_device_speech_card.dart`).
5. **Sample card and sample visit tutorial:** scan the built-in sample card
   (fictional Jordan A Rivera), then play a sample conversation through the
   note and the claim in test mode. Sample cards and conversations already
   exist (`scanDemo`, `lib/data/sample_conversations.dart`); the guided
   tutorial overlay does not.

Minimal app work (for the app worker, not done here): call the practice
endpoint after sign-in, a 4-screen first-run checklist, and the Wi-Fi check
before starting the model download.

### Step 9. First real visit

Consent, record, review the note, confirm uncertain diagnoses, send the claim.
Claims stay in test mode until the practice's payer enrollment through Stedi is
complete and the vendor BAAs are signed. The user guide covers every screen.

## 3. Desktop vs phone

| | Desktop | Phone only |
| --- | --- | --- |
| Sign-up, verify, profile, BAA, payment | Full width forms, QR at the end | Same pages at 360 px; the verify link opens in the phone browser |
| Getting the app | Scan the QR with the phone camera | Tap "Download for Android" |
| Typing the BAA signer name and EIN | Easy | Works; keep fields few |
| Practice admin later | `/account` | `/account` in the phone browser |

## 4. Build order (smallest path to self-serve)

1. Real sign-in in the app and Worker (in progress, other worker).
2. Website sign-up and verify, forwarding to the same auth endpoints.
3. Practice profile with the NPI lookup function.
4. BAA page (after counsel review).
5. Stripe Checkout, webhook, portal and metering (at general availability).
6. App first-run checklist and tutorial.
7. Google Play listing; QR switches to Play.

## 5. Data that must never be in these flows

No patient information on any website page, form or email. Verification and
billing emails carry no PHI. Tokens are never put in logs or query strings
except the one-time email verification link, which is single-use and expires.
