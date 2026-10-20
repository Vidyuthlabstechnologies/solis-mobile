# SOLIS keys and secrets

Vendor keys (Anthropic, Deepgram, Stedi, AWS) never go inside the Android app. Anyone can unpack an APK and read every string in it. The keys live in two places only:

1. On the founder's computer, in `secrets/keys.local.json` (this repo) and `.dev.vars` (Worker repo). Both are git-ignored and readable only by the Windows user who saved them.
2. In production, as Cloudflare Worker secrets on `cloudflare-healthcare-rcm-agentic-cloud`.

The app calls our Worker. The Worker calls the vendors.

```
SOLIS app  --Bearer SOLIS_APP_TOKEN-->  Worker /api/v2/*  --vendor key-->  Anthropic / Stedi / Deepgram
```

## Open the key vault

From the `solis_mobile` folder:

```powershell
python tool\keyvault\keyvault.py
```

The terminal prints the page address and a one-time session token, and the browser opens the page with the token already filled in. If the browser does not open, go to the printed address and paste the token. The token is valid until you press Ctrl+C.

To try it without touching production:

```powershell
python tool\keyvault\keyvault.py --dry-run
```

Dry run writes the local files but does not call Cloudflare.

Requirements: Python 3.10 or newer (standard library only), Node.js, and Wrangler logged in to the Cloudflare account that owns the Worker (`npx wrangler login` once, inside the Worker folder).

## What the page does on Save

1. Validates every value (no spaces in keys, no quotes or control characters). If anything is wrong, nothing is saved.
2. Writes `solis_mobile\secrets\keys.local.json` and `cloudflare-healthcare-rcm-agentic-cloud\.dev.vars`. Each file is written atomically and its permissions are set so only your Windows user can read it (`icacls /inheritance:r`).
3. For every value you changed, runs `npx wrangler secret put NAME` in the Worker folder. The value is passed on standard input, never on the command line, so it does not appear in the process list or shell history.
4. Shows one row per key: updated or failed, with Wrangler's exact error. Values are shown only as their last 4 characters. If an error message happens to contain a value, it is replaced with `[redacted]`.

A blank field keeps the saved value. Tick "Re-push every saved key" to send all saved keys to production again (for example after creating a new Worker).

Each `wrangler secret put` publishes a new version of the Worker with the code that is currently deployed, so saving a key takes effect within seconds without a code deploy.

## Fields

