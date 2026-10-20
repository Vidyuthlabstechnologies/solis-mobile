# SOLIS mobile design brief

How the app is designed and why. Based on published clinician research on ambient AI scribes and on how the established products (Abridge, DAX Copilot / Dragon Copilot, Commure) structure their mobile workflows.

## What physicians need from a scribe on a phone

1. **Capture is the phone's job; review must be fast.** Abridge records on the phone and reviews on a larger screen. DAX recommends the mobile app as the primary recorder. So the recording screen gets one dominant action and nothing else competing for attention.
2. **Editing burden is the top complaint.** In a JAMA Network Open qualitative study of 22 physicians, views on accuracy and style were largely negative because of note length and editing work. The review screen therefore puts each section in its own card with one-tap edit, and nothing else in the way.
3. **Trust comes from traceability.** Abridge's core verification feature is "Linked Evidence": select note text and see the transcript passage behind it. SOLIS shows a Sources action on every note section that ranks the transcript turns supporting it.
4. **Consent before recording.** Vendors and compliance guidance converge on a just-in-time verbal notice, documented in the record. All-party consent states make this a legal requirement in some places. SOLIS asks before the first recording of every visit and archives the consent timestamp with the note.
5. **Pause and resume.** Dragon Copilot guidance calls out stopping for sensitive topics or when the clinician steps out. Commure adds haptic feedback on pause, save and delete. SOLIS has a dedicated pause control and haptics on start, pause, stop and sign.
6. **Alert fatigue.** Interruptive-alert research (Applied Clinical Informatics 2025, JAMIA) says to reserve visual alarm for situations that need action. The old status strip showed six always-on colored badges. It is now one quiet line, with color only when something is actually wrong (for example, screen protection off).

## Rules the UI follows

- **One accent color.** Clinical blue for actions. Red and amber only carry meaning: recording, abnormal vitals, STAT or urgent orders, destructive actions.
- **Readable at arm's length.** Body text 16sp in the note, never below 14sp anywhere; labels at least 12sp.
- **Touch targets at least 48dp**; the record button is 96dp so it can be hit while facing the patient.
- **Never color alone.** Every status pairs an icon with a word (Recording, Paused, STAT, Abnormal).
- **No emoji, no bullet glyphs, no decorative dots.** Material icons only.
- **No fabricated numbers.** The UI never shows a metric the system did not compute from the visit. The engine records only vitals that were actually stated.
- **Destructive and irreversible steps confirm first**: discard, sign, send orders. Removing a code offers Undo instead.

## Screen states

| Phase | Primary action | Secondary |
| --- | --- | --- |
| Ready | Record (after consent) | Type instead, Sample visits |
| Recording | Finish and write note | Pause / resume, Discard |
| Generating | none (progress) | |
| Review: Note | Sign note | Add recording, Sources, Edit, Copy |
| Review: Orders | Send N orders | Check or uncheck individual orders |

Session details (engine, noise filter, language, GPS, UTC time, consent, screen protection, background capture) sit behind the one-line status strip under the app bar.

## Verifying the design

```
flutter test screenshots/screenshot_test.dart --update-goldens
```

renders every main state to `screenshots/out/` with the real Roboto and Material Icons fonts, at 412dp and 320dp, light and dark.

## Sources

- [Physician Perspectives on Ambient AI Scribes, JAMA Network Open](https://jamanetwork.com/journals/jamanetworkopen/fullarticle/2831866)
- [Clinicians' Rationale for Editing Ambient AI-Drafted Clinical Notes, medRxiv 2026](https://www.medrxiv.org/content/10.64898/2026.02.20.26346729v1.full)
- [Evaluation of an Ambient AI Documentation Platform for Clinicians, JAMA Network Open](https://jamanetwork.com/journals/jamanetworkopen/fullarticle/2833433)
- [Ambient AI Scribes in Clinical Practice: A Randomized Trial](https://pmc.ncbi.nlm.nih.gov/articles/PMC12768499/)
- [Abridge: Get started with ambient note taking](https://support.abridge.com/hc/en-us/articles/30287281533715-Get-Started-using-Abridge-Ambient-Note-taking)
- [Abridge Ambient AI, OU Health IT guide (Linked Evidence)](https://itsupport.ou.edu/TDClient/33/Tulsa/KB/Article/3577/Abridge-Ambient-AI?SIDs=4285)
- [DAX Copilot mobile app overview, Microsoft](https://support.microsoft.com/en-us/dax-copilot/dax-copilot-mobile-app-overview)
- [Dragon Copilot: record your first patient session, Microsoft](https://support.microsoft.com/en-us/dragon-copilot/physicians/record-your-first-patient-session)
- [Commure: recording a scribe (Android)](https://docs.pro.commure.com/android/ambient_ai_scribe/recording-a-scribe)
- [Patient consent for ambient listening technology, Insight Health](https://help.insighthealth.ai/en/articles/13912547-patient-consent-for-ambient-listening-technology)
- [Interruptive alert style guide, Applied Clinical Informatics 2025](https://thieme-connect.de/products/ejournals/abstract/10.1055/a-2508-7039)
- [Physician Perspectives on Ambient AI Scribes, PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC11933996/)
