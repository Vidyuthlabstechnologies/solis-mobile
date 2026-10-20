# SOLIS: Health apps declaration and permission declarations

## 1. Health apps declaration

Play Console > Policy > App content > Health apps > Start. Every app must complete this form (even with no health
features); Google reviews it with the release.

### Page 1: select the health features

Tick **only**:

- Medical > **Healthcare Services and Management**

Leave unticked (and why):

| Option | Why not |
| --- | --- |
| Medical Device Apps | SOLIS is not a medical device. Documentation and billing software falls under the FD&C Act section 520(o)(1)(A)/(E) exclusions; it does not diagnose, recommend treatment or generate findings (see `docs/LAUNCH_COMPLIANCE.md` section 3). |
| Clinical Decision Support | SOLIS codes only what the clinician said and asks the clinician to confirm uncertain diagnoses. Coding and claim checks are administrative, not clinical recommendations. |
| Diseases and Conditions Management, Medication and Treatment Management | No patient-facing disease or medication management. Orders are listed for the clinician to review; nothing is sent to a pharmacy or lab. |
| Medical Reference and Education | The "Why" sheets cite coding guidelines, but that supports billing, not medical education. If a reviewer pushes back, adding this option is harmless. |
| Health subjects research, Emergency and First Aid, Mental and Behavioral Health, Reproductive and Sexual Health, Physical Therapy, Disease Prevention and Public Health | Not applicable. |
| All "Health and fitness" options | Not applicable. |
| "My app doesn't provide any health features" | Wrong: SOLIS is a medical app. |

### Page 2: additional questions

The second page only shows expandable questions for some features (for example medical devices in the EEA, or
government-affiliated health apps). For Healthcare Services and Management alone, expect none or a short
confirmation. If asked:

- Is the app regulated as a medical device in any country? **No.**
- Is the app affiliated with a government or public health authority? **No.**
- Is the app used in human subjects research? **No.**

### Description and disclaimer (use the same words everywhere)

Feature summary, if a free-text box appears:

> SOLIS is a clinical documentation and billing tool for licensed US clinicians. With patient consent it records the
> visit, drafts a SOAP note for the clinician to review and sign, suggests ICD-10-CM and procedure codes from what was
> said, checks the claim against official CMS code sets, and sends eligibility checks and claims through a
> clearinghouse. It is used by clinicians and practice staff, not by patients.

Disclaimer (already in the app on sign-in, sign-up and About; also in the store description):

> SOLIS helps clinicians document and bill. It is not a medical device and does not diagnose or treat. The clinician
> reviews and signs every note.

### Account type requirement

Google lists health apps (medical apps) among the services that **should be published from an organization
developer account** (verified with a D-U-N-S number). See `release-checklist.md` step 0.

## 2. Foreground service permission: microphone

Play Console > Policy > App content > Foreground service permissions. Play shows this form because the manifest
declares `android.permission.FOREGROUND_SERVICE_MICROPHONE`.

**Status (re-checked 2026-10-21).** The 1.0.0 build declared these permissions without a matching service. Since
1.0.1 the app has option A: `RecordingService` (`android/app/src/main/kotlin/.../RecordingService.kt`), a
non-exported `<service>` with `android:foregroundServiceType="microphone"` and an ongoing notification with Stop.
The current upload candidate `D:\Downloads\solis-1.0.2.aab` contains it. Fill the form below.

Form answers (option A):

| Field | Answer |
| --- | --- |
| Foreground service type | Microphone |
| Use case | **Background audio access / voice recording** (the use case closest to "records audio the user started") |
| App functionality description | SOLIS records a clinical visit that the clinician starts, with patient consent. Before recording, the patient hears a consent script and agrees out loud or signs on the phone. The clinician taps "Patient agreed, start recording"; a notification shows while recording. The recording continues if the screen turns off or the clinician switches apps during the visit, and stops when the clinician taps Finish, Pause or Discard. The audio is used only to write the visit note. |
| User impact if deferred | The start of the visit would not be recorded, so the note would be missing what the patient said first. The clinician cannot repeat the conversation. |
| User impact if interrupted | Part of the visit would be lost and the note would be incomplete or wrong. The clinician would have to write that part from memory. |
| Video link | `[FOUNDER: unlisted YouTube or Drive link]` |

Video to record (under 60 seconds, screen recording on a phone): open SOLIS > Use demo account > open a patient >
Start today's visit > the consent sheet > Patient agreed, start recording > the recording notification appears >
press Home (recording continues, notification visible) > reopen > Finish and write note.

## 3. Location permission

The app requests `ACCESS_FINE_LOCATION` and `ACCESS_COARSE_LOCATION` only, in the foreground, and targets SDK 36.
**No location declaration form is required** (the Play form is only for `ACCESS_BACKGROUND_LOCATION`). Do not add
background location.

If Play or a reviewer asks why location is used, the wording is:

> SOLIS stamps the visit record with the visit address. When the clinician starts a visit or records patient consent,
> the app reads the phone's location once, in the foreground, and saves the street address with the visit and the
> consent record. If location is not available, the visit is saved without an address rather than with a guessed one.
> Location stays on the phone.

## 4. Other permissions (no declaration needed)

| Permission | Used for |
| --- | --- |
| `RECORD_AUDIO` | Recording the visit after consent (runtime prompt) |
| `POST_NOTIFICATIONS` | Recording and status notifications |
| `WAKE_LOCK` | Keeps the phone awake during a recorded visit |
| `INTERNET`, `ACCESS_NETWORK_STATE` | SOLIS server, cloud transcription, clearinghouse, model download |

No camera permission: card scanning uses the Google ML Kit document scanner and the system photo picker.

Sources: [Health apps declaration](https://support.google.com/googleplay/android-developer/answer/14738291),
[Foreground service requirements](https://support.google.com/googleplay/android-developer/answer/13392821),
[Location permissions](https://support.google.com/googleplay/android-developer/answer/9799150),
[Account types](https://support.google.com/googleplay/android-developer/answer/13634885).
