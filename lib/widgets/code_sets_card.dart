import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/codesets/code_set_loader.dart';
import '../services/codesets/codeset_update_client.dart';
import '../services/codesets/codeset_updates.dart';
import '../theme/solis_theme.dart';
import 'cms_updates_section.dart';
import 'encounter_widgets.dart';

/// Which official code sets (ICD-10-CM, HCPCS, PFS, NCCI, MCE) this run uses,
/// when SOLIS last looked for a signed update, and the two manual controls:
/// check now, and go back to the sets built into the app.
class CodeSetsCard extends StatefulWidget {
  const CodeSetsCard({super.key, this.updates, this.cmsUpdates});

  /// Defaults to [CodesetUpdates.instance].
  final CodesetUpdates? updates;

  /// The "Recent CMS updates" list; defaults to one reading the code-set
  /// monitor. Tests pass their own.
  final CmsUpdatesSection? cmsUpdates;

  @override
  State<CodeSetsCard> createState() => _CodeSetsCardState();
}

class _CodeSetsCardState extends State<CodeSetsCard> {
  CodesetUpdates? get _u => widget.updates ?? CodesetUpdates.instance;
  CodesetStatus? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _u?.changes.addListener(_refresh);
    _refresh();
  }

  @override
  void dispose() {
    _u?.changes.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _refresh() async {
    final u = _u;
    if (u == null) return;
    final s = await u.status();
    if (mounted) setState(() => _status = s);
  }

  Future<void> _checkNow() async {
    final u = _u;
    if (u == null) return;
    setState(() => _busy = true);
    final r = await u.check(force: true);
    await _refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_resultText(r))));
  }

  Future<void> _useBuiltIn() async {
    final u = _u;
    if (u == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use built-in code sets?'),
        content: const Text(
          'SOLIS removes the downloaded code sets and goes back to the ones that came with the app. '
          'A newer published release is still installed when it appears.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Use built-in')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    await u.useBuiltIn();
    await _refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Using the built-in code sets.')));
  }

  static String _resultText(CodesetUpdateResult r) {
    switch (r.status) {
      case CodesetUpdateStatus.updated:
        return 'Code sets ${r.serial} downloaded. They are used when SOLIS next starts.';
      case CodesetUpdateStatus.upToDate:
        return 'Code sets are up to date.';
      case CodesetUpdateStatus.throttled:
        return 'Checked recently. Try again later.';
      case CodesetUpdateStatus.incompatible:
        return 'A newer code-set format needs an app update. Current sets stay in use.';
      case CodesetUpdateStatus.failed:
        return 'Could not check for code sets. Current sets stay in use.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final u = _u;
    final s = _status;
    final muted = theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant);
    final when = DateFormat.yMMMd().add_jm();

    final Widget tag;
    if (u == null) {
      tag = StatusTag(label: 'Built-in', color: cs.onSurfaceVariant, icon: Icons.inventory_2_outlined);
    } else if (s == null) {
      tag = StatusTag(label: 'Checking', color: cs.onSurfaceVariant, icon: Icons.hourglass_empty_rounded);
    } else if (s.usingBundled) {
      tag = StatusTag(label: 'Built-in', color: cs.onSurfaceVariant, icon: Icons.inventory_2_outlined);
    } else {
      tag = const StatusTag(label: 'Updated', color: SolisTheme.success, icon: Icons.verified_outlined);
    }

    final editions = IcdEditions.available.map((fy) => 'FY$fy').join(', ');
    final rows = <Widget>[];
    void line(String label, String value) {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 104, child: Text(label, style: muted)),
            Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
          ],
        ),
      ));
    }

    if (u == null) {
      line('In use', 'Built-in sets, release $bundledCodesetSerial');
      line('ICD-10-CM', editions);
      line('Updates', 'Not available on this device');
    } else if (s != null) {
      line('In use', s.usingBundled ? 'Built-in sets, release ${s.activeSerial}' : 'Downloaded release ${s.activeSerial}');
      line('ICD-10-CM', editions);
      if (s.labels.isNotEmpty) line('Sources', s.labels.join('\n'));
      line('Last check', s.lastCheck == null ? 'Never' : when.format(s.lastCheck!.toLocal()));
      if (s.pendingSerial != null) line('Next start', 'Release ${s.pendingSerial} is downloaded and verified');
      final r = s.lastResult;
      if (r != null && r.status == CodesetUpdateStatus.failed) line('Last result', 'Check failed. Current sets stay in use.');
    }

    final canCheck = u != null && !_busy && !(s?.checking ?? false);
    final canReset = u != null && !_busy && s != null && (!s.usingBundled || s.pendingSerial != null);
    return SectionCard(
      title: 'Code sets',
      icon: Icons.menu_book_outlined,
      actions: [tag],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Official CMS code sets. Signed updates are checked once a day and used from the next start.',
            style: muted,
          ),
          const SizedBox(height: 6),
          ...rows,
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: canCheck ? _checkNow : null,
                icon: _busy || (s?.checking ?? false)
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync_rounded),
                label: const Text('Check now'),
              ),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: canReset ? _useBuiltIn : null,
                child: const Text('Use built-in code sets'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          widget.cmsUpdates ?? const CmsUpdatesSection(),
        ],
      ),
    );
  }
}
