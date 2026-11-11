import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/subscriptions/subscription_service.dart';
import '../widgets/legal_links.dart';

/// Shows the paywall when a new visit needs SOLIS Pro. Returns true when
/// the clinician may go ahead.
Future<bool> ensurePro(BuildContext context, {AuthService? auth, SubscriptionService? subscriptions}) async {
  final subs = subscriptions ?? SubscriptionService.instance;
  if (!subs.blocksNewVisits(auth ?? AuthService.instance)) return true;
  final unlocked = await Navigator.of(context).push<bool>(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => PaywallScreen(subscriptions: subs)),
  );
  return unlocked == true || subs.isPro;
}

/// SOLIS Pro plans from Google Play, with restore and an access code.
class PaywallScreen extends StatefulWidget {
  final SubscriptionService? subscriptions;
  const PaywallScreen({super.key, this.subscriptions});

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  SubscriptionService get _subs => widget.subscriptions ?? SubscriptionService.instance;

  List<SubscriptionPlan>? _plans;
  SubscriptionPlan? _chosen;
  String? _error;
  String? _note;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _plans = null;
    });
    try {
      final plans = await _subs.plans();
      if (!mounted) return;
      setState(() {
        _plans = plans;
        _chosen = plans.firstWhere((p) => p.isYearly, orElse: () => plans.first);
      });
    } on SubscriptionException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });
    try {
      await action();
    } on SubscriptionException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _done() => Navigator.of(context).pop(true);

  Future<void> _buy() => _run(() async {
        final plan = _chosen;
        if (plan == null) return;
        final outcome = await _subs.purchase(plan);
        if (!mounted) return;
        switch (outcome) {
          case PurchaseOutcome.purchased:
            _done();
          case PurchaseOutcome.pending:
            setState(() => _note = 'Google Play is still confirming your payment. SOLIS Pro unlocks as soon as it does.');
          case PurchaseOutcome.cancelled:
            break;
        }
      });

  Future<void> _restore() => _run(() async {
        final found = await _subs.restore();
        if (!mounted) return;
        if (found) {
          _done();
        } else {
          setState(() => _note = 'No SOLIS Pro subscription was found for this Google account.');
        }
      });

  Future<void> _code() async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AccessCodeDialog(subscriptions: _subs));
    if (ok == true && mounted) _done();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final plans = _plans;
    return Scaffold(
      appBar: AppBar(title: const Text('SOLIS Pro')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Text('Keep documenting and billing with SOLIS Pro', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            for (final line in const [
              'Unlimited visits, notes and claims',
              'Voice notes written on this phone or in the cloud',
              'Claim checks, eligibility and 837P files',
              'Your patients and visits stay yours: nothing is locked if you stop',
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Icon(Icons.check_circle_outline, size: 20, color: cs.primary),
                  const SizedBox(width: 10),
                  Expanded(child: Text(line)),
                ]),
              ),
            const SizedBox(height: 16),
            if (plans == null && _error == null) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
            if (plans != null)
              RadioGroup<SubscriptionPlan>(
                groupValue: _chosen,
                onChanged: (p) => setState(() => _chosen = p),
                child: Column(
                  children: [
                    for (final p in plans)
                      Card(
                        key: Key('plan_${p.id}'),
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: p == _chosen ? cs.primary : cs.outlineVariant, width: p == _chosen ? 2 : 1),
                        ),
                        child: RadioListTile<SubscriptionPlan>(
                          value: p,
                          title: Text(p.title),
                          subtitle: Text([
                            '${p.price} per ${p.period}',
                            if (p.perMonth != null) '(${p.perMonth})',
                            if (p.trial != null) '· ${p.trial}',
                          ].join(' ')),
                        ),
                      ),
                  ],
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, key: const Key('paywall_error'), style: TextStyle(color: cs.error)),
              ),
            if (_note != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_note!, key: const Key('paywall_note')),
              ),
            if (_error != null && plans == null)
              Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: _load, child: const Text('Try again'))),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('paywall_subscribe'),
              onPressed: _busy || _chosen == null ? null : _buy,
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(_chosen?.trial != null ? 'Start free trial' : 'Subscribe'),
            ),
            const SizedBox(height: 8),
            Text(
              _chosen == null
                  ? ''
                  : '${_chosen!.trial != null ? 'After the trial, ' : ''}${_chosen!.price} is charged to your Google Play account every ${_chosen!.period} '
                      'until you cancel. Cancel any time in Google Play > Subscriptions.',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                TextButton(key: const Key('paywall_restore'), onPressed: _busy ? null : _restore, child: const Text('Restore purchase')),
                TextButton(key: const Key('paywall_code'), onPressed: _busy ? null : _code, child: const Text('I have an access code')),
              ],
            ),
            const LegalLinks(),
          ],
        ),
      ),
    );
  }
}

/// Enter a reviewer or partner access code.
class AccessCodeDialog extends StatefulWidget {
  final SubscriptionService subscriptions;
  const AccessCodeDialog({super.key, required this.subscriptions});

  @override
  State<AccessCodeDialog> createState() => _AccessCodeDialogState();
}

class _AccessCodeDialogState extends State<AccessCodeDialog> {
  final _code = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.subscriptions.redeemAccessCode(_code.text);
      if (mounted) Navigator.of(context).pop(true);
    } on SubscriptionException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Access code'),
        content: TextField(
          key: const Key('access_code'),
          controller: _code,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(labelText: 'Code', errorText: _error, errorMaxLines: 3),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(key: const Key('access_code_submit'), onPressed: _busy ? null : _submit, child: const Text('Unlock')),
        ],
      );
}
