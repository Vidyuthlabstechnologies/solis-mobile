import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'paywall_screen.dart';
import '../models/patient_account.dart';
import '../services/account_repository.dart';
import '../services/billing/eligibility_service.dart';
import '../services/coding/place_of_service.dart';
import '../services/places.dart';
import '../services/security/phi_clipboard.dart';
import '../theme/solis_theme.dart';
import '../widgets/encounter_widgets.dart';
import 'encounter_screen.dart';
import 'patients_screen.dart';
import 'scan_card_screen.dart';
import '../services/patient_merge.dart';

/// One patient account: demographics, insurance and every visit (date of
/// service) under the account number.
class PatientChartScreen extends StatefulWidget {
  final String accountNumber;
  final bool isDark;
  final ValueChanged<bool>? onThemeToggle;

  const PatientChartScreen({super.key, required this.accountNumber, this.isDark = false, this.onThemeToggle});

  @override
  State<PatientChartScreen> createState() => _PatientChartScreenState();
}

class _PatientChartScreenState extends State<PatientChartScreen> {
  AccountRepository get _repo => AccountRepository.instance;
  final EligibilityService _eligibilityService = EligibilityService();

  @override
  void initState() {
    super.initState();
    _repo.addListener(_changed);
    // Coverage is rechecked when the chart opens and the last check is a
    // day old, so an expired plan shows before the visit, not after a denial.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshEligibilityIfStale());
  }

  Future<void> _refreshEligibilityIfStale() async {
    final account = _repo.byNumber(widget.accountNumber);
    if (account == null || !_eligibilityService.isConfigured || account.insurance == null) return;
    final latest = account.visits.isEmpty ? null : account.visits.reduce((a, b) => a.number > b.number ? a : b);
    if (latest != null && !_eligibilityService.isStale(latest)) return;
    final r = await _eligibilityService.check(account.accountNumber, visitNumber: latest?.number);
    if (mounted && latest == null && r != null) setState(() => _lastEligibility = r);
  }