| Name | Secret | Used for |
| --- | --- | --- |
| `SOLIS_APP_TOKEN` | yes | Shared secret the app sends as `Authorization: Bearer`. Use Generate. |
| `ANTHROPIC_API_KEY` | yes | Claude writes the SOAP note (`/api/v2/note`). Without it, or if Claude is unavailable, the Worker uses Workers AI and says so in `warnings`. |
| `ANTHROPIC_WORKSPACE_ID` | no | Only for an organization key that is not scoped to a workspace (Anthropic then requires the `anthropic-workspace-id` header). |
| `DEEPGRAM_API_KEY` | yes | Mints short-lived Deepgram tokens for live transcription. |
| `STEDI_API_KEY` | yes | Eligibility, 837P claims and claim status. |
| `STEDI_MODE` | no | `test` or `production`. The page shows which. In test mode claims get usage indicator `T`. |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` | yes, yes, no | Optional, reserved for Bedrock or Transcribe. Stored and reported by `/api/v2/health`; no route uses them yet. |
| `SOLIS_SUBMITTER_ORG_NAME`, `SOLIS_SUBMITTER_ID`, `SOLIS_SUBMITTER_CONTACT_NAME`, `SOLIS_SUBMITTER_PHONE`, `SOLIS_SUBMITTER_EMAIL` | no | 837P submitter, added by the Worker when a claim has no `submitter`. Stedi needs a phone or an email. |
| `SOLIS_RECEIVER_ORG_NAME` | no | Default 837P receiver name when a claim has no `receiver`. The payer ID goes in each claim as `tradingPartnerServiceId`. |
| `SOLIS_REQUIRE_USER_SESSION` | no | `true` makes a clinician session mandatory on `/note`, `/stedi/*`, `/deepgram/*`. Leave unset until every installed build signs in. |
| `GOOGLE_PLAY_INTEGRITY_SA_JSON` | yes | Google service account JSON allowed to call the Play Integrity API. Unset: the check is skipped (and counted). |
| `SOLIS_INTEGRITY_ENFORCE` | no | `true` blocks sign-in on a failed verdict. Default report-only. |
| `SOLIS_ANDROID_PACKAGE`, `SOLIS_SIGNING_CERT_SHA256` | no | Package name expected in the verdict (default `com.solis.clinical.solis_mobile`) and optional signing certificate digests. |
| `SOLIS_GCP_PROJECT_NUMBER` | no (app build) | Only in `keys.local.json`: the Google Cloud project number the app passes to Play Integrity. Not a Worker secret. |

The non-secret 837P values are also stored as Worker secrets. That keeps them out of git and lets them change without a code deploy.

## The app token

`SOLIS_APP_TOKEN` is not a vendor key. It only lets a copy of the app use our Worker, which is rate limited (60 notes per hour and 120 Stedi or Deepgram calls per minute per IP, and repeated bad tokens are locked out). It will be readable inside a released APK, so treat it as a revocable app identifier, not as user authentication. User authentication is the clinician account below (`X-Solis-Session`).

Build releases with `tool\build_release.ps1` (see "Release build"). It reads the token from the local store without printing it.

## Rotation

1. Create the new key in the vendor's dashboard.
2. Open the key vault, paste the new key, Save. Check the row says updated.
3. Check `GET /api/v2/health` still reports the integration as configured, and run one real request.
4. Revoke the old key in the vendor's dashboard.

For `SOLIS_APP_TOKEN`: Generate a new one, Save, rebuild and release the app. Old app builds stop working at that moment, so release first if users depend on them.

If a key leaks: revoke it at the vendor first, then rotate as above.

## Where nothing should be

- Not in git. Both repos ignore `secrets/`, `keys.local.json` and `.dev.vars`.
- Not in the app source, `pubspec.yaml`, Android resources or any committed file.
- Not in chat, email or tickets. Share the last 4 characters if you need to say which key.
- Not in logs. The Worker never logs request bodies on `/api/v2`, and the key vault logs only method and path.

## Still to do by the founder

1. Review the Worker changes (`src/v2/`, `src/types/env.ts`, the two lines in `src/index.ts`), then deploy them once from the Worker folder:
   ```powershell
   npm test
   npx tsc --noEmit
   npx wrangler deploy
   ```
   Until this deploy, production has the secrets but not the `/api/v2` routes.
2. Run the key vault without `--dry-run` and save the real keys.
3. Call `GET /api/v2/health` with the app token and confirm every integration you use is `true`.
4. Point the app at the `/api/v2` routes and send the bearer token (app change, not done yet).
5. Stedi: start with a test key and `STEDI_MODE=test`; switch to production only after a test claim round trip works.

## Worker API reference

All routes need `Authorization: Bearer <SOLIS_APP_TOKEN>`. Missing or wrong token: `401`. Token not configured on the Worker: `503`.

### GET /api/v2/health

```json
{ "ok": true, "integrations": { "anthropic": true, "workersAi": true, "stedi": true, "stediMode": "test",
  "deepgram": true, "aws": false, "submitter837p": true } }
```

### POST /api/v2/note

Request:

```json
{ "transcript": "Doctor: ...\nPatient: ...", "patient": { "age": 54, "sex": "F" },
  "placeOfService": "11", "visitType": "Established outpatient" }
```

Response `200`:

```json
{ "success": true, "provider": "anthropic", "model": "claude-haiku-5-5",
  "note": {
    "soap": { "subjective": ["..."], "objective": ["..."], "assessment": ["..."], "plan": ["..."] },
    "vitals": [ { "name": "BP", "value": "128/82", "unit": "mmHg" } ],
    "diagnoses": [ { "description": "Possible pneumonia", "icd10Candidate": "", "certainty": "uncertain",
                     "evidence": [ { "quote": "Pneumonia is possible", "matched": true } ] } ] },
  "warnings": [] }
```

Evidence quotes are checked word for word against the transcript (`matched`). A diagnosis marked confirmed with no matching quote is downgraded to uncertain and a warning is added. Errors: `400` bad input, `413` transcript over 60,000 characters, `422` the model declined, `429` hourly limit, `502` model error, `503` no AI configured. Errors are `{ "success": false, "error": "..." }`.

### POST /api/v2/stedi/eligibility, /api/v2/stedi/claims, /api/v2/stedi/claim-status

The request body is Stedi's own JSON for:

- eligibility: `POST https://healthcare.us.stedi.com/2024-04-01/change/medicalnetwork/eligibility/v3`
- claims (837P): `POST https://healthcare.us.stedi.com/2024-04-01/change/medicalnetwork/professionalclaims/v3/submission`
- claim status (276/277): `POST https://healthcare.us.stedi.com/2024-04-01/change/medicalnetwork/claimstatus/v2`

The response is Stedi's JSON with Stedi's status code. For claims, send an `Idempotency-Key` header (for example the claim ID) so a retry is never billed twice; the Worker forwards it. `503` if `STEDI_API_KEY` is not set, `502` if Stedi cannot be reached.

### POST /api/v2/deepgram/token

Request (optional): `{ "ttlSeconds": 60 }` (10 to 600, default 60).

Response:

```json
{ "accessToken": "<jwt>", "expiresIn": 60, "authScheme": "Bearer", "websocketUrl": "wss://api.deepgram.com/v1/listen" }
```

Open the websocket to `websocketUrl` with the header `Authorization: Bearer <accessToken>` (plus the usual Deepgram query parameters). The token only has to be valid when the socket opens; the stream stays up afterwards. Deepgram supports these temporary tokens (`POST /v1/auth/grant`), so no audio relay through the Worker is needed.

## Clinician accounts (`/api/v2/auth/*`)

Every route still needs the app token. A signed-in clinician also sends `X-Solis-Session: <accessToken>`.

| Route | Body | Success | Errors (`{ "error", "code" }`) |
| --- | --- | --- | --- |
| `POST /auth/register` | `{ "email", "password" (12 to 256 chars), "fullName", "npi"? }` | `201 { user, session }` | `400` invalid_email / weak_password / invalid_name / invalid_npi, `409` email_taken, `429` (10 sign-ups per IP per hour) |
| `POST /auth/login` | `{ "email", "password" }` | `200 { user, session }` | `401` bad_credentials, `423` locked (5 failures lock 15 minutes), `429` rate_limited (10 per IP+email, 60 per IP, per 15 minutes) |
| `POST /auth/refresh` | `{ "refreshToken" }` | `200 { user, session }` (the old refresh token is consumed; a replay gets 401) | `401` session_invalid |
| `POST /auth/logout` | `{ "refreshToken" }?` + session header | `200 { "ok": true }` | none (idempotent) |
| `GET /auth/me` | session header | `200 { user }` | `401` session_required / session_invalid |
| `POST /auth/delete-account` | `{ "password" }` + session header | `200 { "deleted": true }`: user row and every session deleted | `401` bad_credentials / session_invalid, `429` |

`user` is `{ id, email, fullName, npi, createdAt }`. `session` is `{ accessToken (12 h), refreshToken (30 days), expiresAt, refreshExpiresAt }`. Passwords: chained PBKDF2-HMAC-SHA256, 6 x 100,000 iterations, per-user salt. Only SHA-256 hashes of tokens are stored. D1 tables come from `migrations/0001_solis_app_users.sql` in the Worker repo (`npx wrangler d1 migrations apply healthcare_rcm_d1 --remote`).

The app keeps the session in the Android Keystore / iOS Keychain (`flutter_secure_storage`), refreshes it when it expires, and retries a cloud call once after a `session_invalid`. Offline, a clinician who signed in before can still open the app; cloud features say they need a connection. "Use demo account" is local only and never calls the server.

## Play Integrity

Sign-in and sign-up carry a Play Integrity (Standard API) token when the build has a Google Cloud project number. The app sends `X-Solis-Integrity` (token) and `X-Solis-Integrity-Nonce` (random, single use); the token's request hash is hex SHA-256 of `nonce|request path`. No email, password or patient data is hashed.

The Worker decodes the token with `playintegrity.googleapis.com/v1/<package>:decodeIntegrityToken` using the service account, and checks package name, request hash, age (5 minutes), `PLAY_RECOGNIZED`, `MEETS_DEVICE_INTEGRITY` and, if set, the signing certificate. Modes (`GET /api/v2/health` shows `playIntegrity`):

- `off` (no service account): never blocks; each skipped check is counted per day in KV (`INTEG:skipped:<date>`) and logged with the count.
- `report-only` (service account set): failures are counted (`INTEG:<reason>:<date>`) and logged, nothing is blocked. Use this while the APK is sideloaded: a sideloaded build is never `PLAY_RECOGNIZED`.
- `enforced` (`SOLIS_INTEGRITY_ENFORCE=true`): a missing or failing token gets `403 integrity_failed`. Turn on only after the Play Store build is the one clinicians use.
- If Google cannot be reached the check fails open (counted as `unavailable`).

To turn it on: in Google Cloud, enable the Play Integrity API on a project, link it in Play Console (App integrity), create a service account with no roles and download its JSON key; save it in the key vault as `GOOGLE_PLAY_INTEGRITY_SA_JSON`; add `SOLIS_GCP_PROJECT_NUMBER` to `keys.local.json`; rebuild.

## TLS pinning

The app trusts only the public root CAs Cloudflare issues from (Google Trust Services R1 to R4, Let's Encrypt ISRG X1 and X2, SSL.com, Sectigo, USERTrust, plus GlobalSign Root CA for the GTS R4 cross-sign) when it talks to the Worker host, instead of every root on the phone. A user-installed proxy root or a certificate from any other CA is refused, with the message "The connection to the SOLIS server could not be verified".

Trade-off: pinning the leaf or the intermediates would be stronger against a mis-issuing pinned CA, but Cloudflare rotates both every few months, so every installed copy would lose the server at the next rotation. Root pins survive rotations; all pinned roots are valid until 2028 or later, most into the 2040s.

Update path: `pwsh -File tool\make_tls_pins.ps1` regenerates `lib/services/net/pinned_roots.dart` from the local JDK and Windows trust stores (nothing downloaded). Re-run it when Cloudflare adds a CA and ship the update well before the new CA is used. Pins stop being enforced after `PinnedHttp.enforcedUntil` (2028-06-01), so an install that is never updated falls back to normal trust rather than breaking; a test fails when that date is less than a year away, as a reminder to move it forward. `--dart-define=SOLIS_TLS_PINNING=off` disables pinning for a debugging proxy (never for a release). Deepgram, NPPES and model downloads use normal trust.

## Release build

```powershell
pwsh -File tool\build_release.ps1            # APK + AAB
pwsh -File tool\build_release.ps1 -SkipAab   # APK only
```

The script reads `SOLIS_APP_TOKEN` (and `SOLIS_GCP_PROJECT_NUMBER` if present) from `secrets\keys.local.json` into a temporary `--dart-define-from-file` JSON on `D:\temp` (deleted afterwards; values never printed or put on a command line), builds with `--obfuscate --split-debug-info=D:\SOLIS-symbols\<version>`, verifies the APK with `apksigner verify --print-certs` (v2 scheme, not the debug key) and the AAB with `jarsigner -verify`, and copies `solis-<version>.apk` / `.aab` to `D:\Downloads` and `C:\Users\varsh\Downloads` with their SHA-256. Keep `D:\SOLIS-symbols\<version>`: `flutter symbolize -i <stack trace> -d D:\SOLIS-symbols\<version>\app.android-arm64.symbols` needs it to read crash reports. R8 minification and resource shrinking stay on for release (`android/app/build.gradle.kts`).

The obfuscation hides names, not secrets: anything compiled into the app (the app token included) can still be extracted, which is why vendor keys live only on the Worker.
