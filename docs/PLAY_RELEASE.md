# Releasing SOLIS on Google Play with subscriptions

The click-by-click order for the owner. Everything secret goes into GitHub, Play Console or RevenueCat directly,
never into chat or the repo. The organization-account blocker in `docs/PLAY_STORE.md` comes first; nothing below
can go live until the account is an Organization account.

## What the app does (since the Play Billing PR)

- **SOLIS Pro** (RevenueCat entitlement `pro`) is needed to start a **new visit** in a signed-in account. Patients,
  past visits, notes and exports stay open without it. The **demo account is always free**.
- A build without `REVENUECAT_ANDROID_KEY` sells nothing and never blocks (local and CI test builds).
- Paywall: plans and prices from Google Play, free-trial label when Play offers one, Restore purchase,
  "I have an access code", privacy and terms links. Pending payments are explained, not unlocked.
- Profile > Account: SOLIS Pro status, Manage (opens Google Play subscriptions), Privacy policy, Terms of use.
- Signed-in clinicians are RevenueCat customers under their SOLIS account ID, so Pro follows them across phones.

## 1. Play Console: subscriptions (after the first bundle is uploaded to any track)

Play only lets you create subscriptions once a bundle with the BILLING permission is uploaded. Upload the first
bundle from the release workflow (step 4) to **Internal testing**, then:

1. Monetize > Products > **Subscriptions** > Create subscription.
   - Product ID `solis_pro` (cannot be changed later), name "SOLIS Pro".
2. Add base plan **`monthly`**: auto-renewing, 1 month, price $149.00 (confirmed 2026-11-11; set per country or let Play convert).
3. Add base plan **`yearly`**: auto-renewing, 1 year, price $1,548.00, i.e. $129/month (confirmed 2026-11-11).
4. Free trial on both base plans: Add offer > "New customer acquisition", eligibility "Never had this
   subscription", phase **Free trial**, **14 days** (confirmed 2026-11-11: a first real claim takes more than a
   week to come back). The app shows whatever length Play offers, so changing it needs no new build.
   The paywall appears only when a clinician bills a real claim; notes, visits and test claims are always free.
5. Activate both base plans.
6. Setup > **Payments profile** must be the organization's (ML Dynamic Solutions Private Limited), with a bank
   account for payouts.
7. Setup > License testing: add the Gmail accounts that test purchases (they are not charged).

## 2. Google Cloud: let RevenueCat read Play purchases

1. Google Cloud console > the project linked to Play Console > enable **Google Play Android Developer API** and
   **Google Play Developer Reporting API**.
2. IAM > Service accounts > Create (e.g. `revenuecat`) > Keys > Add key > JSON. Keep the file off the repo.
3. Play Console > Users and permissions > Invite new user > the service account email > app permissions for SOLIS:
   View app information, View financial data, Manage orders and subscriptions.
4. It can take up to 36 hours before Google accepts the credentials.

## 3. RevenueCat

1. Create a project "SOLIS" > Add app > **Google Play**, package `com.solis.clinical.solis_mobile`, upload the JSON
   key from step 2.
2. Product catalog > Products > import `solis_pro:monthly` and `solis_pro:yearly`.
3. Entitlements > New > identifier **`pro`** > attach both products.
4. Offerings > `default` (mark as current) > packages **`$rc_monthly`** → `solis_pro:monthly`,
   **`$rc_annual`** → `solis_pro:yearly`.
5. API keys > copy the **Google Play public SDK key** (starts with `goog_`). It goes into GitHub only (step 4).
6. Optional: Integrations > Google Real-Time Developer Notifications (RevenueCat shows the Pub/Sub topic to paste
   into Play Console > Monetization setup), so renewals and cancellations show up at once.
7. Reviewer access code: see `marketing/play-store/app-access.md`, instructions set 3.

## 4. GitHub: secrets and the release workflow

Repository > Settings > Environments > New environment **`play-release`** (add yourself as a required reviewer if
you want an approval click before each build). In that environment add:

| Secret | What |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | The upload keystore, base64. On Windows PowerShell: `[Convert]::ToBase64String([IO.File]::ReadAllBytes("secrets\solis-upload.jks"))` |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password (from `android/key.properties` on your PC) |
| `ANDROID_KEY_ALIAS` | Key alias (same file) |
| `ANDROID_KEY_PASSWORD` | Key password (same file) |
| `REVENUECAT_ANDROID_KEY` | The `goog_` key from RevenueCat |

Variables (same environment, not secret): `SUPPORT_EMAIL`, and optionally `PRIVACY_POLICY_URL`, `TERMS_URL`,
`DELETE_ACCOUNT_URL` (defaults are the solis-health.pages.dev pages).

Then:

1. Actions > **Launch readiness** > Run workflow. It lists anything missing (names only) and checks the privacy,
   terms and deletion pages are live.
2. Bump `version:` in `pubspec.yaml` (and `solisVersion`) for each upload; Play rejects a reused version code.
3. Actions > **Release (Play bundle)** > Run workflow. It runs the tests, builds the signed `.aab` and `.apk`, and
   fails if the bundle is debug-signed or the BILLING permission is missing. The run summary shows the upload key
   **SHA-1**: it must match Play Console > Test and release > App integrity > Upload key certificate.
4. Download the artifact and upload `app-play-release.aab` in Play Console. The same run also builds
   `app-standalone-release.apk` for the website (see `docs/STANDALONE.md`).

## 5. Website

Deploy the site so the new **Terms of use** page and the updated privacy page are live
(`cd marketing/site && node tools/build.mjs && npx wrangler pages deploy --branch main`).
The terms page is a plain-language draft; have it reviewed before launch.

## 6. Play Console forms to update

- App content > **Data safety**: re-answer from `marketing/play-store/data-safety.md` (adds Purchase history and
  RevenueCat).
- App content > **App access**: add instructions set 3 (access code).
- Store listing: Play shows "In-app purchases" automatically. Do not put prices in the description.
- Monetize > Subscriptions: each base plan needs its benefits text (e.g. "Unlimited visits, notes and claims").

## 7. Test before going wider

1. Internal testing track, a license-tester Gmail on a real phone, install from the Play opt-in link
   (sideloaded APKs cannot buy).
2. Sign in with a real SOLIS account > start a visit > paywall shows Play's prices > subscribe (test card) >
   visit starts. Check RevenueCat > Customers shows the SOLIS account ID with `pro` active.
3. Uninstall, reinstall, sign in > Pro is still on. Profile > Account > Restore and Manage both work.
4. Cancel in Google Play > after the test renewal window Pro ends; past visits are still readable.
5. Enter the reviewer code on a fresh account > unlocks.

Then promote the release to closed or production testing as `docs/PLAY_STORE.md` describes.
