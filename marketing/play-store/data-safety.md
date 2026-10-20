# SOLIS: Data safety form answers

Play Console > Policy > App content > Data safety. Based on the code in `lib/` and the Worker API in `docs/KEYS.md`
as of v1.0.0 (2026-10-17). Re-check these answers whenever a data flow changes; the form is reviewed with each release.

Re-checked for v1.0.2 (2026-10-21): the network calls added in 1.0.1 and 1.0.2 are plain GET requests for public
data, the signed code-set files on R2 (`manifest.json` and changed files) and the CMS updates list from the code-set
Worker (`/v1/transmittals`). They carry no user, patient or account data (only what any HTTPS request carries), so the answers below are unchanged.

## How the app actually moves data (what the answers are based on)

| Flow | What leaves the phone | Where it goes | When |
| --- | --- | --- | --- |
| Clinician account | Full name, email, password, optional NPI; session tokens | SOLIS server (Cloudflare Worker, `/api/v2/auth/*`) | Sign-up, sign-in, refresh, sign-out, delete account. Not in demo mode. |
| Note writing (cloud mode) | Visit transcript text, patient age and sex, place of service, visit type | SOLIS server, which calls Anthropic (Claude) | When the clinician finishes a visit in cloud mode |
| Live transcription (cloud mode) | Visit audio | Deepgram (`wss://api.deepgram.com`) directly from the phone, using a short-lived token from the SOLIS server | Only when the practice turns cloud mode on, after patient consent |
| Platform speech fallback | Visit audio | Android's system speech recognizer (Google), which may process audio on Google servers | Only when neither the on-device engine nor cloud mode is used |
| Eligibility, claims, claim status | Patient name, date of birth, sex, address, member ID, payer, diagnosis and procedure codes, charges, provider NPI and tax ID, service address; ambulance pick-up/drop-off addresses | SOLIS server, which forwards to Stedi (clearinghouse), which forwards to the payer | When the clinician checks eligibility or sends a claim |
| NPI lookup | The NPI number typed | CMS NPPES NPI Registry (public API) | Provider profile |
| ICD-10 search | Search words typed | NLM Clinical Tables (public API) | Diagnosis search |
| On-device model download | Nothing about the user (file download) | GitHub releases (sherpa-onnx models) | One-time, on-device mode |
| Card scanning | Nothing. Images are read on the phone by Google ML Kit and deleted | Stays on the phone | Scan card |
| ML Kit SDK telemetry | Device model, OS, app package and version, per-installation ID, performance and error codes | Google (ML Kit), not shared | Whenever ML Kit runs |
| Play Integrity | Attestation token (device attestation, app metadata) | Google Play, verified by the SOLIS server | Sign-in and sign-up |
| Visit location | Nothing. GPS fix and street address are stored with the visit on the phone. The street address is looked up by Android's system Geocoder | Stays on the phone (Geocoder is an OS service) | Consent and visit start |
| Patients, visits, notes, claims | Stored on the phone (app-private storage, Android file-based encryption). There is no SOLIS patient database on the server | Phone | Always |

Everything off the phone uses HTTPS/WSS (TLS). The SOLIS server host is TLS-pinned in the app.

## Section 1: Data collection and security

| Question | Answer |
| --- | --- |
| Does your app collect or share any of the required user data types? | **Yes** |
| Is all of the user data collected by your app encrypted in transit? | **Yes** |
| Which of the following methods of account creation does your app support? | **Username and password** (email + password). Also note there is a demo mode with no account. |
| Do you provide a way for users to request that their data is deleted? | **Yes** (in-app: Provider profile > Account > Delete account; web: `https://solis-health.pages.dev/delete-account`) |
| Delete account URL | `https://solis-health.pages.dev/delete-account` (page source added in `marketing/site/src/delete-account.html`; deploy it before submitting) |
| Does your app allow users to create an account using an account from another app (sign in with Google etc.)? | **No** |
| Independent security review (MASA) | **No** (not done) |
| Committed to Play Families policy | Not applicable (adults only) |

## Section 2: Data types

"Collected" in Play's sense means sent off the device. "Shared" means sent to a third party. Play does **not**
count transfers to service providers that process data on your behalf (Anthropic, Deepgram, Stedi as your
processors under BAAs), or transfers the user starts and expects (sending a claim to a payer), as sharing.
The recommended answers below therefore mark these as **collected, not shared**, and the privacy policy names
the vendors. If counsel prefers maximum disclosure, flip "Shared" to Yes for Health info, Audio, Name, Address
and Other info; nothing else changes.

Tick these and leave every other type unticked:

### Personal info

| Type | Collected | Shared | Ephemeral | Required or optional | Purposes |
| --- | --- | --- | --- | --- | --- |
| **Name** | Yes | No | No | Required | App functionality, Account management |
| **Email address** | Yes | No | No | Required | Account management, App functionality |
| **User IDs** | Yes | No | No | Required | Account management, Fraud prevention, security, and compliance |
| **Address** | Yes | No | No | Required | App functionality |
| **Other info** | Yes | No | No | Required | App functionality, Account management |

