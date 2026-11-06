import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/patient_account.dart';
import '../services/account_repository.dart';
import '../services/card_parser.dart';
import '../services/card_scanner.dart';
import '../theme/solis_theme.dart';
import '../widgets/encounter_widgets.dart';
import 'patients_screen.dart';

/// Scan an insurance card, driver's license or Social Security card, review
/// what was read, then create the patient account (or add the card to an
/// existing one). Several cards can be scanned into one review.
class ScanCardScreen extends StatefulWidget {
  /// Skip the camera and show an empty form.
  final bool manualEntry;

  /// Add the scanned card to this account instead of creating a new one.
  final String? existingAccountNumber;

  /// Test hook: results to use instead of the camera.
  @visibleForTesting
  final ScannedIdentity? preview;

  const ScanCardScreen({super.key, this.manualEntry = false, this.existingAccountNumber, this.preview});

  @override
  State<ScanCardScreen> createState() => _ScanCardScreenState();
}

class _ScanCardScreenState extends State<ScanCardScreen> {
  final _formKey = GlobalKey<FormState>();
  final _scanner = CardScanner();
  CardType _type = CardType.insurance;
  bool _scanning = false;
  ScannedIdentity _scanned = const ScannedIdentity();
  bool _showForm = false;
  String? _matchChoice; // account number, or 'new'
  final _matchKey = GlobalKey();

  DateTime? _dob;
  PatientSex _sex = PatientSex.unknown;
  String _relationship = 'self';
  String? _ssnLast4;

  late final Map<String, TextEditingController> _c = {
    for (final k in const [
      'first', 'middle', 'last', 'address', 'city', 'state', 'zip', 'phone', 'dl', 'dlState',
      'payer', 'memberId', 'group', 'planType', 'payerId', 'subscriber', 'rxBin', 'rxPcn', 'rxGroup',
    ])
      k: TextEditingController(),
  };

  AccountRepository get _repo => AccountRepository.instance;
  PatientAccount? get _existing => widget.existingAccountNumber == null ? null : _repo.byNumber(widget.existingAccountNumber!);