  @override
  void dispose() {
    _repo.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String _today() => DateTime.now().toIso8601String().split('T').first;

  /// Opens today's unfinished visit, or starts one at once: today's date and
  /// the place of service from a saved place, the last visit (30 days) or the
  /// profile default. Both stay visible and changeable on the visit.
  Future<void> _startVisit(PatientAccount account) async {
    final today = account.visits.where((v) => v.dateOfService == _today() && v.status == VisitStatus.inProgress).toList();
    if (today.isNotEmpty) {
      _openVisit(account, today.last.number);
      return;
    }
    if (!await ensurePro(context) || !mounted) return;
    final choice = choosePlaceOfService(provider: _repo.provider, account: account);
    final visit = await _repo.addVisit(account.accountNumber, dateOfService: DateTime.now(), placeOfService: choice.code, posSource: choice.source);
    // Check coverage in the background while the visit runs.
    unawaited(_eligibilityService.check(account.accountNumber, visitNumber: visit.number).catchError((Object _) => null));
    if (mounted) _openVisit(account, visit.number);
  }

  /// A visit on another date (late documentation), with its place of service.
  Future<void> _startVisitOnDate(PatientAccount account) async {
    if (!await ensurePro(context) || !mounted) return;
    var date = DateTime.now();
    var pos = choosePlaceOfService(provider: _repo.provider, account: account).code;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text('Visit ${account.visits.fold<int>(0, (m, v) => v.number > m ? v.number : m) + 1}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(SolisTheme.radiusMd),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: date,
                    firstDate: DateTime(DateTime.now().year - 1),
                    lastDate: DateTime.now(),
                    helpText: 'Date of service',
                  );
                  if (picked != null) setDialog(() => date = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Date of service', prefixIcon: Icon(Icons.event_outlined)),
                  child: Text(formatDos(date.toIso8601String().split('T').first)),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: pos,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Place of service', prefixIcon: Icon(Icons.place_outlined)),
                items: [
                  for (final p in placesOfService)
                    DropdownMenuItem(
                      value: p.code,
                      child: Text(p.label, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setDialog(() => pos = v ?? pos),
              ),
              const SizedBox(height: 8),
              Text(
                'Place of service decides which visit codes are valid and how the claim pays.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Start visit')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final visit = await _repo.addVisit(account.accountNumber, dateOfService: date, placeOfService: pos, posSource: 'manual');
    unawaited(_eligibilityService.check(account.accountNumber, visitNumber: visit.number).catchError((Object _) => null));
    if (mounted) _openVisit(account, visit.number);
  }

  bool _checking = false;

  /// Real-time eligibility (270/271), saved on the latest visit.
  Future<void> _checkEligibility(PatientAccount account) async {
    final ins = account.insurance;
    if (ins == null) return;
    if (ins.payerId == null || ins.payerId!.isEmpty) {
      _message('Add the payer ID from the back of the card to check eligibility.');
      return;
    }
    final target = account.visits.isEmpty ? null : account.visits.reduce((a, b) => a.number > b.number ? a : b);
    setState(() => _checking = true);
    try {
      final r = await _eligibilityService.check(account.accountNumber, visitNumber: target?.number);
      if (!mounted) return;
      if (target == null && r != null) setState(() => _lastEligibility = r);
      _message(switch (EligibilityService.stateOf(r)) {
        EligibilityState.inactive => 'Coverage is not active for this date.',
        EligibilityState.failed => EligibilityService.describe(r),
        _ => 'Coverage checked.',
      });
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// Hides the patient with Undo. The account stays restorable for 30 days
  /// (Patients, Recently deleted), then it is erased.
  Future<void> _deletePatient(PatientAccount account) async {
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    final deleted = await _repo.deletePatient(account.accountNumber);
    if (deleted == null) return;
    HapticFeedback.mediumImpact();
    nav.pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('${account.fullName} deleted. Restorable for ${AccountRepository.softDeleteWindow.inDays} days.'),
        action: SnackBarAction(label: 'Undo', onPressed: () => _repo.restorePatient(account.accountNumber)),
      ));
  }

  /// Picks a duplicate chart and merges it into this one.
  Future<void> _mergeInto(PatientAccount account) async {
    final likely = {
      for (final m in _repo.findMatches(firstName: account.firstName, lastName: account.lastName, dateOfBirth: account.dateOfBirth, memberId: account.insurance?.memberId))
        m.accountNumber,
    };
    final others = _repo.accounts.where((a) => a.accountNumber != account.accountNumber).toList()
      ..sort((a, b) {
        final la = likely.contains(a.accountNumber) ? 0 : 1;
        final lb = likely.contains(b.accountNumber) ? 0 : 1;
        return la != lb ? la.compareTo(lb) : a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase());
      });
    if (others.isEmpty) {
      _message('There is no other chart to merge.');
      return;
    }
    final picked = await showModalBottomSheet<PatientAccount>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(title: Text('Merge which chart into ${account.fullName}?', style: Theme.of(ctx).textTheme.titleMedium)),
              for (final o in others)
                ListTile(
                  key: Key('merge_pick_${o.accountNumber}'),
                  leading: Icon(likely.contains(o.accountNumber) ? Icons.content_copy_rounded : Icons.person_outline_rounded),
                  title: Text(o.fullName),
                  subtitle: Text([
                    o.accountNumber,
                    if (o.dateOfBirth != null) 'DOB ${formatDate(o.dateOfBirth)}',
                    '${o.visits.length} ${o.visits.length == 1 ? 'visit' : 'visits'}',
                    if (likely.contains(o.accountNumber)) 'likely the same person',
                  ].join('  |  ')),
                  onTap: () => Navigator.pop(ctx, o),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final preview = planMerge(account, picked);
    if (preview.blocked != null) {
      _message(preview.blocked!);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Merge ${picked.fullName} into this chart?'),
        content: Text([
          '${picked.visits.length} ${picked.visits.length == 1 ? 'visit moves' : 'visits move'} to ${account.accountNumber}.',
          if (preview.filled.isNotEmpty) 'Filled in from the duplicate: ${preview.filled.join(', ')}.',
          'Details already on this chart are kept. ${picked.accountNumber} goes to Recently deleted.',
        ].join('\n\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(key: const Key('merge_confirm'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Merge')),
        ],
      ),
    );
    if (ok != true) return;
    final result = await _repo.mergePatients(account.accountNumber, picked.accountNumber);
    if (!mounted) return;
    _message(result.blocked ?? 'Merged. ${result.movedVisits.length} ${result.movedVisits.length == 1 ? 'visit' : 'visits'} moved to this chart.');
  }

  Map<String, dynamic>? _lastEligibility;

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Map<String, dynamic>? _eligibilityFor(PatientAccount account) {
    for (final v in [...account.visits]..sort((a, b) => b.number.compareTo(a.number))) {
      if (v.eligibility != null) return v.eligibility;
    }
    return _lastEligibility;
  }

  Widget _eligibilityRow(BuildContext context, PatientAccount account) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final e = _eligibilityFor(account);
    final configured = _eligibilityService.isConfigured;
    final dark = theme.brightness == Brightness.dark;
    final detail = EligibilityService.describe(e, configured: configured);
    final (color, icon) = switch (EligibilityService.stateOf(e)) {
      EligibilityState.notChecked => (cs.onSurfaceVariant, Icons.help_outline_rounded),
      EligibilityState.failed => (SolisTheme.onTint(SolisTheme.warning, isDark: dark), Icons.warning_amber_rounded),
      EligibilityState.inactive => (SolisTheme.onTint(SolisTheme.danger, isDark: dark), Icons.block_rounded),
      EligibilityState.active => (SolisTheme.onTint(SolisTheme.success, isDark: dark), Icons.verified_outlined),
    };

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 20, color: color)),
          const SizedBox(width: 8),
          Expanded(child: Text(detail, key: const Key('chart_eligibility'), style: theme.textTheme.bodyMedium?.copyWith(color: color))),
          if (configured)
            _checking
                ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                : TextButton(onPressed: () => _checkEligibility(account), child: Text(e == null ? 'Check' : 'Recheck')),
        ],
      ),
    );
  }

  void _openVisit(PatientAccount account, int number) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EncounterScreen(accountNumber: account.accountNumber, visitNumber: number, isDark: widget.isDark, onThemeToggle: widget.onThemeToggle),
      ),
    );
  }

  Future<void> _editAccount(PatientAccount account, {bool scan = false}) async {
    await Navigator.push<PatientAccount>(
      context,
      MaterialPageRoute(
        builder: (_) => ScanCardScreen(existingAccountNumber: account.accountNumber, manualEntry: !scan),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = _repo.byNumber(widget.accountNumber);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    if (account == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(icon: Icons.person_off_outlined, title: 'Account not found', message: 'It may have been removed.'),
      );
    }
    final ins = account.insurance;
    final inNetwork = ins != null && _repo.provider.acceptedPayers.any((p) => _payerMatch(p, ins.payerName));
    final visits = [...account.visits]..sort((a, b) => b.number.compareTo(a.number));
    final openToday = account.visits.where((v) => v.dateOfService == _today() && v.status == VisitStatus.inProgress).toList();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(account.fullName, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(account.accountNumber, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Scan a card for this patient',
            icon: const Icon(Icons.document_scanner_outlined),
            onPressed: () => _editAccount(account, scan: true),
          ),
          IconButton(tooltip: 'Edit patient details', icon: const Icon(Icons.edit_outlined), onPressed: () => _editAccount(account)),
          PopupMenuButton<String>(
            key: const Key('chart_menu'),
            tooltip: 'More',
            onSelected: (v) {
              if (v == 'date') _startVisitOnDate(account);
              if (v == 'delete') _deletePatient(account);
              if (v == 'merge') _mergeInto(account);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'date',
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.event_outlined, size: 20),
                  SizedBox(width: 12),
                  Flexible(child: Text('Visit for another date', overflow: TextOverflow.ellipsis)),
                ]),
              ),
              const PopupMenuItem(
                value: 'merge',
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.merge_rounded, size: 20),
                  SizedBox(width: 12),
                  Flexible(child: Text('Merge a duplicate chart', overflow: TextOverflow.ellipsis)),
                ]),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.delete_outline_rounded, size: 20, color: cs.error),
                  const SizedBox(width: 12),
                  Flexible(child: Text('Delete patient', overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.error))),
                ]),
              ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: () => _startVisit(account),
              icon: Icon(openToday.isNotEmpty ? Icons.play_arrow_rounded : Icons.add_rounded),
              label: Text(openToday.isNotEmpty ? 'Continue visit ${openToday.last.number}' : "Start today's visit"),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          SectionCard(
            title: 'Patient',
            icon: Icons.person_outline,
            actions: [
              if (account.isSample)
                const Padding(padding: EdgeInsets.only(right: 8), child: StatusTag(label: 'Sample', color: SolisTheme.info, icon: Icons.science_outlined)),
            ],
            child: Column(
              children: [
                _row(context, 'Account number', account.accountNumber, copy: true),
                _row(
                  context,
                  'Date of birth',
                  account.dateOfBirth == null ? 'Not on file' : '${formatDate(account.dateOfBirth)} (age ${account.ageOn()})',
                  missing: account.dateOfBirth == null,
                ),
                _row(context, 'Sex', switch (account.sex) {
                  PatientSex.male => 'Male',
                  PatientSex.female => 'Female',
                  _ => 'Not on file',
                }, missing: account.sex == PatientSex.unknown),
                if (account.addressLine1 != null || account.city != null)
                  _row(
                    context,
                    'Address',
                    [
                      account.addressLine1,
                      [account.city, account.state, account.zip].whereType<String>().join(' '),
                    ].whereType<String>().where((s) => s.trim().isNotEmpty).join(', '),
                  ),
                if (account.phone != null) _row(context, 'Phone', account.phone!),
                if (account.driverLicenseNumber != null)
                  _row(context, "Driver's license", '${account.driverLicenseState ?? ''} ${_mask(account.driverLicenseNumber!)}'.trim()),
                if (account.ssnLast4 != null) _row(context, 'SSN', 'Last 4: ${account.ssnLast4}'),
                InkWell(
                  key: const Key('allergies_row'),
                  onTap: () => _editAllergies(context, account),
                  child: _row(context, 'Allergies', account.allergySummary, missing: !account.allergiesRecorded),
                ),
                if (account.isMinorOn() || account.guarantor != null)
                  InkWell(
                    key: const Key('guarantor_row'),
                    onTap: () => _editGuarantor(context, account),
                    child: _row(context, 'Responsible party', account.guarantor?.summary ?? 'Needed for a minor', missing: account.guarantor == null),
                  ),
                InkWell(
                  key: const Key('language_row'),
                  onTap: () => _editLanguage(context, account),
                  child: _row(context, 'Language', account.languageSummary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Insurance',
            icon: Icons.health_and_safety_outlined,
            actions: [
              if (ins != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: StatusTag(
                    label: inNetwork ? 'In network' : 'Not in your payers',
                    color: inNetwork ? SolisTheme.success : SolisTheme.warning,
                    icon: inNetwork ? Icons.check_rounded : Icons.warning_amber_rounded,
                  ),
                ),
            ],
            child: ins == null
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('No insurance on file.', style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                        ),
                        TextButton.icon(
                          onPressed: () => _editAccount(account, scan: true),
                          icon: const Icon(Icons.document_scanner_outlined),
                          label: const Text('Scan card'),
                        ),
                      ],
                    ),
                  )
                : Column(
                    children: [
                      _row(context, 'Payer', [ins.payerName, if (ins.planType != null) ins.planType].join('  |  ')),
                      _row(context, 'Member ID', ins.memberId, copy: true),
                      if (ins.groupNumber != null) _row(context, 'Group', ins.groupNumber!),
                      if (ins.payerId != null) _row(context, 'Payer ID', ins.payerId!),
                      if (ins.rxBin != null || ins.rxPcn != null)
                        _row(
                          context,
                          'Pharmacy',
                          ['BIN ${ins.rxBin ?? '-'}', 'PCN ${ins.rxPcn ?? '-'}', if (ins.rxGroup != null) 'Group ${ins.rxGroup}'].join('  |  '),
                        ),
                      if (ins.copays.isNotEmpty) _row(context, 'Copays', ins.copays.entries.map((e) => '${e.key} ${e.value}').join('  |  ')),
                      _eligibilityRow(context, account),
                    ],
                  ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text('Visits', style: theme.textTheme.titleMedium),
          ),
          if (visits.isEmpty)
            const EmptyState(
              icon: Icons.event_note_outlined,
              title: 'No visits yet',
              message: "Start today's visit to record the conversation and build the claim.",
            )
          else
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < visits.length; i++) ...[
                    if (i > 0) const Divider(indent: 16, endIndent: 16),
                    _VisitTile(visit: visits[i], onTap: () => _openVisit(account, visits[i].number)),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _mask(String s) => s.length <= 4 ? s : '${'*' * (s.length - 4)}${s.substring(s.length - 4)}';

  static bool _payerMatch(String a, String b) {
    String n(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    final x = n(a), y = n(b);
    return x.isNotEmpty && y.isNotEmpty && (x.contains(y) || y.contains(x));
  }

  /// Records allergies as free text, or "No known allergies" in one tap.
  Future<void> _editAllergies(BuildContext context, PatientAccount account) async {
    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) => _AllergyDialog(initial: account.allergies?.join(', ') ?? ''),
    );
    if (result == null) return;
    await AccountRepository.instance.updateAccount(account.copyWith(allergies: result));
  }

  Future<void> _editGuarantor(BuildContext context, PatientAccount account) async {
    final result = await showDialog<(Guarantor?,)>(context: context, builder: (_) => GuarantorDialog(initial: account.guarantor));
    if (result == null) return;
    await AccountRepository.instance.updateAccount(account.copyWith(guarantor: result.$1, clearGuarantor: result.$1 == null));
  }

  Future<void> _editLanguage(BuildContext context, PatientAccount account) async {
    final result = await showDialog<(String, bool)>(
      context: context,
      builder: (_) => LanguageDialog(language: account.preferredLanguage, interpreter: account.interpreterNeeded),
    );
    if (result == null) return;
    await AccountRepository.instance.updateAccount(account.copyWith(preferredLanguage: result.$1, interpreterNeeded: result.$2));
  }

  Widget _row(BuildContext context, String label, String value, {bool copy = false, bool missing = false}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 330;
        final labelText = Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant));
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!narrow) SizedBox(width: 120, child: labelText),
              Expanded(
                child: narrow
                    ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [labelText, _value(theme, value, missing)])
                    : _value(theme, value, missing),
              ),
              if (copy)
                IconButton(
                  tooltip: 'Copy $label',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.content_copy_rounded, size: 18),
                  onPressed: () {
                    PhiClipboard.copy(value);
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(content: Text('$label copied')));
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _value(ThemeData theme, String value, bool missing) => Text(
    value,
    style: theme.textTheme.bodyLarge?.copyWith(
      color: missing ? SolisTheme.onTint(SolisTheme.warning, isDark: widget.isDark) : null,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );
}

