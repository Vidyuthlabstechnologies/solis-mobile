# Standalone build (no Google Play)

SOLIS ships as two Android builds from the same code:

| | `play` | `standalone` |
| --- | --- | --- |
| Installed from | Google Play | The website (`solis-health.pages.dev`, APK on R2) or handed to a clinic |
| SOLIS Pro / paywall | Yes, Google Play Billing via RevenueCat | No. Everything is unlocked |
| `com.android.vending.BILLING` permission | Yes | Removed (`android/app/src/standalone/AndroidManifest.xml`) |
| Play Integrity at sign-in | Yes, when `SOLIS_GCP_PROJECT_NUMBER` is set | Not included (stub plugin in `android/app/src/standalone/`) |
| Updates | Google Play | Install the newer APK over it (same signing key) |
| Version shown in About | `1.0.2` | `1.0.2 (standalone)` |

Everything else is the same and works end to end: demo account, sign-up and sign-in with the SOLIS server, on-device
and cloud notes, card scanning, coding checks, eligibility and claims through the server, code-set updates, account
deletion, privacy and terms links.

Both builds use the application ID `com.solis.clinical.solis_mobile`, so a phone has one or the other. Moving between
them means uninstalling first (Google Play re-signs Play builds with its own key, so Android won't update one with
the other). Patient data is on the phone, so export what you need before switching.

## Build it

```
flutter build apk --release --flavor standalone
```

`flutter run` and `flutter build` without `--flavor` use `play` (`default-flavor` in `pubspec.yaml`). Without
`android/key.properties` the APK is signed with the debug key: fine for testing, not for handing out.

The signed standalone APK comes from GitHub: Actions > **Release (Play bundle)** > Run workflow. The artifact has
`app-standalone-release.apk`, signed with the upload key. If the APK already on the website was signed with that
key too (it was, if it was built with `android/key.properties`), existing website installs update in place. Its SHA-256 is in the run summary. To publish it on the site, upload it to R2 and update
`marketing/site/tools/apk.json` (version, sha256, url, bytes) before building the site.

The **Android builds** workflow builds both on every pull request that touches the app and fails if the standalone
APK has the BILLING permission or the Play Integrity library.

## One server setting to watch

The Worker checks Play Integrity in report-only mode by default. If `SOLIS_INTEGRITY_ENFORCE=true` is ever turned
on, standalone builds can no longer sign in (they send no integrity token). Keep enforcement off while the standalone
build is in use, or add an exception for it on the server first.

## What the standalone build still contains

The RevenueCat Flutter plugin is part of `pubspec.yaml`, so its code is in both APKs. In the standalone build it is
never started (no key, and `AppConfig.isStandalone` turns subscriptions off) and it cannot bill, because the
permission is removed. Removing the library entirely would need a second app package; ask if that matters.
