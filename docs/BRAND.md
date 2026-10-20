# SOLIS brand

The identity in one line: **SOLIS Orchid** and the **Split Sun**.

Everything here is generated from one script, `tool/make_brand_assets.py`, and drawn at runtime by `SolisBrandMark` in `lib/widgets/solis_brand.dart`. Change the geometry or color in both places together.

## Why a new color

The old accent, `#0F52BA`, is a generic clinical blue. It sat next to Doximity, Microsoft, most EHR portals, and our own `info` status blue, so it was not recognizable and it blurred an action with a status.

What the ambient scribe and EHR brands near us use (sampled from their public sites and brand guides, October 2026):

| Company | Main brand color | Hue family |
| --- | --- | --- |
| Epic | `#CD1543` crimson, warm greys | red |
| Abridge | `#141312` near-black, `#EEE5DD` cream, `#EA2C00` red-orange | neutral, red-orange |
| Suki | `#1B1B1B` black, `#FFE148` yellow | neutral, yellow |
| Freed | `#6A3CDF` / `#4D2BA1` violet, `#0A204F` navy | violet, navy |
| athenahealth | `#4E2D82` Hero purple, `#F3A61C` honey | purple, gold |
| Doximity | `#00538A` blue | blue |
| Microsoft Dragon Copilot (Nuance) | `#0078D4` Microsoft blue | blue |

Our own UI also reserves hues for meaning: red (recording, abnormal, STAT, destructive), amber (warning), green (success), teal (patient speaker, signed) and blue (info). Put the competitors and our semantic colors on a hue wheel and one region is empty: magenta-orchid, between purple (Freed, athenahealth, around 260 degrees) and red (Epic, our danger color, 0 degrees). That is where SOLIS sits.

Why it holds up in a clinic:

- It cannot be mistaken for a status. It is not red, amber, green, teal or blue, so an orchid button never reads as "abnormal" or "done".
- It survives color-vision deficiency. Under deuteranopia and protanopia, orchid shifts toward blue while our danger red shifts toward brown-olive, so the brand and the alarm stay apart. Status still never relies on color alone (icon plus word), per `docs/DESIGN.md`.
- It is warm enough for a sun brand without borrowing the reserved amber.
- It is owned: no scribe, EHR or physician network in the table above uses it.

## SOLIS Orchid

| Role | Name in code | Hex | RGB | HSL |
| --- | --- | --- | --- | --- |
| **Brand (light primary, logo tile)** | `SolisTheme.brand` / `orchid40` | `#980F86` | 152, 15, 134 | 308, 82%, 33% |
| Dark-mode primary | `SolisTheme.brandDark` / `orchid80` | `#E5A3E8` | 229, 163, 232 | 297, 60%, 77% |
| Deep (text on containers, dark onPrimary, night splash) | `SolisTheme.brandDeep` / `orchid20` | `#4E0044` | 78, 0, 68 | 308, 100%, 15% |
| Light container | `SolisTheme.brandContainer` / `orchid95` | `#FDE2F6` | 253, 226, 246 | 316, 87%, 94% |
| Dark container | `SolisTheme.brandContainerDark` / `orchid30` | `#6F0061` | 111, 0, 97 | 308, 100%, 22% |
| Text on dark container | `SolisTheme.brandContainerText` / `orchid90` | `#F1CAF3` | 241, 202, 243 | 297, 63%, 87% |

`SolisTheme.primaryBlue` is kept for older call sites and now equals `brand`.

### Tonal ramp

Built in OKLCH at hue 335 so each step is perceptually even; tones 70 to 90 lean to hue 325 so the dark-mode accent stays clear of the salmon dark-mode danger color (`#FF8A80`).

| Tone | Hex | Tone | Hex |
| --- | --- | --- | --- |
| 10 | `#2F0029` | 60 | `#CA58B5` |
| 20 | `#4E0044` | 70 | `#D180D6` |
| 30 | `#6F0061` | 80 | `#E5A3E8` |
| 40 | `#980F86` | 90 | `#F1CAF3` |
| 50 | `#B435A0` | 95 | `#FDE2F6` |
| | | 99 | `#FFF8FD` |

### Contrast (WCAG 2.x)

| Pair | Ratio | Result |
| --- | --- | --- |
| Brand `#980F86` text on white | 7.64:1 | AAA |
| White text on brand `#980F86` | 7.64:1 | AAA |
| Brand on app background `#F8FAFC` | 7.30:1 | AAA |
| Brand on surface container `#F1F5F9` | 6.98:1 | AA |
| Brand on dark snackbar `#E6E9EF` | 6.28:1 | AA |
| brandDeep on brandContainer | 12.35:1 | AAA |
| brandDark `#E5A3E8` on dark background `#0B0E14` | 9.88:1 | AAA |
| brandDark on dark surface `#12161F` | 9.25:1 | AAA |
| brandDark on dark surface high `#1A1F2B` | 8.42:1 | AAA |
| brandDark on highest dark container `#2A3142` | 6.64:1 | AA |
| brandDeep text on brandDark (dark-mode filled button) | 7.63:1 | AAA |
| brandContainerText on brandContainerDark | 7.83:1 | AAA |
| brandDark on light snackbar `#0F172A` | 9.13:1 | AAA |
| White mark on night splash `#4E0044` | 14.92:1 | AAA |