class _VisitTile extends StatelessWidget {
  final Visit visit;
  final VoidCallback onTap;

  const _VisitTile({required this.visit, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Visit ${visit.number}', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    '${formatDos(visit.dateOfService)}  |  ${placeOfService(visit.placeOfService).label}',
                    style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            VisitStatusTag(status: visit.status),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// Allergies as free text; owns its controller so it lives as long as the
/// dialog, including its closing animation.
class _AllergyDialog extends StatefulWidget {
  final String initial;
  const _AllergyDialog({required this.initial});

  @override
  State<_AllergyDialog> createState() => _AllergyDialogState();
}

class _AllergyDialogState extends State<_AllergyDialog> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Allergies'),
        content: TextField(
          controller: _c,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Allergies and reactions', hintText: 'Penicillin (hives), latex'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, const <String>[]), child: const Text('No known allergies')),
          FilledButton(onPressed: () => Navigator.pop(context, parseAllergies(_c.text)), child: const Text('Save')),
        ],
      );
}

/// Languages most often needed in US clinics, offered first.
const commonLanguages = [
  'English', 'Spanish', 'Chinese (Mandarin)', 'Chinese (Cantonese)', 'Vietnamese', 'Tagalog', 'Arabic', 'Korean',
  'Russian', 'French', 'Haitian Creole', 'Portuguese', 'Hindi', 'Polish', 'Japanese', 'American Sign Language',
];

/// Picks the preferred language and whether an interpreter is needed.
/// Pops with (language, interpreter); an empty language clears it.
class LanguageDialog extends StatefulWidget {
  final String? language;
  final bool interpreter;