  @override
  void initState() {
    super.initState();
    final existing = _existing;
    if (existing != null) {
      _fillFromAccount(existing);
    }
    if (widget.preview != null) {
      _apply(widget.preview!, authoritative: false);
    }
    _showForm = widget.manualEntry || widget.preview != null || existing != null;
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _fillFromAccount(PatientAccount a) {
    _c['first']!.text = a.firstName;
    _c['middle']!.text = a.middleName ?? '';
    _c['last']!.text = a.lastName;
    _c['address']!.text = a.addressLine1 ?? '';
    _c['city']!.text = a.city ?? '';
    _c['state']!.text = a.state ?? '';
    _c['zip']!.text = a.zip ?? '';
    _c['phone']!.text = a.phone ?? '';
    _c['dl']!.text = a.driverLicenseNumber ?? '';
    _c['dlState']!.text = a.driverLicenseState ?? '';
    _dob = a.dateOfBirth;
    _sex = a.sex;
    _ssnLast4 = a.ssnLast4;
    final ins = a.insurance;
    if (ins != null) {
      _c['payer']!.text = ins.payerName;
      _c['memberId']!.text = ins.memberId;
      _c['group']!.text = ins.groupNumber ?? '';
      _c['planType']!.text = ins.planType ?? '';
      _c['payerId']!.text = ins.payerId ?? '';
      _c['subscriber']!.text = ins.subscriberName ?? '';
      _c['rxBin']!.text = ins.rxBin ?? '';
      _c['rxPcn']!.text = ins.rxPcn ?? '';
      _c['rxGroup']!.text = ins.rxGroup ?? '';
      _relationship = ins.relationship;
    }
  }

  /// Copies scanned values into the form. Empty form fields are filled;
  /// a license barcode also overwrites demographic fields read by OCR.
  void _apply(ScannedIdentity id, {required bool authoritative}) {
    void put(String key, String? value) {
      if (value == null || value.trim().isEmpty) return;
      if (authoritative || _c[key]!.text.trim().isEmpty) _c[key]!.text = value.trim();
    }

    put('first', id.firstName);
    put('middle', id.middleName);
    put('last', id.lastName);
    put('address', id.addressLine1);
    put('city', id.city);
    put('state', id.state);
    put('zip', id.zip);
    put('dl', id.licenseNumber);
    put('dlState', id.licenseState);
    put('payer', id.payerName);
    put('memberId', id.memberId);
    put('group', id.groupNumber);
    put('planType', id.planType);
    put('payerId', id.payerId);
    put('subscriber', id.subscriberName);
    put('rxBin', id.rxBin);
    put('rxPcn', id.rxPcn);
    put('rxGroup', id.rxGroup);
    if (id.dateOfBirth != null && (authoritative || _dob == null)) _dob = id.dateOfBirth;
    if (id.sex != null && id.sex != PatientSex.unknown && (authoritative || _sex == PatientSex.unknown)) _sex = id.sex!;
    if (id.ssnLast4 != null) _ssnLast4 = id.ssnLast4;
    _scanned = _scanned.merge(id, otherIsAuthoritative: authoritative);
  }

  Future<void> _scan({bool fromGallery = false, bool demo = false}) async {
    setState(() => _scanning = true);
    try {
      final result = demo ? await _scanner.scanDemo(_type) : await _scanner.scan(_type, fromGallery: fromGallery);
      if (!mounted) return;
      if (result == null) return;
      if (result.identity.isEmpty) {
        _message('Nothing readable on that card. Hold it flat, fill the frame, and avoid glare.');
        return;
      }
      HapticFeedback.mediumImpact();
      setState(() {
        _apply(result.identity, authoritative: result.usedBarcode);
        _showForm = true;
        _matchChoice = null;
        if (_existing == null) {
          _matchChoice = strongMatch(
            _repo.findMatches(memberId: _t('memberId'), firstName: _t('first'), lastName: _t('last'), dateOfBirth: _dob),
            memberId: _t('memberId'),
            dateOfBirth: _dob,
          )?.accountNumber;
        }
      });
      _message(demo
          ? 'Sample ${cardTypeLabel(_type).toLowerCase()} read on this phone. Check the details below.'
          : result.usedBarcode
              ? 'License barcode read. Check the details below.'
              : '${cardTypeLabel(_type)} read. Check the details below.');
    } catch (e) {
      if (mounted) _message('The card could not be read on this device: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  String? _t(String key) {
    final v = _c[key]!.text.trim();
    return v.isEmpty ? null : v;
  }

  InsuranceCoverage? _coverage() {
    final payer = _t('payer');
    final member = _t('memberId');
    if (payer == null && member == null) return null;
    final copays = _existing?.insurance?.copays ?? const <String, String>{};
    return InsuranceCoverage(
      payerName: payer ?? '',
      memberId: member ?? '',
      groupNumber: _t('group'),
      planType: _t('planType'),
      payerId: _t('payerId'),
      subscriberName: _t('subscriber'),
      relationship: _relationship,
      rxBin: _t('rxBin'),
      rxPcn: _t('rxPcn'),
      rxGroup: _t('rxGroup'),
      copays: {...copays, ..._scanned.copays},
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final possible = _existing != null ? const [] : _repo.findMatches(memberId: _t('memberId'), firstName: _t('first'), lastName: _t('last'), dateOfBirth: _dob);
    if (possible.isNotEmpty && _matchChoice == null) {
      HapticFeedback.lightImpact();
      final panel = _matchKey.currentContext;
      if (panel != null) unawaited(Scrollable.ensureVisible(panel, duration: const Duration(milliseconds: 300), alignment: 0.05));
      _message('This looks like an existing patient. Choose their account or Create a new account.');
      return;
    }

    final existing = _existing ?? (_matchChoice != null && _matchChoice != 'new' ? _repo.byNumber(_matchChoice!) : null);
    PatientAccount saved;
    if (existing != null) {
      saved = existing.copyWith(
        firstName: _t('first'),
        middleName: _t('middle'),
        lastName: _t('last'),
        dateOfBirth: _dob,
        sex: _sex == PatientSex.unknown ? null : _sex,
        addressLine1: _t('address'),
        city: _t('city'),
        state: _t('state'),
        zip: _t('zip'),
        phone: _t('phone'),
        driverLicenseNumber: _t('dl'),
        driverLicenseState: _t('dlState'),
        ssnLast4: _ssnLast4,
        insurance: _coverage(),
      );
      await _repo.updateAccount(saved);
    } else {
      saved = await _repo.createAccount(
        firstName: _t('first')!,
        middleName: _t('middle'),
        lastName: _t('last')!,
        dateOfBirth: _dob,
        sex: _sex,
        addressLine1: _t('address'),
        city: _t('city'),
        state: _t('state'),
        zip: _t('zip'),
        phone: _t('phone'),
        driverLicenseNumber: _t('dl'),
        driverLicenseState: _t('dlState'),
        ssnLast4: _ssnLast4,
        insurance: _coverage(),
      );
    }
    if (!mounted) return;
    Navigator.pop(context, saved);
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 40),
      firstDate: DateTime(1900),
      lastDate: now,
      initialEntryMode: DatePickerEntryMode.input,
      helpText: 'Date of birth',
    );
    if (picked != null) setState(() => _dob = picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final existing = _existing;
    final matches = existing != null || !_showForm
        ? const <PatientAccount>[]
        : _repo.findMatches(memberId: _t('memberId'), firstName: _t('first'), lastName: _t('last'), dateOfBirth: _dob);

    final title = existing != null ? 'Update ${existing.firstName}' : (widget.manualEntry ? 'New patient' : 'Scan card');

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        top: false,
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              if (!widget.manualEntry) ...[
                _ScanPanel(
                  type: _type,
                  scanning: _scanning,
                  onType: (t) => setState(() => _type = t),
                  onCamera: () => _scan(),
                  onGallery: () => _scan(fromGallery: true),
                  // Sample cards only in demo mode, so a real chart never starts from fiction.
                  onDemo: _repo.demoMode ? () => _scan(demo: true) : null,
                ),
                if (_scanned.sources.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final s in _scanned.sources) StatusTag(label: s, color: SolisTheme.success, icon: Icons.check_rounded),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
              ],
              if (_showForm) ...[
                if (matches.isNotEmpty) ...[
                  _MatchPanel(
                    key: _matchKey,
                    matches: matches,
                    choice: _matchChoice,
                    onChoice: (c) => setState(() => _matchChoice = c),
                  ),
                  const SizedBox(height: 16),
                ],
                _section(context, 'Patient', Icons.person_outline),
                Row(
                  children: [
                    Expanded(child: _field('first', 'First name', required: true, caps: TextCapitalization.words)),
                    const SizedBox(width: 12),
                    Expanded(child: _field('last', 'Last name', required: true, caps: TextCapitalization.words)),
                  ],
                ),
                const SizedBox(height: 12),
                _field('middle', 'Middle name', caps: TextCapitalization.words),
                const SizedBox(height: 12),
                InkWell(
                  onTap: _pickDob,
                  borderRadius: BorderRadius.circular(SolisTheme.radiusMd),
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Date of birth', prefixIcon: Icon(Icons.cake_outlined), suffixIcon: Icon(Icons.edit_calendar_outlined)),
                    child: Text(
                      _dob == null ? 'Not set' : '${formatDate(_dob)}  (age ${_age(_dob!)})',
                      style: theme.textTheme.bodyLarge?.copyWith(color: _dob == null ? cs.onSurfaceVariant : null),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text('Sex (as on the insurance record)', style: theme.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<PatientSex>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: PatientSex.female, label: Text('Female')),
                      ButtonSegment(value: PatientSex.male, label: Text('Male')),
                      ButtonSegment(value: PatientSex.unknown, label: Text('Unknown')),
                    ],
                    selected: {_sex},
                    onSelectionChanged: (s) => setState(() => _sex = s.first),
                  ),
                ),
                const SizedBox(height: 12),
                _field('address', 'Street address', caps: TextCapitalization.words),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(flex: 5, child: _field('city', 'City', caps: TextCapitalization.words)),
                    const SizedBox(width: 12),
                    Expanded(flex: 3, child: _field('state', 'State', caps: TextCapitalization.characters)),
                    const SizedBox(width: 12),
                    Expanded(flex: 3, child: _field('zip', 'ZIP', keyboard: TextInputType.number)),
                  ],
                ),
                const SizedBox(height: 12),
                _field('phone', 'Phone', keyboard: TextInputType.phone),
                const SizedBox(height: 24),
                _section(context, 'Insurance', Icons.health_and_safety_outlined),
                _field('payer', 'Payer', caps: TextCapitalization.words),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: _field('memberId', 'Member ID', caps: TextCapitalization.characters)),
                    const SizedBox(width: 12),
                    Expanded(child: _field('group', 'Group number', caps: TextCapitalization.characters)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: _field('planType', 'Plan type')),
                    const SizedBox(width: 12),
                    Expanded(child: _field('payerId', 'Payer ID (EDI)', caps: TextCapitalization.characters)),
                  ],
                ),
                const SizedBox(height: 12),
                _field('subscriber', 'Subscriber name', caps: TextCapitalization.words),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _relationship,
                  decoration: const InputDecoration(labelText: 'Patient relationship to subscriber'),
                  items: const [
                    DropdownMenuItem(value: 'self', child: Text('Self')),
                    DropdownMenuItem(value: 'spouse', child: Text('Spouse')),
                    DropdownMenuItem(value: 'child', child: Text('Child')),
                    DropdownMenuItem(value: 'other', child: Text('Other')),
                  ],
                  onChanged: (v) => setState(() => _relationship = v ?? 'self'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: _field('rxBin', 'Rx BIN', keyboard: TextInputType.number)),
                    const SizedBox(width: 12),
                    Expanded(child: _field('rxPcn', 'Rx PCN', caps: TextCapitalization.characters)),
                    const SizedBox(width: 12),
                    Expanded(child: _field('rxGroup', 'Rx group', caps: TextCapitalization.characters)),
                  ],
                ),
                if (_scanned.copays.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Copays on card: ${_scanned.copays.entries.map((e) => '${e.key} ${e.value}').join(', ')}',
                    style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
                const SizedBox(height: 24),
                _section(context, 'Identity documents', Icons.badge_outlined),
                Row(
                  children: [
                    Expanded(flex: 3, child: _field('dl', "Driver's license number", caps: TextCapitalization.characters)),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: _field('dlState', 'State', caps: TextCapitalization.characters)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.lock_outline, size: 20, color: cs.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _ssnLast4 == null
                            ? 'No Social Security number on file. Only the last 4 digits are ever kept.'
                            : 'SSN on file: last 4 digits $_ssnLast4. The full number is not stored.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.check_rounded),
                  label: Text(
                    existing != null
                        ? 'Save to ${existing.accountNumber}'
                        : (_matchChoice != null && _matchChoice != 'new' ? 'Update existing account' : 'Create account'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  int _age(DateTime dob) {
    final now = DateTime.now();
    var a = now.year - dob.year;
    if (now.month < dob.month || (now.month == dob.month && now.day < dob.day)) a--;
    return a;
  }

  Widget _section(BuildContext context, String title, IconData icon) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(title, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
        ],
      ),
    );
  }

  Widget _field(String key, String label, {bool required = false, TextInputType? keyboard, TextCapitalization caps = TextCapitalization.none}) {
    return TextFormField(
      controller: _c[key],
      keyboardType: keyboard,
      textCapitalization: caps,
      onChanged: (_) {
        if (key == 'memberId' || key == 'first' || key == 'last') setState(() {});
      },
      decoration: InputDecoration(labelText: required ? '$label (required)' : label),
      validator: required ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null : null,
    );
  }
}

class _ScanPanel extends StatelessWidget {
  final CardType type;
  final bool scanning;
  final ValueChanged<CardType> onType;
  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback? onDemo;

  const _ScanPanel({
    required this.type,
    required this.scanning,
    required this.onType,
    required this.onCamera,
    required this.onGallery,
    this.onDemo,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = switch (type) {
      CardType.insurance => 'Scan the front, then the back. The scanner finds the card edges and straightens it. The back usually has Rx BIN, PCN and the payer ID.',
      CardType.driverLicense => 'Scan the back with the barcode. It holds the exact name, date of birth, sex and address. Add the front too if the barcode is worn.',
      CardType.ssnCard => 'Only the name and the last 4 digits are kept. The full number is never stored.',
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<CardType>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: CardType.insurance, label: Text('Insurance')),
                ButtonSegment(value: CardType.driverLicense, label: Text('License')),
                ButtonSegment(value: CardType.ssnCard, label: Text('SSN')),
              ],
              selected: {type},
              onSelectionChanged: (s) => onType(s.first),
            ),
            const SizedBox(height: 12),
            Text(hint, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            if (scanning)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onCamera,
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Scan'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onGallery,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('From photos'),
                    ),
                  ),
                ],
              ),
            if (!scanning && onDemo != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onDemo,
                  icon: const Icon(Icons.badge_outlined),
                  label: const Text('Try a sample card'),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.phonelink_lock_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Read on this phone. The photo is deleted after reading.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MatchPanel extends StatelessWidget {
  final List<PatientAccount> matches;
  final String? choice;
  final ValueChanged<String> onChoice;

  const _MatchPanel({super.key, required this.matches, required this.choice, required this.onChoice});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget option(String value, String title, String subtitle) {
      final selected = choice == value;
      return Card(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SolisTheme.radiusMd),
          side: BorderSide(color: selected ? theme.colorScheme.primary : theme.colorScheme.outlineVariant, width: selected ? 2 : 1),
        ),
        child: ListTile(
          onTap: () => onChoice(value),
          leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: selected ? theme.colorScheme.primary : null),
          title: Text(title),
          subtitle: Text(subtitle),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NoteBanner(
          icon: Icons.people_alt_outlined,
          title: 'This may be an existing patient',
          message: 'Add the card to their account to keep one chart per person.',
          color: SolisTheme.warning,
        ),
        const SizedBox(height: 8),
        for (final m in matches)
          option(m.accountNumber, 'Add to ${m.fullName}${choice == m.accountNumber ? ' (selected)' : ''}', '${m.accountNumber}  |  ${formatDate(m.dateOfBirth)}  |  ${m.visits.length} visits'),
        option('new', 'Create a new account', 'Only if this is a different person'),
      ],
    );
  }
}

/// The one existing chart a scanned card clearly belongs to: the only match
/// with the same member ID, or else the only match with the same name and
/// date of birth. Null when there is none or more than one, so the person
/// at the desk chooses.
PatientAccount? strongMatch(List<PatientAccount> matches, {String? memberId, DateTime? dateOfBirth}) {
  String n(String? s) => (s ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (n(memberId).length >= 5) {
    final byId = matches.where((m) => n(m.insurance?.memberId) == n(memberId)).toList();
    if (byId.length == 1) return byId.single;
    if (byId.length > 1) return null;
  }
  if (dateOfBirth == null) return null;
  final byDob = matches
      .where((m) => m.dateOfBirth != null && m.dateOfBirth!.year == dateOfBirth.year && m.dateOfBirth!.month == dateOfBirth.month && m.dateOfBirth!.day == dateOfBirth.day)
      .toList();
  return byDob.length == 1 ? byDob.single : null;
}
