import 'package:flutter/material.dart';

import 'solis_brand.dart';

const solisDisclaimer = 'SOLIS helps clinicians document and bill. It is not a medical device and does not diagnose or treat. '
    'The clinician reviews and signs every note.';

/// The app version shown in About. Must match `version:` in pubspec.yaml
/// (test/version_test.dart fails the build when it does not).
const solisVersion = '1.0.2';

/// The one-line medical disclaimer, shown on sign-in and in About.
class MedicalDisclaimer extends StatelessWidget {
  final TextAlign textAlign;
  const MedicalDisclaimer({super.key, this.textAlign = TextAlign.start});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 16, color: cs.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            solisDisclaimer,
            textAlign: textAlign,
            style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// About SOLIS: version, disclaimer and open-source licenses.
void showSolisAbout(BuildContext context) {
  showAboutDialog(
    context: context,
    applicationName: 'SOLIS',
    applicationVersion: solisVersion,
    applicationIcon: const SolisBrandMark(size: 40),
    children: const [
      SizedBox(height: 8),
      MedicalDisclaimer(),
    ],
  );
}
