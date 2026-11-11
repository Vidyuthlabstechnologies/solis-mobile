import 'dart:async';

import 'package:flutter/material.dart';

import '../models/patient_account.dart';
import '../services/account_repository.dart';
import '../services/app_session.dart';
import '../services/auth_service.dart';
import '../services/billing/billing_queue.dart';
import '../services/billing/billing_stats.dart';
import '../services/billing/claim_submission_service.dart';
import '../services/billing/claims_csv.dart';
import '../services/coding/place_of_service.dart';
import '../services/patient_list.dart';
import '../services/value_report.dart';
import '../services/security/phi_clipboard.dart';
import '../widgets/medical_disclaimer.dart';
import '../theme/solis_theme.dart';
import '../widgets/encounter_widgets.dart';
import 'encounter_screen.dart';
import 'patient_chart_screen.dart';
import 'paywall_screen.dart';
import 'integrations_screen.dart';
import 'provider_profile_screen.dart';
import 'scan_card_screen.dart';

/// Home: Today's visits, every patient, and the Billing queue.
///
/// Today lists the visits with today's date of service, unfinished first.
/// Patients is every account, searchable by name, account number or member
/// ID. Billing groups every visit by what it needs next (signature, fixes,
/// send, payer) and sends the clean ones in one batch. Claim status refreshes
/// when the app opens and on pull to refresh.
class PatientsScreen extends StatefulWidget {
  final bool isDark;
  final ValueChanged<bool>? onThemeToggle;
  final int initialTab;

  /// Test hook: the claim service the Billing tab uses.
  final ClaimSubmissionService? claimService;

  const PatientsScreen({super.key, this.isDark = false, this.onThemeToggle, this.initialTab = 0, this.claimService});

  /// Claim status is refreshed once per app start, not on every rebuild.
  static bool _refreshedThisLaunch = false;

  /// How often a screen left open checks the outbox and claim status.
  static const statusRefreshEvery = Duration(hours: 3);

  @visibleForTesting
  static void resetLaunchRefresh() => _refreshedThisLaunch = false;

  @override
  State<PatientsScreen> createState() => _PatientsScreenState();
}

class _PatientsScreenState extends State<PatientsScreen> {
  final _search = TextEditingController();
  String _query = '';
  late int _tab = widget.initialTab;
  late final ClaimSubmissionService _claims = widget.claimService ?? ClaimSubmissionService();
  bool _refreshing = false;

  AccountRepository get _repo => AccountRepository.instance;

  @override
  void initState() {
    super.initState();
    _repo.addListener(_onChanged);
    if (!PatientsScreen._refreshedThisLaunch && _claims.isConnected) {
      PatientsScreen._refreshedThisLaunch = true;
      // Send what waited in the outbox and pick up payer answers.
      unawaited(_refresh(minAge: const Duration(hours: 1), quiet: true));
    }
    // While the app stays open, outbox and payer status are checked again
    // every few hours (claims checked within the last hours are skipped).
    _statusTimer = Timer.periodic(PatientsScreen.statusRefreshEvery, (_) {
      if (mounted && _claims.isConnected) unawaited(_refresh(minAge: PatientsScreen.statusRefreshEvery, quiet: true));
    });
  }

  Timer? _statusTimer;

