# SOLIS: Google Play release checklist

In Play Console order. Files referenced are in this folder (`marketing/play-store/`). Checked against Play Console Help
on 2026-10-17 (step 0 re-checked 2026-10-21); Google changes the Console often, so follow the Console's own labels if they differ.

## 0. Developer account: organization, not personal (do this first)

Google lists health apps ("Medical apps and Human Subjects Research apps") among the services that should be
published from an **organization** developer account, alongside financial, VPN and government apps. An organization
account needs a **D-U-N-S number** (free from Dun & Bradstreet; avoid paid third-party "D-U-N-S services") and
verification of the organization's legal name and address. Apple has the same rule for iOS (guideline 5.1.1(ix)).

- [ ] Form the legal entity (if not yet) and get its D-U-N-S number: `[FOUNDER: legal entity name, address, D-U-N-S]`.
      Allow up to about 30 days for a new D-U-N-S.
- [ ] If you do not have a Play developer account yet: create one as **Organization**, pay the one-time fee, complete
      identity and organization verification, and add a public developer email, phone and website.
- [ ] If you already have a **personal** account (the current case): do not publish SOLIS from it. Convert it to an
      organization account in Play Console (self-service, steps in `docs/PLAY_STORE.md`): verify the personal account,
      verify the organization website under About you, then **Change account type**, with a payments profile that
      carries the D-U-N-S number. Wait at least 72 hours after the switch before submitting the app. The switch
      cannot be undone. (Alternative: create a new organization account; nothing is published yet, so there is no
      app to transfer.)
      Publishing a Medical app from a personal account risks rejection or removal, and a personal account created after
      2023-11-13 also has to run the 12-tester, 14-day closed test before it can apply for production (step 6).
- [ ] Developer name shown on Play: use the legal entity name (or "SOLIS" if the entity trades as SOLIS). The web
      deletion page says "by SOLIS"; change it if the developer name differs.

## 1. Create the app

Play Console > Home > **Create app**

| Field | Value |
| --- | --- |
| App name | `SOLIS: Visit Notes and Claims` |
| Default language | English (United States) - en-US |
| App or game | App |
| Free or paid | Free (pilot; subscriptions can be added later; a paid app cannot become free later, free can add IAP) |
| Declarations | Tick Developer Program Policies and US export laws |

## 2. App content (Policy > App content), in this order

- [ ] **Privacy policy**: `https://solis-health.pages.dev/privacy` (expand it first, see `listing.md` > Privacy policy)
- [ ] **App access**: `app-access.md` (demo account, no credentials; optional reviewer test account)
- [ ] **Ads**: No (`target-audience.md`)
- [ ] **Content rating**: IARC questionnaire (`content-rating.md`)
- [ ] **Target audience and content**: 18 and over, Restrict Minor Access on (`target-audience.md`)
- [ ] **News apps**: No
- [ ] **COVID-19 contact tracing and status apps**: not one
- [ ] **Data safety**: `data-safety.md` (needs the deletion URL live: deploy `delete-account.html` first)
- [ ] **Government apps**: No
- [ ] **Financial features**: "My app doesn't provide any financial features"
- [ ] **Health apps**: Healthcare Services and Management only (`health-declaration.md`)
- [ ] **Foreground service permissions**: microphone (`health-declaration.md` section 2). Resolve the missing
      foreground service first (add it, or remove the permission), and record the demo video.
- [ ] Location: no form needed (foreground only). Nothing to do unless Play asks.

## 3. Store listing (Grow users > Store presence > Main store listing)

- [ ] App name, short description, full description: `listing.md`
- [ ] App icon: `graphics/icon-512.png`
- [ ] Feature graphic: `graphics/feature-graphic-1024x500.png` (+ alt text from `listing.md`)
- [ ] Phone screenshots: the 8 files in `graphics/phone/`, in order (+ alt text)
- [ ] Tablet screenshots: skip (optional)
- [ ] Store settings: category **Medical**, tags, contact email `[FOUNDER: support email]`, website
      `https://solis-health.pages.dev`
- [ ] Countries / regions (Production > Countries/regions): **United States** only for now (SOLIS is built for US
      codes, payers and law).

## 4. Upload the app bundle and enroll in Play App Signing

Bundle: `D:\Downloads\solis-1.0.2.aab` (version 1.0.2+3, 98.1 MB, 2026-10-18). Checked 2026-10-21: signed with the
upload key, certificate `CN=SOLIS, OU=Mobile, O=SOLIS, C=US`, SHA-256
`9F:1C:69:C0:37:AF:93:4D:0F:99:BE:A6:CD:55:F9:1D:67:37:F9:DE:E6:30:07:00:31:23:15:FB:38:98:57:9F`
(the same upload key as `docs/LAUNCH_COMPLIANCE.md`). Older bundles (1.0.0, 1.0.1) are also in `D:\Downloads`; nothing
has been uploaded yet, so upload the newest one. Each later upload needs a higher versionCode (bump the `+3` in
`pubspec.yaml`, then rebuild with `tooluild_release.ps1`).

