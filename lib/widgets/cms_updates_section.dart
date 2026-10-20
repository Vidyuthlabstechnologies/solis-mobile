import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../services/codesets/cms_transmittals.dart';
import '../services/security_and_background_service.dart';

/// "Recent CMS updates" inside the Code sets card: the newest CMS
/// transmittals that change claims (EDI front-end edits, HCPCS, fee schedule,
/// NCCI, ICD-10 and so on), from the code-set monitor. Collapsed until opened,
/// so the Integrations screen makes no network call by itself. Each row opens
/// the CMS page.
class CmsUpdatesSection extends StatefulWidget {
  const CmsUpdatesSection({super.key, this.client, this.openUrl, this.limit = 5, this.initiallyExpanded = false});

  /// Defaults to [CmsTransmittalsClient.instance].
  final CmsTransmittalsClient? client;

  /// Opens a CMS page; returns false when it could not. Defaults to the
  /// platform browser.
  final Future<bool> Function(String url)? openUrl;

  final int limit;
  final bool initiallyExpanded;

  @override
  State<CmsUpdatesSection> createState() => _CmsUpdatesSectionState();
}

class _CmsUpdatesSectionState extends State<CmsUpdatesSection> {
  late bool _open = widget.initiallyExpanded;
  bool _loading = false;
  bool _failed = false;
  List<CmsTransmittal>? _items;

  CmsTransmittalsClient get _client => widget.client ?? CmsTransmittalsClient.instance;

  @override
  void initState() {
    super.initState();
    if (_open) _load();
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final items = await _client.recent(limit: widget.limit, refresh: refresh);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  void _toggle() {
    setState(() => _open = !_open);
    if (_open && _items == null && !_loading) _load();
  }

  Future<void> _openPage(CmsTransmittal t) async {
    final open = widget.openUrl ?? SecurityAndBackgroundService.openUrl;
    final ok = await open(t.url);
    if (ok || !mounted) return;
    await Clipboard.setData(ClipboardData(text: t.url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open the browser. Link to ${t.id} copied.')));
  }

  static String subtitle(CmsTransmittal t) {
    final date = DateFormat.yMMMd();
    return [
      t.cr == null ? t.id : 'CR ${t.cr}, ${t.id}',
      if (t.implementationDate != null) 'implementation ${date.format(t.implementationDate!)}',
    ].join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final items = _items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextButton.icon(
          key: const Key('cms_updates_toggle'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48), alignment: Alignment.centerLeft, padding: const EdgeInsets.only(right: 8)),
          onPressed: _toggle,
          icon: Icon(_open ? Icons.expand_less_rounded : Icons.campaign_outlined),
          label: Text(_open ? 'Hide recent CMS updates' : 'Recent CMS updates'),
        ),
        if (_open) ...[
          if (_loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Loading CMS updates', style: muted)),
                ],
              ),
            )
          else if (_failed)
            Row(
              children: [
                Icon(Icons.cloud_off_rounded, size: 18, color: cs.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(child: Text('CMS updates could not be loaded.', style: muted)),
                TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => _load(refresh: true),
                  child: const Text('Retry'),
                ),
              ],
            )
          else if (items != null && items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('No recent CMS changes that affect claims.', style: muted),
            )
          else if (items != null) ...[
            Text('CMS transmittals that change claims, newest first. Tap one to open it on cms.gov.', style: muted),
            const SizedBox(height: 4),
            for (final t in items)
              InkWell(
                key: Key('cms_update_${t.id}'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => _openPage(t),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                              const SizedBox(height: 2),
                              Text(subtitle(t), style: muted),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.open_in_new_rounded, size: 18, color: cs.primary, semanticLabel: 'Open on cms.gov'),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ],
      ],
    );
  }
}