  @override
  void dispose() {
    _repo.removeListener(_onChanged);
    _statusTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh({Duration minAge = Duration.zero, bool quiet = false}) async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final sent = await _claims.retryQueued();
      final changed = await _claims.refreshAll(minAge: minAge);
      if (!mounted || quiet) return;
      _message([
        if (sent > 0) '$sent queued ${sent == 1 ? 'claim' : 'claims'} sent',
        if (changed > 0) '$changed ${changed == 1 ? 'claim' : 'claims'} updated by the payer',
        if (sent == 0 && changed == 0) 'Claim status is up to date',
      ].join('. '));
    } catch (_) {
      if (mounted && !quiet) _message('Could not reach the clearinghouse. Pull down to try again.');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _message(String text, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  PatientSort _sort = PatientSort.recent;
  PatientFilter _filter = PatientFilter.all;

  List<PatientAccount> get _filtered => patientList(_repo.accounts, query: _query, filter: _filter, sort: _sort);

  /// Registers a patient who cannot be identified yet, in one tap, and
  /// opens the chart so the visit can start. Billing waits for the name.
  Future<void> _addUnidentified() async {
    final name = unidentifiedName(DateTime.now());
    final account = await _repo.createAccount(firstName: name.first, lastName: name.last);
    if (!mounted) return;
    _message('${account.fullName} added. Enter the name when known; the claim waits for it.');
    _openChart(account);
  }

  Future<void> _copyClaimsCsv() async {
    final count = _repo.accounts.fold<int>(0, (n, a) => n + a.visits.where((v) => v.claim != null).length);
    if (count == 0) {
      _message('No claims to copy yet.');
      return;
    }
    await PhiClipboard.copy(claimsCsv(_repo.accounts));
    if (mounted) _message('$count ${count == 1 ? 'claim' : 'claims'} copied as CSV. Paste within 60 seconds; then the clipboard clears.');
  }

  Future<void> _openScan({bool manual = false}) async {
    final account = await Navigator.push<PatientAccount>(
      context,
      MaterialPageRoute(builder: (_) => ScanCardScreen(manualEntry: manual)),
    );
    if (account != null && mounted) _openChart(account);
  }

  static PopupMenuItem<String> _menuItem(String value, IconData icon, String label) => PopupMenuItem(
        value: value,
        child: Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 12),
            Text(label),
          ],
        ),
      );

  void _openChart(PatientAccount account) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PatientChartScreen(
          accountNumber: account.accountNumber,
          isDark: widget.isDark,
          onThemeToggle: widget.onThemeToggle,
        ),
      ),
    );
  }

  void _openVisit(PatientAccount account, Visit visit, {int tab = 0}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EncounterScreen(
          accountNumber: account.accountNumber,
          visitNumber: visit.number,
          isDark: widget.isDark,
          onThemeToggle: widget.onThemeToggle,
          initialReviewTab: tab,
        ),
      ),
    );
  }

  Future<void> _showRecentlyDeleted() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final deleted = _repo.recentlyDeleted;
          final theme = Theme.of(ctx);
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
            child: SafeArea(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  Text('Recently deleted', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    'Deleted patients stay here for ${AccountRepository.softDeleteWindow.inDays} days, then they are erased.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  if (deleted.isEmpty)
                    const EmptyState(icon: Icons.delete_outline_rounded, title: 'Nothing deleted', message: 'Deleted patients can be restored from here.')
                  else
                    for (final a in deleted)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(a.fullName),
                        subtitle: Text('${a.accountNumber}  |  deleted ${formatDate(a.deletedAtUtc?.toLocal())}'),
                        trailing: TextButton(
                          onPressed: () async {
                            await _repo.restorePatient(a.accountNumber);
                            setSheet(() {});
                          },
                          child: const Text('Restore'),
                        ),
                      ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final provider = _repo.provider;
    final items = classifyVisits(_repo.accounts, provider, demoMode: _repo.demoMode);
    final needsWork = items.where((i) => i.bucket.index <= BillingBucket.queued.index).length;

    return Scaffold(
      appBar: AppBar(
        title: Text(switch (_tab) { 0 => 'Today', 1 => 'Patients', _ => 'Billing' }),
        actions: [
          IconButton(
            tooltip: 'Add patient without a card',
            icon: const Icon(Icons.person_add_alt_outlined),
            onPressed: () => _openScan(manual: true),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Tooltip(
              message: 'Provider profile',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProviderProfileScreen())),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: cs.primary.withAlpha(widget.isDark ? 70 : 30),
                    foregroundColor: widget.isDark ? cs.primary : SolisTheme.primaryBlue,
                    child: Text(provider.initials, style: theme.textTheme.labelLarge?.copyWith(color: widget.isDark ? cs.primary : SolisTheme.primaryBlue)),
                  ),
                ),
              ),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) async {
              if (v == 'theme') widget.onThemeToggle?.call(!widget.isDark);
              if (v == 'integrations') Navigator.push(context, MaterialPageRoute(builder: (_) => const IntegrationsScreen()));
              if (v == 'deleted') _showRecentlyDeleted();
              if (v == 'csv') _copyClaimsCsv();
              if (v == 'unidentified') _addUnidentified();
              if (v == 'about') showSolisAbout(context);
              if (v == 'signout') {
                final nav = Navigator.of(context);
                await AuthService.instance.signOut();
                _repo.setDemoMode(false);
                nav.pushNamedAndRemoveUntil(AppSession.loginRoute, (_) => false);
              }
            },
            itemBuilder: (_) => [
              _menuItem('integrations', Icons.hub_outlined, 'Integrations'),
              _menuItem('unidentified', Icons.person_search_outlined, 'Unidentified patient (EMS, ED)'),
              _menuItem('deleted', Icons.restore_from_trash_outlined, 'Recently deleted'),
              _menuItem('csv', Icons.table_chart_outlined, 'Copy claims as CSV'),
              if (widget.onThemeToggle != null)
                _menuItem('theme', widget.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, widget.isDark ? 'Light theme' : 'Dark theme'),
              _menuItem('about', Icons.info_outline, 'About SOLIS'),
              _menuItem('signout', Icons.logout_rounded, 'Sign out'),
            ],
          ),
        ],
      ),
      floatingActionButton: _tab == 2
          ? null
          : FloatingActionButton.extended(
              onPressed: _openScan,
              icon: const Icon(Icons.document_scanner_outlined),
              label: const Text('Scan card'),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.today_outlined), selectedIcon: Icon(Icons.today_rounded), label: 'Today'),
          const NavigationDestination(icon: Icon(Icons.people_outline_rounded), selectedIcon: Icon(Icons.people_rounded), label: 'Patients'),
          NavigationDestination(
            icon: Badge(isLabelVisible: needsWork > 0, label: Text('$needsWork'), child: const Icon(Icons.receipt_long_outlined)),
            selectedIcon: Badge(isLabelVisible: needsWork > 0, label: Text('$needsWork'), child: const Icon(Icons.receipt_long_rounded)),
            label: 'Billing',
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (_repo.demoMode) const _DemoStrip(),
            Expanded(
              child: switch (_tab) {
                0 => _buildToday(context, items),
                1 => _buildPatients(context),
                _ => _buildBilling(context, items),
              },
            ),
          ],
        ),
      ),
    );
  }

  // --- Today ---------------------------------------------------------------

  /// What is left for the day, all dates: tapping it opens Billing.
  Widget? _daySummaryCard(BuildContext context, List<BillingItem> items) {
    final d = daySummary(items);
    if (d.clear) return null;
    final theme = Theme.of(context);
    String n(int c, String one, String many) => '$c ${c == 1 ? one : many}';
    final parts = [
      if (d.unsigned > 0) n(d.unsigned, 'note to sign', 'notes to sign'),
      if (d.needsFixes > 0) n(d.needsFixes, 'claim to fix', 'claims to fix'),
      if (d.readyToSend > 0) n(d.readyToSend, 'claim ready to send', 'claims ready to send'),
    ];
    return Card(
      key: const Key('day_summary'),
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.checklist_rounded),
        title: Text('Left to do', style: theme.textTheme.titleSmall),
        subtitle: Text(parts.join(', ')),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => setState(() => _tab = 2),
      ),
    );
  }

  /// What SOLIS did today and this week: notes signed, claims sent, the
  /// amount billed, and an estimate of the time saved.
  Widget? _valueCard(BuildContext context) {
    final r = ValueReport.compute(_repo.accounts);
    if (r.week.isEmpty) return null;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    String line(ValueTotals t) => [
          '${t.notesSigned} ${t.notesSigned == 1 ? 'note' : 'notes'} signed',
          '${t.claimsSent} ${t.claimsSent == 1 ? 'claim' : 'claims'} sent (${formatDollars(t.billed)})',
          'about ${t.timeSavedLabel} saved',
        ].join(', ');
    return Card(
      key: const Key('value_card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.insights_rounded, color: cs.primary),
              const SizedBox(width: 12),
              Expanded(child: Text('What SOLIS did for you', style: theme.textTheme.titleSmall)),
            ]),
            const SizedBox(height: 8),
            Text('Today: ${line(r.today)}.', key: const Key('value_today')),
            const SizedBox(height: 4),
            Text('Last 7 days: ${line(r.week)}.', key: const Key('value_week')),
            const SizedBox(height: 6),
            Text(
              'Time saved is an estimate of ${ValueTotals.minutesPerNote} minutes of writing per signed note.',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToday(BuildContext context, List<BillingItem> items) {
    final visits = visitsOn(_repo.accounts);
    final summary = _daySummaryCard(context, items);
    final value = _valueCard(context);
    if (visits.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        children: [
          ?summary,
          if (summary != null && value != null) const SizedBox(height: 8),
          ?value,
          const EmptyState(
            icon: Icons.today_outlined,
            title: 'No visits today',
            message: 'Scan a card for a new patient, or open a patient in Patients to start a visit.',
          ),
        ],
      );
    }
    final header = [?summary, ?value];
    final offset = header.length;
    return ListView.separated(
      key: const Key('today_list'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      itemCount: visits.length + offset,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        if (i < offset) return header[i];
        final (a, v) = visits[i - offset];
        return _VisitCard(
          title: a.fullName,
          subtitle: 'Visit ${v.number}  |  ${placeOfService(v.placeOfService).label}',
          trailing: VisitStatusTag(status: v.status),
          onTap: () => _openVisit(a, v),
        );
      },
    );
  }

  // --- Patients ------------------------------------------------------------

  Widget _buildPatients(BuildContext context) {
    final list = _filtered;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _search,
            onChanged: (v) => setState(() => _query = v),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search name, account or member ID',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => setState(() {
                        _search.clear();
                        _query = '';
                      }),
                    ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final f in PatientFilter.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(patientFilterLabel(f)),
                            selected: _filter == f,
                            onSelected: (_) => setState(() => _filter = f),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              PopupMenuButton<PatientSort>(
                tooltip: 'Sort patients',
                icon: const Icon(Icons.sort_rounded),
                initialValue: _sort,
                onSelected: (v) => setState(() => _sort = v),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: PatientSort.recent, child: Text('Last visit, newest first')),
                  PopupMenuItem(value: PatientSort.name, child: Text('Name, A to Z')),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? ListView(
                  children: [
                    EmptyState(
                      icon: _query.isEmpty && _filter == PatientFilter.all ? Icons.badge_outlined : Icons.search_off_rounded,
                      title: _query.isEmpty && _filter == PatientFilter.all ? 'No patients yet' : 'No matches',
                      message: _query.isEmpty && _filter == PatientFilter.all
                          ? 'Scan an insurance card or driver\'s license to open a patient account.'
                          : _query.isEmpty
                              ? 'No patients match this filter.'
                              : 'Try a different name, account number or member ID.',
                    ),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => _PatientTile(account: list[i], onTap: () => _openChart(list[i])),
                ),
        ),
      ],
    );
  }

  // --- Billing -------------------------------------------------------------

  Widget _buildBilling(BuildContext context, List<BillingItem> items) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sendable = batchSendable(items);
    final connected = _claims.isConnected;
    final groups = <BillingBucket, List<BillingItem>>{};
    for (final i in items) {
      groups.putIfAbsent(i.bucket, () => []).add(i);
    }

    return RefreshIndicator(
      onRefresh: () => _refresh(),
      child: ListView(
        key: const Key('billing_list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (connected && sendable.isNotEmpty)
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                key: const Key('batch_send'),
                onPressed: () => _batchSend(sendable),
                icon: const Icon(Icons.outbox_outlined),
                label: Text('Send ${sendable.length} ready ${sendable.length == 1 ? 'claim' : 'claims'}'),
              ),
            )
          else if (!connected)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(Icons.hub_outlined, size: 18, color: cs.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No clearinghouse connected. Claims are copied from each visit until one is set up in Integrations.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          if (_refreshing) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
          _MoneyCard(accounts: _repo.accounts),
          if (items.isEmpty)
            const EmptyState(icon: Icons.receipt_long_outlined, title: 'Nothing to bill', message: 'Signed visits and their claims appear here.')
          else
            for (final b in BillingBucket.values)
              if (groups[b] != null) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                  child: Row(
                    children: [
                      Expanded(child: Text(billingBucketLabel(b), style: theme.textTheme.titleSmall?.copyWith(color: cs.primary))),
                      Text('${groups[b]!.length}', style: theme.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
                for (final item in groups[b]!) ...[
                  _VisitCard(
                    key: Key('billing_${item.claimId}'),
                    title: item.account.fullName,
                    subtitle: [
                      item.claimId,
                      formatDos(item.visit.dateOfService),
                      if (item.total > 0) '\$${item.total.toStringAsFixed(2)}',
                    ].join('  |  '),
                    detail: _detailFor(item),
                    trailing: VisitStatusTag(status: item.visit.status),
                    onTap: () => _openVisit(item.account, item.visit, tab: b == BillingBucket.needsSignature ? 0 : 3),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
        ],
      ),
    );
  }

  String? _detailFor(BillingItem i) => switch (i.bucket) {
        BillingBucket.needsSignature => 'Review and sign the note',
        BillingBucket.needsFixes => '${i.errors} ${i.errors == 1 ? 'issue' : 'issues'} to fix',
        BillingBucket.readyToSend => i.warnings > 0 ? '${i.warnings} ${i.warnings == 1 ? 'warning' : 'warnings'} to review before sending' : null,
        BillingBucket.queued => 'Sends when the connection is back',
        BillingBucket.rejected || BillingBucket.denied => (i.visit.submission?['statusExplanation'] ??
                i.visit.submission?['lastStatus'] ?? (i.visit.submission?['errors'] as List?)?.firstOrNull)?.toString(),
        BillingBucket.paidThisWeek => i.visit.submission?['paidAmount'] == null ? null : 'Paid \$${i.visit.submission!['paidAmount']}',
        BillingBucket.awaitingPayer => i.visit.submission?['lastStatus']?.toString(),
      };

  /// One confirmation for the batch, then each claim is sent in turn with
  /// its own idempotency key; a row per claim shows how it went.
  Future<void> _batchSend(List<BillingItem> sendable) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BatchSendDialog(items: sendable, service: _claims),
    );
    if (mounted) setState(() {});
  }
}

