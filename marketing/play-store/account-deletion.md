# SOLIS: Account deletion (Play User Data policy)

Play requires, for any app that lets users create an account: (1) an in-app path to delete the account and its data,
and (2) a web link where users can request deletion without reinstalling the app. The link goes in
Play Console > Policy > App content > Data safety (Data deletion questions) as the "Delete account URL".

## 1. In-app path (done in v1.0.0)

Provider profile (tap the initials avatar at the top right of Patients) > **Account** > **Delete account** >
enter password > **Delete account**.

What it does (from `lib/widgets/account_section.dart` and `lib/services/auth_service.dart`):
- Calls `POST /api/v2/auth/delete-account` with the password; the server deletes the account and all sessions.
- Erases the patients, visits, notes and provider profile stored on the phone, then signs out.
- Claims already sent to a payer are not recalled (the dialog says so).
- Demo mode: the button is disabled ("Available when signed in with a SOLIS account"); the demo data lives only on
  the phone and is removed by uninstalling or clearing app storage.

## 2. Web deletion page (source added, NOT deployed)

- Source: `marketing/site/src/delete-account.html`
- URL after deploy: `https://solis-health.pages.dev/delete-account` (Pages serves `delete-account.html` at the pretty URL)
- Meets the Play checklist: names the app and developer as on the listing, shows the in-app steps prominently,
  lets users request deletion (form + email), explains what is deleted, what is kept and why.
- The form reuses the existing early-access form script (`assets/site.js`, form id `access-form`) and the existing
  `POST /api/early-access` function, with hidden fields `practice = "Account deletion request"`, `role = "Other"`,
  `specialty = "Account deletion"`. No new backend code. Requests land in the same LEADS KV namespace; filter on
  `practice == "Account deletion request"`.

### Founder to do before submitting

1. Replace both `[FOUNDER-SUPPORT-EMAIL]` placeholders in `delete-account.html` with the real support address
   (the same one as the store listing contact email).
2. Confirm the promise on the page: "We confirm by email from that address before deleting, then delete the account
   within 30 days and reply when it is done." Change the number if you want a different window.
3. Build and deploy the site (`node tools/build.mjs`, then the usual `wrangler pages deploy`), and open
   `https://solis-health.pages.dev/delete-account` to check it loads without errors.
4. Recommended: link the page from the privacy page and the footer ("Delete your account"), and add it to
   `sitemap.xml`. Not done here, to keep this change to one new file.
5. Process requests: look up the email in the Worker's users table (D1), delete the user and sessions (the same
   effect as the in-app delete), and email the requester. Keep a log of the date each request was completed.
6. Write the retention exceptions into the privacy policy (claims sent to payers and clearinghouse records).

## Data safety answers that depend on this

- "Do you provide a way for users to request that their data is deleted?" **Yes**
- "Delete account URL": `https://solis-health.pages.dev/delete-account`

Source: [Understanding Google Play's app account deletion requirements](https://support.google.com/googleplay/android-developer/answer/13327111).
