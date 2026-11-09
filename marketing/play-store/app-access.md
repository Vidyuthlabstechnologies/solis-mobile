# SOLIS: App access instructions for Google Play reviewers

Play Console > Policy > App content > App access.

## Choice

Select: **All or some functionality in my app is restricted**, then **+ Add new instructions**.

(Reason: the app opens on a sign-in screen. Reviewers can get past it with one tap, without credentials, but Play
asks for instructions whenever a sign-in screen is the first thing shown.)

## Instructions set 1: demo account (no credentials)

| Field | Value |
| --- | --- |
| Name | Demo account (no credentials needed) |
| Username | `not needed` |
| Password | `not needed` |
| Any other instructions | paste the text below |

```
No username or password is needed.

1. Open SOLIS. On the sign-in screen tap "Use demo account" (below the Sign in button).
2. The app opens with fictional patients and a fictional demo practice. Everything stays on the phone.
3. To see a visit: Patients > Margaret Vance (or any patient) > Start today's visit.
   Allow the microphone and location prompts. The consent sheet appears first; tap
   "Patient agreed, start recording", speak for a few seconds, then tap "Finish and write note".
   The on-device engine works offline after a one-time download of about 150 MB
   (menu > Integrations > on-device speech); without it the app uses the phone's speech recognizer.
4. Open the Claim tab to see diagnosis codes, claim checks and the "Why" button on each check.
5. Scan card (Patients > Scan card > "Try a sample card") reads a fictional sample card, no camera needed.
6. Claims in the demo are test only; nothing is sent to a payer.

Account deletion: Provider profile (top-right avatar) > Account > Delete account. It is enabled
for real SOLIS accounts (the demo account has no server account to delete). A test account for
deletion is in instructions set 2.

SOLIS is a documentation and billing tool for licensed clinicians. It is not a medical device.
```

## Instructions set 2 (optional, recommended): real test account for the deletion flow

Reviewers sometimes check that account deletion works. Create a dedicated reviewer account yourself on the
production server (in the app: Request access > create account), with a throwaway email you control, and enter it
here. Recreate it after each review if the reviewer deletes it.

| Field | Value |
| --- | --- |
| Name | Test clinician account (for account deletion) |
| Username | `[FOUNDER: reviewer test email]` |
| Password | `[FOUNDER: reviewer test password, stored in your password manager, not in this repo]` |
| Any other instructions | `Sign in with these details. Provider profile > Account > Delete account removes this account on the SOLIS server and erases the data on this phone.` |

Do not put credentials in this file or in git.

## Before submitting

- The Worker with `/api/v2/auth/*` must be deployed (see `docs/KEYS.md` "Still to do by the founder"), otherwise
  sign-up, sign-in and deletion fail for reviewers.
- Do not make access depend on location, a VPN, or an allow-list of emails during review.
- If Play Integrity enforcement is on (`SOLIS_INTEGRITY_ENFORCE=true`), keep it in report-only mode until the first
  Play-distributed build is approved, so the reviewer's devices are not blocked.

## Instructions set 3: SOLIS Pro (subscription) for reviewers

Added for Play Billing (2026-11-09). The demo account never asks for a subscription. A signed-in account (set 2)
sees the SOLIS Pro paywall when it starts a new visit. Give reviewers an access code so they can test past it
without paying:

1. In RevenueCat, create the code: Customers > search `access_<CODE>` (for example `access_PLAYREVIEW2026`).
   If it does not exist yet, open the app once, enter the code (it fails), and the customer appears. Then
   Customer > Entitlements > **Grant promotional entitlement** > `pro` > duration (e.g. 3 months).
2. Paste into the "Any other instructions" field, with the real code:

```
SOLIS Pro is a Google Play subscription. To test it without paying:
1. Sign in with the account in instructions set 2.
2. Open any patient and tap "Start today's visit". The SOLIS Pro screen appears.
3. Tap "I have an access code", enter PLAYREVIEW2026 and tap Unlock.
The paywall itself (prices from Google Play, Restore purchase, Privacy policy, Terms of use) can be
viewed before step 3. Subscriptions can be cancelled in Google Play > Subscriptions; the app links
there from Provider profile > Account > SOLIS Pro.
```

Revoke the code in RevenueCat after review if you want; the reviewer's Pro ends at once. The code lasts for the app session: after the app is closed and reopened, enter it again.