/// Confirms a batch send, then sends the claims one by one.
class BatchSendDialog extends StatefulWidget {
  final List<BillingItem> items;
  final ClaimSubmissionService service;

  const BatchSendDialog({super.key, required this.items, required this.service});

  @override
  State<BatchSendDialog> createState() => _BatchSendDialogState();
}

class _BatchSendDialogState extends State<BatchSendDialog> {
  final Map<String, SendResult?> _results = {};
  bool _sending = false;
  bool _done = false;

  Future<void> _send() async {
    // Real claims need SOLIS Pro; test claims are free.
    if (!widget.service.isTest && !await ensurePro(context)) return;
    if (!mounted) return;
    setState(() => _sending = true);
    for (final i in widget.items) {
      setState(() => _results[i.claimId] = null);
      SendResult r;
      try {
        r = await widget.service.send(i.account.accountNumber, i.visit.number);
      } catch (e) {
        r = SendResult(SendStatus.failed, problems: ['$e']);
      }
      if (!mounted) return;
      setState(() => _results[i.claimId] = r);
    }
    if (mounted) {
      setState(() {
        _sending = false;
        _done = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final test = widget.service.isTest;
    final total = widget.items.fold<double>(0, (s, i) => s + i.total);
    Widget status(BillingItem i) {
      if (!_results.containsKey(i.claimId)) return const SizedBox.shrink();
      final r = _results[i.claimId];
      if (r == null) return const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
      final (label, color, icon) = switch (r.status) {
        SendStatus.accepted => ('Sent', SolisTheme.success, Icons.check_rounded),
        SendStatus.queued => ('Queued', SolisTheme.warning, Icons.schedule_send_outlined),
        SendStatus.rejected => ('Rejected', SolisTheme.danger, Icons.error_outline_rounded),
        _ => ('Not sent', SolisTheme.danger, Icons.error_outline_rounded),
      };
      return StatusTag(label: label, color: color, icon: icon);
    }

    return AlertDialog(
      icon: const Icon(Icons.outbox_outlined, size: 32),
      title: Text(
        '${test ? 'Send ${widget.items.length} test' : 'Send ${widget.items.length}'} ${widget.items.length == 1 ? 'claim' : 'claims'}${test ? '' : ' to payers'}?',
        textAlign: TextAlign.center,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              test
                  ? 'Test mode: the clearinghouse checks the claims but no payer pays them.'
                  : 'Production: payers will adjudicate these claims. Total \$${total.toStringAsFixed(2)}.',
              style: theme.textTheme.bodyMedium?.copyWith(color: test ? null : SolisTheme.onTint(SolisTheme.warning, isDark: dark)),
            ),
            const SizedBox(height: 8),
            for (final i in widget.items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(i.account.fullName, style: theme.textTheme.bodyLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text('${i.claimId}  |  \$${i.total.toStringAsFixed(2)}', style: theme.textTheme.bodySmall),
                          if (_results[i.claimId]?.problems.isNotEmpty == true && _results[i.claimId]!.status != SendStatus.accepted)
                            Text(_results[i.claimId]!.problems.first, style: theme.textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    status(i),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: _done
          ? [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))]
          : [
              TextButton(onPressed: _sending ? null : () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(
                key: const Key('batch_send_confirm'),
                onPressed: _sending ? null : _send,
                child: Text('Send ${widget.items.length}'),
              ),
            ],
    );
  }
}

/// One line saying the app is in demo mode, on every home tab.
/// This month's billed and paid totals and what payers still owe, by age.
class _MoneyCard extends StatelessWidget {
  final List<PatientAccount> accounts;
  const _MoneyCard({required this.accounts});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final month = monthTotals(accounts, month: now);
    final aging = arAging(accounts, today: now);
    if (month.claims == 0 && aging.count == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    String money(double v) => '\$${v.toStringAsFixed(2)}';
    const tabular = [FontFeature.tabularFigures()];
    Widget cell(String label, String value) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
              Text(value, style: theme.textTheme.bodyMedium?.copyWith(fontFeatures: tabular)),
            ],
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        key: const Key('money_card'),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('This month', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Row(children: [cell('Billed', money(month.billed)), cell('Paid', money(month.paid)), cell('Claims', '${month.claims}')]),
              if (aging.count > 0) ...[
                const SizedBox(height: 16),
                Text('Waiting on payers, by days since the visit', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Row(children: [
                  for (var i = 0; i < 4; i++) cell('${ArAging.labels[i]} days', money(aging.buckets[i])),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DemoStrip extends StatelessWidget {
  const _DemoStrip();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: cs.outlineVariant))),
      child: Row(
        children: [
          Icon(Icons.science_outlined, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Demo mode: sample patients and a demo provider. Claims go to test only.',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _VisitCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String? detail;
  final Widget trailing;
  final VoidCallback onTap;

  const _VisitCard({super.key, required this.title, required this.subtitle, required this.trailing, required this.onTap, this.detail});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(subtitle, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant), maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (detail != null && detail!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(detail!, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant), maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                    const SizedBox(height: 6),
                    trailing,
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _PatientTile extends StatelessWidget {
  final PatientAccount account;
  final VoidCallback onTap;

  const _PatientTile({required this.account, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final last = account.visits.isEmpty ? null : account.visits.reduce((a, b) => a.number > b.number ? a : b);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(account.fullName, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      '${account.ageSex}  |  ${account.accountNumber}',
                      style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      account.insurance == null ? 'No insurance on file' : account.insurance!.payerName,
                      style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      last == null ? 'No visits' : 'Visit ${last.number}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(color: last == null ? cs.onSurfaceVariant : cs.onSurface),
                    ),
                    if (last != null) ...[
                      const SizedBox(height: 2),
                      Text(formatDos(last.dateOfService), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      const SizedBox(height: 4),
                      VisitStatusTag(status: last.status),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "2026-10-15" -> "Oct 15, 2026".
String formatDos(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return '${_months[d.month - 1]} ${d.day}, ${d.year}';
}

String formatDate(DateTime? d) => d == null ? 'Not on file' : '${_months[d.month - 1]} ${d.day}, ${d.year}';