- [ ] Testing > Internal testing > Create new release.
- [ ] Play App Signing: accept **Google-generated app signing key** (default). Your keystore
      `secrets/solis-upload.jks` stays the **upload key**. Keep its backup (`D:\SOLIS-signing-backup`). If the upload key
      is lost, Play support can reset it; the app signing key is held by Google.
- [ ] Upload `solis-1.0.2.aab`. Release name `1.0.2 (3)`. Release notes: "First pilot build."
- [ ] After upload, copy the **app signing key** SHA-256 from Setup > App signing and add it to the Worker as
      `SOLIS_SIGNING_CERT_SHA256` (with the upload key digest), so Play Integrity verdicts match Play-installed builds.
- [ ] Link the Google Cloud project for Play Integrity (Release > App integrity) if not already, and keep
      `SOLIS_INTEGRITY_ENFORCE` off until internal testers have signed in successfully.
- [ ] Optional: upload native debug symbols if Play shows the warning (R8 mapping is inside the AAB; Dart symbols in
      `D:\SOLIS-symbols` are for your own crash decoding).

## 5. Internal testing (first)

- [ ] Testers: create an email list (founder, team, up to 100). Copy the opt-in link and install from Play on a real
      phone.
- [ ] Smoke test from the Play-installed build: demo account, a recorded visit, note, claim tab, scan sample card,
      sign-up and sign-in with a real account, delete account, sign-in again fails.
- [ ] Check Play Console > Release > Pre-launch report for crashes and policy warnings.
- Internal testing has no review wait for the build itself, but the App content declarations are reviewed.

## 6. Closed testing (pilot clinics)

- [ ] Testing > Closed testing > Create track (for example "Pilot clinics"), promote the internal release.
- [ ] Testers: pilot clinicians' Google account emails or a Google Group.
- [ ] **If the developer account is a personal account created after 2023-11-13**: production access needs a closed
      test with **at least 12 testers opted in for at least 14 continuous days** (opting out and back in restarts the
      count), then Dashboard > **Apply for production** (questions about the test, the app and readiness; review usually
      7 days or less). An organization account does not have this requirement, which is another reason for step 0.
- [ ] Collect feedback; fix and ship builds with a higher versionCode.

## 7. Production

- [ ] Production > Create new release > promote the tested build. Start with a staged rollout (for example 20%).
- [ ] Before sending for review: all App content items green, store listing complete, privacy policy expanded, delete
      page live, BAAs signed before any real patient data (see `docs/LAUNCH_COMPLIANCE.md` section 2).
- [ ] Publishing overview > Send for review. Health apps can get extended review (7 days or more).
- [ ] After approval: update the website's download section to point to Play, and keep the sideload APK only for
      pilots that cannot use Play.

## Founder inputs needed

| Item | Where it goes |
| --- | --- |
| Legal entity name, address, D-U-N-S number | Developer account (step 0) |
| Support email (public) | Store listing contact, `delete-account.html` (2 places), IARC email |
| Reviewer test account (optional) | App access set 2 |
| Foreground service decision + demo video link | Health/permissions declaration |
| Expanded privacy policy (counsel review) | App content > Privacy policy |
| Deletion turnaround (30 days on the page) | `delete-account.html` |
| Deepgram / Anthropic retention terms | Data safety "ephemeral" answers |

## Sources

- Store listing assets and limits: https://support.google.com/googleplay/android-developer/answer/9866151
- App name and description limits: https://support.google.com/googleplay/android-developer/answer/113469
- Organization vs personal account (health apps, D-U-N-S): https://support.google.com/googleplay/android-developer/answer/13634885
- Testing requirement for new personal accounts: https://support.google.com/googleplay/android-developer/answer/14151465
- Prepare your app for review (App content): https://support.google.com/googleplay/android-developer/answer/9859455
- Data safety: https://support.google.com/googleplay/android-developer/answer/10787469
- Health apps declaration: https://support.google.com/googleplay/android-developer/answer/14738291
- Health content and services policy: https://support.google.com/googleplay/android-developer/answer/16679511
- Foreground service declaration: https://support.google.com/googleplay/android-developer/answer/13392821
- Location permissions: https://support.google.com/googleplay/android-developer/answer/9799150
- Account deletion: https://support.google.com/googleplay/android-developer/answer/13327111
- Content rating: https://support.google.com/googleplay/android-developer/answer/9859655
- Target audience: https://support.google.com/googleplay/android-developer/answer/9867159
- Financial features: https://support.google.com/googleplay/android-developer/answer/13849271
- ML Kit data disclosure: https://developers.google.com/ml-kit/android-data-disclosure
- Play Integrity data safety: https://developer.android.com/google/play/integrity/terms
