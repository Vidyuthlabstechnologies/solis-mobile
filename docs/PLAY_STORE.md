# Publishing SOLIS on Google Play

Status on 2026-10-21: not submitted. Upload candidate `D:\Downloads\solis-1.0.2.aab` (1.0.2+3, signed with the upload
key in `secrets/solis-upload.jks`). The full step-by-step checklist and every form answer are in
`marketing/play-store/` (start with `release-checklist.md`).

## Blocker: the developer account must be an Organization account

SOLIS is a Medical app (clinical notes, coding, claims). Google requires developers who offer health apps, which it
describes as "Medical apps and Human Subjects Research apps", to register as an **organization**, the same as
financial-services, VPN and government apps. Organization registration needs a **D-U-N-S number**, and the account
details must stay consistent with the Dun & Bradstreet profile.

The current Play Console account is a **Personal** account, so it has to be converted to an Organization account
(or a new Organization account created) before SOLIS is submitted. Do not submit SOLIS from the personal account.

Source: Play Console Requirements, https://support.google.com/googleplay/android-developer/answer/10788890

## What the user needs to do

1. Get a D-U-N-S number for the legal entity from Dun & Bradstreet. It is free; ignore third-party services that
   charge for it. Allow up to about 30 days for a new number.
2. Convert the personal account in Play Console (self-service):
   1. Make sure the personal account is fully verified, with no pending verification warnings on the Home page.
   2. Under **About you**, add and verify the organization's official website (for now
      `https://solis-health.pages.dev`, or the company domain). The account type option appears only after the
      website is verified.
   3. Select **Change account type**.
   4. Create a payments profile for the organization (this is where the D-U-N-S number is entered), or pick an
      existing one with the organization's details.
   5. Enter the organization type (company, non-profit, academic institution or government), size and phone.
   6. Enter contact details. Google checks the contact and public developer email and phone with one-time codes.
   7. Complete identity verification and upload any documents asked for on the Account details page.
   8. Under **About you**, select **Link your payments profile to your developer account**, then **Confirm** and
      **Save**.
3. Wait at least 72 hours after the switch before submitting the app.
4. Continue with `marketing/play-store/release-checklist.md` from step 1.

Notes:

- The switch cannot be reversed. An organization account cannot go back to an individual account.
- An organization account does not have the 12-tester, 14-day closed-test requirement that applies to new personal
  accounts before production access.
- Use the legal entity name as the developer name, or update the "by SOLIS" wording on the web account-deletion page
  to match.

Source: Change your developer account type, https://support.google.com/googleplay/android-developer/answer/16260648

## Related files

| File | What it covers |
| --- | --- |
| `marketing/play-store/release-checklist.md` | Play Console steps in order, from account to production |
| `marketing/play-store/listing.md` | Store listing text and screenshot alt text |
| `marketing/play-store/data-safety.md` | Data safety form answers |
| `marketing/play-store/health-declaration.md` | Health apps declaration and the microphone foreground-service form |
| `marketing/play-store/content-rating.md`, `target-audience.md`, `app-access.md`, `account-deletion.md` | Other App content forms |
| `marketing/play-store/graphics/` | Icon, feature graphic, phone screenshots |
| `docs/LAUNCH_COMPLIANCE.md` | Wider launch compliance list (Apple has a similar organization rule, guideline 5.1.1(ix)) |