- Name: the clinician's name on the account, and patients' names on eligibility checks and claims.
- User IDs: SOLIS account ID and session tokens.
- Address: patient and practice addresses on claims (and ambulance pick-up/drop-off).
- Other info: clinician NPI; patient date of birth, sex, and insurance member ID on claims.
- Do **not** tick Phone number (not sent), Race and ethnicity, Political or religious beliefs, Sexual orientation.
- "Required": a clinician cannot send a claim without these. (Demo mode sends nothing, but the form asks about the feature.)

### Financial info

| Type | Collected | Shared | Ephemeral | Required or optional | Purposes |
| --- | --- | --- | --- | --- | --- |
| **Other financial info** | Yes | No | No | Optional | App functionality |

- Claim charges, payer and insurance member details sent to Stedi. No payment cards, no purchase history.
  Optional because claims are optional (a clinician can use SOLIS for notes only).
  If you judge claim charges are not the user's own financial info, this row can be left out; keeping it is the
  more conservative answer.

### Health and fitness

| Type | Collected | Shared | Ephemeral | Required or optional | Purposes |
| --- | --- | --- | --- | --- | --- |
| **Health info** | Yes | No | No | Optional | App functionality |

- Visit transcripts (cloud mode, to the SOLIS server and Anthropic), diagnosis and procedure codes (claims, to Stedi
  and the payer). Optional: in on-device mode with no claims sent, health info stays on the phone.
- Ephemeral: answer **No**. The SOLIS server does not log request bodies, but Stedi stores claims and Anthropic's
  retention depends on your API agreement (zero data retention only if arranged).
- Do not tick Fitness info.

### Audio

| Type | Collected | Shared | Ephemeral | Required or optional | Purposes |
| --- | --- | --- | --- | --- | --- |
| **Voice or sound recordings** | Yes | No | Yes, if Deepgram is configured not to retain audio; otherwise No | Optional | App functionality |

- Only in cloud mode (Deepgram) or the platform speech fallback. On-device mode keeps audio on the phone.
- Before answering "Ephemeral: Yes", get written confirmation from Deepgram (BAA and no audio retention / opt-out of
  model improvement). Until then answer **No**.

### Location

**Do not tick** Approximate or Precise location. The GPS fix and the street address stay on the phone with the visit
record; the app never sends them to SOLIS or a vendor. (The address is resolved by Android's system Geocoder, an OS
service.) If a future version sends the visit location to the server or puts it on a claim, tick **Precise location**:
Collected Yes, Shared No, Required, App functionality.

### Photos and videos

**Do not tick.** Card photos are read on the phone by ML Kit and deleted. Nothing is uploaded.

### App activity

**Do not tick.** No analytics or tracking SDKs. (If you later opt Play Integrity into "environment details", tick
App activity > Other actions: Collected, not shared, Fraud prevention, security, and compliance.)

### App info and performance

| Type | Collected | Shared | Ephemeral | Required or optional | Purposes |
| --- | --- | --- | --- | --- | --- |
| **Diagnostics** | Yes | No | No | Required | Analytics |
| **Other app performance data** | Yes | No | No | Required | Analytics, Fraud prevention, security, and compliance |

- Google ML Kit SDK diagnostics (device model, OS, latency, error codes) and Play Integrity app metadata.
  No crash reporting SDK is in the app, so do not tick Crash logs.

### Device or other IDs

| Type | Collected | Shared | Ephemeral | Required or optional | Purposes |
| --- | --- | --- | --- | --- | --- |
| **Device or other IDs** | Yes | No | No | Required | Fraud prevention, security, and compliance, Analytics |

- ML Kit per-installation identifier; Play Integrity device attestation token.

### Not collected (leave unticked)

Messages, Files and docs, Calendar, Contacts, Web browsing, Photos and videos, Location, App activity, Fitness info,
Crash logs, Music or other audio files.

## What the store will show (preview)

- Data shared: No data shared with third parties
- Data collected: Personal info, Financial info, Health and fitness, Audio, App info and performance, Device or other IDs
- Data is encrypted in transit
- You can request that data be deleted

## Founder checks before submitting

1. Sign BAAs with Anthropic, Deepgram and Stedi (and confirm the Cloudflare PHI path), as `docs/LAUNCH_COMPLIANCE.md`
   says. The "service provider, not shared" answers depend on these vendors processing data only on your behalf.
2. Expand the privacy policy so it matches this form (types collected, vendors, retention, deletion link). Play
   rejects listings whose privacy policy and Data safety form disagree.
3. Deletion: the in-app flow deletes the server account and sessions and erases phone data. Claims already sent to a
   payer cannot be recalled; say so in the privacy policy (Play allows retention for legal reasons if disclosed).
4. `FOREGROUND_SERVICE_MICROPHONE` is declared but the current build has no foreground service of type microphone
   (see `health-declaration.md`). This does not change the Data safety answers.

Sources: [Data safety form help](https://support.google.com/googleplay/android-developer/answer/10787469),
[ML Kit data disclosure](https://developers.google.com/ml-kit/android-data-disclosure),
[Play Integrity data safety](https://developer.android.com/google/play/integrity/terms),
[Account deletion requirements](https://support.google.com/googleplay/android-developer/answer/13327111).
