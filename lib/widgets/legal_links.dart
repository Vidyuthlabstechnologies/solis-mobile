import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';

/// Opens [url] in the browser; shows a message when nothing can open it.
Future<void> openExternal(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  bool ok;
  try {
    ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    ok = false;
  }
  if (!ok) messenger?.showSnackBar(SnackBar(content: Text('Could not open $url')));
}

/// "Privacy policy · Terms of use", for sign-in, the paywall and settings.
class LegalLinks extends StatelessWidget {
  const LegalLinks({super.key});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton(
          key: const Key('link_privacy'),
          onPressed: () => openExternal(context, AppConfig.privacyPolicyUrl),
          child: Text('Privacy policy', style: style),
        ),
        Text('·', style: style),
        TextButton(
          key: const Key('link_terms'),
          onPressed: () => openExternal(context, AppConfig.termsUrl),
          child: Text('Terms of use', style: style),
        ),
      ],
    );
  }
}