  const LanguageDialog({super.key, this.language, this.interpreter = false});

  @override
  State<LanguageDialog> createState() => _LanguageDialogState();
}

class _LanguageDialogState extends State<LanguageDialog> {
  late final _c = TextEditingController(text: widget.language ?? '');
  late bool _interpreter = widget.interpreter;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Language'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('language_text'),
                controller: _c,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Preferred language'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final l in commonLanguages.take(8))
                    ChoiceChip(
                      label: Text(l),
                      selected: _c.text.trim().toLowerCase() == l.toLowerCase(),
                      onSelected: (_) => setState(() {
                        _c.text = l;
                        if (l != 'English') _interpreter = true;
                      }),
                    ),
                ],
              ),
              SwitchListTile(
                key: const Key('interpreter_switch'),
                contentPadding: EdgeInsets.zero,
                value: _interpreter,
                onChanged: (v) => setState(() => _interpreter = v),
                title: const Text('Interpreter needed'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const Key('language_save'), onPressed: () => Navigator.pop(context, (_c.text.trim(), _interpreter)), child: const Text('Save')),
        ],
      );
}

/// Records the responsible party. Pops with (guarantor,) or (null,) to
/// remove it.
class GuarantorDialog extends StatefulWidget {
  final Guarantor? initial;

  const GuarantorDialog({super.key, this.initial});

  @override
  State<GuarantorDialog> createState() => _GuarantorDialogState();
}

class _GuarantorDialogState extends State<GuarantorDialog> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _phone = TextEditingController(text: widget.initial?.phone ?? '');
  late String _relationship = widget.initial?.relationship ?? 'parent';
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter their name');
      return;
    }
    final phone = _phone.text.trim();
    Navigator.pop(context, (Guarantor(name: name, relationship: _relationship, phone: phone.isEmpty ? null : phone),));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Responsible party'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('guarantor_name'),
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(labelText: 'Full name', errorText: _error),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final e in Guarantor.relationships.entries)
                    ChoiceChip(label: Text(e.value), selected: _relationship == e.key, onSelected: (_) => setState(() => _relationship = e.key)),
                ],
              ),
              TextField(
                key: const Key('guarantor_phone'),
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone'),
              ),
            ],
          ),
        ),
        actions: [
          if (widget.initial != null) TextButton(onPressed: () => Navigator.pop(context, (null,)), child: const Text('Remove')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const Key('guarantor_save'), onPressed: _save, child: const Text('Save')),
        ],
      );
}
