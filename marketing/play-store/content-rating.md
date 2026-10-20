# SOLIS: Content rating (IARC questionnaire)

Play Console > Policy > App content > Content rating > Start new questionnaire.

## Step 1: Email and category

| Field | Answer |
| --- | --- |
| Email address (IARC writes to it; not public) | `[FOUNDER: email]` |
| Category | **All Other App Types** (the non-game category; in some Console versions it is labelled "Utility, Productivity, Communication, or Other"). Not "Reference, News, or Educational" and not "Social". |
| Does the app access, display or link to news? | No |

## Step 2: Questions

Answer **No** to every content question:

| Topic | Answer | Note |
| --- | --- | --- |
| Violence (realistic, fantasy, blood, gore) | No | |
| Fear / horror content | No | |
| Sexuality, nudity | No | |
| Crude humor / offensive language | No | |
| Controlled substances (drugs, alcohol, tobacco): does the app reference or depict them? | No | Prescriptions appear only as clinical orders a licensed clinician dictated. IARC asks about depiction or promotion of drug, alcohol or tobacco use; that is not this. If the reviewer reads it differently, "references only, in a medical context" still yields the lowest rating. |
| Gambling, simulated gambling | No | |
| Hate speech, discrimination | No | |

Miscellaneous (non-game) questions:

| Question | Answer | Why |
| --- | --- | --- |
| Can users interact or exchange content with other users? | No | Each clinician's account is separate; there is no chat, feed or sharing between users. |
| Does the app share the user's current physical location with other users? | No | The visit address is stored on the phone with the visit record. |
| Does the app allow users to purchase digital goods? | No | No in-app purchases in v1.0.0. Change this if subscriptions are added in the app. |
| Does the app contain a web browser or a search engine with unrestricted internet access? | No | |
| Is the app a Web browser or search engine? | No | |
| Does the app contain any of the content above in user-generated content? | No | |

## Expected result

Everyone / ESRB Everyone, PEGI 3, USK 0, IARC 3+ (exact labels depend on region). The store audience is still
adults only because of the Target audience setting (see `target-audience.md`); the content rating describes content,
not the intended user.

Retake the questionnaire if you add in-app purchases, messaging between users, or any feature that shows a user's
location to other users.

Source: [Content rating questionnaire](https://support.google.com/googleplay/android-developer/answer/9859655),
[Content ratings](https://support.google.com/googleplay/android-developer/answer/9898843).