The dark-mode pair carries the same promise as the light pair: the accent on every dark surface, and text on a filled accent, both clear 4.5:1 with room to spare.

### Rules

- One accent. Orchid is for actions, focus, selection and the brand. It never marks a state.
- Red, amber, green, teal and blue stay semantic and are never used for branding.
- The logo tile is always `#980F86` with a white mark, in both themes.
- Do not tint photos or large backgrounds with orchid. Large fills use `brandContainer` (light) or `brandContainerDark` (dark).

## The mark: Split Sun

One sun disc, cut along the horizon. The upper half (the dome) stays where it rose and moves right; the lower half (the bowl) moves left by the same amount. A thin gap of sky separates them.

- **As a picture** it is a sunrise and its reflection: SOLIS is Latin for "of the sun".
- **As a letter** the offset halves form an S.
- **As the product**: the top half is what was said in the room, the bottom half is what was written down (the note and the claim). It is the same disc, shifted, with nothing added. That is the promise of a scribe that never invents.

Geometry (fractions of the tile side, tile is 1 x 1):

| Part | Value |
| --- | --- |
| Tile corner radius | 0.23 |
| Sun radius | 0.23 |
| Horizontal slide of each half | 0.08 (dome right, bowl left) |
| Vertical gap from horizon, each half | 0.025 (total gap 0.05) |
| Dome center | (0.58, 0.475), upper half |
| Bowl center | (0.42, 0.525), lower half |

Two filled half-discs: no strokes, no thin lines, so it stays legible at 24 px (the gap is still one pixel at 24 px). The mark fits inside the Android adaptive-icon safe zone with margin (mark radius 22.6 dp of the 33 dp safe radius).

### Wordmark

The letters S O L I S are drawn from the same circles and bars as the mark (stroke 0.18 of cap height, cap height 0.40 of the tile, tracking 0.16). The S uses the same slide ratio as the mark, so the logo and the first letter rhyme. No font is used, so the wordmark carries no third-party license. Text color is `#0F172A` on light backgrounds and white on dark.

## Files

| Path | What |
| --- | --- |
| `assets/brand/solis_mark.svg` | Master mark on its tile |
| `assets/brand/solis_glyph.svg` | Mark alone, `currentColor`, for one-color use |
| `assets/brand/solis_wordmark.svg`, `solis_wordmark_dark.svg` | Lockup for light and dark backgrounds |
| `assets/brand/solis_mark_{48,96,192,512,1024}.png` | Tile exports |
| `assets/brand/solis_playstore_512.png` | Full-bleed store icon (the store applies its own mask) |
| `assets/brand/solis_glyph_orchid_1024.png`, `solis_glyph_ink_1024.png` | One-color mark on transparency |
| `assets/brand/solis_wordmark*.png` | Lockup exports, transparent and on white or dark |
| `android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml` | Adaptive icon: background color, vector foreground, monochrome layer for Android 13 themed icons |
| `android/app/src/main/res/drawable/ic_launcher_foreground.xml`, `ic_launcher_monochrome.xml` | Vector layers |
| `android/app/src/main/res/mipmap-*/ic_launcher.png` | Legacy icons, mdpi to xxxhdpi |
| `android/app/src/main/res/drawable*/launch_background.xml`, `drawable-*dpi/launch_mark.png` | Launch screen before Android 12 |
| `android/app/src/main/res/values-v31/styles.xml`, `values-night-v31/styles.xml` | Android 12+ system splash (`windowSplashScreenBackground`, `windowSplashScreenAnimatedIcon`) |
| `android/app/src/main/res/values/colors.xml`, `values-night/colors.xml` | Brand and splash colors (deep orchid at night) |

Regenerate everything with:

```
python tool/make_brand_assets.py
```

## Sources

- [athenahealth brand guidelines: color](https://brand.athenahealth.com/guidelines/color)
- [Epic logo color, logotyp.us](https://logotyp.us/logo/epic/)
- Public home pages of abridge.com, suki.ai, getfreed.ai, doximity.com and epic.com, sampled for their most used hex values
- [WCAG 2.2 contrast minimum, W3C](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)
- [Android adaptive icons](https://developer.android.com/develop/ui/views/launch/icon_design_adaptive)
- [Android splash screens](https://developer.android.com/develop/ui/views/launch/splash-screen)
