import 'dart:async';

import 'package:flutter/material.dart';

import '../models/provider_profile.dart';
import '../services/account_repository.dart';
import '../services/app_session.dart';
import '../services/auth_service.dart';
import '../services/security_and_background_service.dart';
import '../services/coding/place_of_service.dart';
import '../services/npi_registry.dart';
import '../widgets/account_section.dart';
import 'charge_master_screen.dart';

/// Looks up an NPI in NPPES. Tests pass a fake.
typedef NpiLookup = Future<NpiRecord?> Function(String npi);

/// The physician's billing identity: name, NPI, tax ID, taxonomy, practice
/// address and the payers they are credentialed with. Every claim uses it.
///
/// With [firstRun] it is the "Set up your practice" step a new clinician
/// completes before patients or claims: no back button, the NPI from sign-up
/// is looked up in NPPES on open, and Save continues to the home screen.
class ProviderProfileScreen extends StatefulWidget {
  final bool firstRun;
  final NpiLookup? npiLookup;

  const ProviderProfileScreen({super.key, this.firstRun = false, this.npiLookup});

  @override
  State<ProviderProfileScreen> createState() => _ProviderProfileScreenState();
}

class _ProviderProfileScreenState extends State<ProviderProfileScreen> {
  static const _payerOptions = [
    'Aetna', 'Blue Cross Blue Shield', 'Cigna', 'Humana', 'Kaiser Permanente', 'Medicaid', 'Medicare', 'Molina Healthcare',
    'TRICARE', 'UnitedHealthcare', 'WellCare', 'Oscar Health', 'Ambetter',
  ];

  AccountRepository get _repo => AccountRepository.instance;

  final _formKey = GlobalKey<FormState>();
  final _practiceFocus = FocusNode();
  late ProviderProfile _p = _repo.provider;
  late final AuthUser? _user = AuthService.instance.user;
  late final Map<String, TextEditingController> _c = {
    'fullName': TextEditingController(text: _p.fullName.isEmpty ? (_user?.fullName ?? '') : _p.fullName),
    'credentials': TextEditingController(text: _p.credentials),
    'npi': TextEditingController(text: _p.npi.isEmpty ? (_user?.npi ?? '') : _p.npi),
    'groupNpi': TextEditingController(text: _p.groupNpi ?? ''),
    'taxId': TextEditingController(text: _p.taxId),
    'practiceName': TextEditingController(text: _p.practiceName),
    'address': TextEditingController(text: _p.addressLine1),
    'city': TextEditingController(text: _p.city),
    'state': TextEditingController(text: _p.state),
    'zip': TextEditingController(text: _p.zip),
    'phone': TextEditingController(text: _p.phone),
    'customPayer': TextEditingController(),
  };
  // Known specialties plus whatever the NPI registry or a saved profile adds.
  late final Map<String, String> _specialties = {
    ...specialtyTaxonomy,
    if (_p.specialty.isNotEmpty && _p.taxonomyCode.isNotEmpty) _p.specialty: _p.taxonomyCode,
  };
  late String? _specialty = _specialties.containsKey(_p.specialty) ? _p.specialty : null;
  late bool _enforceSexEdits = _p.enforceSexEdits;
  late bool _blockScreenshots = _p.blockScreenshots;
  late bool _preferOnDevice = _p.preferOnDevice;
  late List<SavedPlace> _places = [..._p.savedPlaces];
  late String _pos = _p.defaultPlaceOfService;
  late final Set<String> _payers = {..._p.acceptedPayers};
  bool _lookingUp = false;
  String? _lookedUpNpi;
  Timer? _npiDebounce;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // The NPI given at sign-up fills the form from NPPES straight away.
    if (widget.firstRun && isValidNpi(_c['npi']!.text.trim()) && _c['practiceName']!.text.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _lookupNpi(quiet: true);
      });
    }
  }

  @override
  void dispose() {
    _npiDebounce?.cancel();
    _practiceFocus.dispose();
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onNpiChanged(String value) {
    setState(() {});
    _npiDebounce?.cancel();
    final npi = value.trim();
    if (!isValidNpi(npi) || npi == _lookedUpNpi) return;
    // A complete, valid NPI is looked up on its own after a short pause.
    _npiDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _lookupNpi(quiet: true);
    });
  }

  /// Fills the form from the public NPPES NPI Registry.
  Future<void> _lookupNpi({bool quiet = false}) async {
    final npi = _c['npi']!.text.trim();
    if (!isValidNpi(npi)) {
      if (!quiet) _message('Enter a valid 10-digit NPI first.');
      return;
    }
    if (_lookingUp) return;
    setState(() => _lookingUp = true);
    try {
      final r = await (widget.npiLookup ?? NpiRegistry().lookup)(npi);
      if (!mounted) return;
      _lookedUpNpi = npi;
      if (r == null) {
        _message('No provider found for NPI $npi in the NPPES registry. Fill in your details below.');
        return;
      }
      setState(() {
        if (r.isOrganization) {
          if (r.organizationName != null) _c['practiceName']!.text = r.organizationName!;
          _c['groupNpi']!.text = r.npi;
        } else {
          final name = r.displayName;
          if (name.isNotEmpty) _c['fullName']!.text = name;
          if (r.credential != null && r.credential!.isNotEmpty) _c['credentials']!.text = r.credential!;
          // An individual record has no practice name; an organization name
          // on the record (sole proprietors) is used when present.
          if (r.organizationName != null && _c['practiceName']!.text.trim().isEmpty) _c['practiceName']!.text = r.organizationName!;
        }
        if (r.addressLine1 != null) _c['address']!.text = r.addressLine1!;
        if (r.city != null) _c['city']!.text = r.city!;
        if (r.state != null) _c['state']!.text = r.state!;
        if (r.zip != null) _c['zip']!.text = r.zip!;
        if (r.phone != null) _c['phone']!.text = r.phone!;
        if (r.taxonomyCode != null) {
          final known = _specialties.entries.where((e) => e.value == r.taxonomyCode).map((e) => e.key).toList();
          if (known.isNotEmpty) {
            _specialty = known.first;
          } else {
            final label = r.taxonomyDescription ?? r.taxonomyCode!;
            _specialties[label] = r.taxonomyCode!;
            _specialty = label;
          }
        }
      });
      if (_c['practiceName']!.text.trim().isEmpty) _practiceFocus.requestFocus();
      _message(r.active ? 'Filled from the NPI Registry. Check the details and add your tax ID.' : 'This NPI is marked deactivated in the registry.');
    } catch (e) {
      if (mounted && !quiet) _message('Could not reach the NPI Registry: $e');
      if (mounted && quiet) _message('Could not reach the NPI Registry. Fill in your details, or tap Look up again.');
    } finally {
      if (mounted) setState(() => _lookingUp = false);
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _save() async {
    // A double tap must not save twice and pop the screen under this one.
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) {
      _message('Some details are missing or invalid. They are marked in red.');
      return;
    }
    _saving = true;
    String t(String k) => _c[k]!.text.trim();
    _p = _p.copyWith(
      fullName: t('fullName'),
      credentials: t('credentials'),
      npi: t('npi'),
      groupNpi: t('groupNpi').isEmpty ? null : t('groupNpi'),
      taxId: t('taxId'),
      specialty: _specialty,
      taxonomyCode: _specialty == null ? null : _specialties[_specialty],
      enforceSexEdits: _enforceSexEdits,
      blockScreenshots: _blockScreenshots,
      preferOnDevice: _preferOnDevice,
      savedPlaces: _places,
      practiceName: t('practiceName'),
      addressLine1: t('address'),
      city: t('city'),
      state: t('state').toUpperCase(),
      zip: t('zip'),
      phone: t('phone'),
      defaultPlaceOfService: _pos,
      acceptedPayers: _payers.toList()..sort(),
    );
    await _repo.saveProvider(_p);
    // The platform call must not hold up leaving the screen.
    unawaited(SecurityAndBackgroundService.setScreenshotsBlocked(_p.blockScreenshots));
    if (!mounted) return;
    if (widget.firstRun) {
      Navigator.of(context).pushNamedAndRemoveUntil(AppSession.homeRoute, (_) => false);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Provider profile saved. New claims use it.')));
    Navigator.pop(context);
  }

  /// Prices are saved as soon as the charge master closes, so they do not
  /// wait on the rest of the form.
  Future<void> _openChargeMaster() async {
    final fees = await Navigator.push<Map<String, double>>(
      context,
      MaterialPageRoute(builder: (_) => ChargeMasterScreen(fees: _p.feeSchedule)),
    );
    if (fees == null || !mounted) return;
    await _repo.saveProvider(_repo.provider.copyWith(feeSchedule: fees));
    if (!mounted) return;
    setState(() => _p = _p.copyWith(feeSchedule: fees));
    _message('Prices saved. New claim lines use them.');
  }

  Future<void> _signOut() async {
    final nav = Navigator.of(context);
    await AuthService.instance.signOut();
    nav.pushNamedAndRemoveUntil(AppSession.loginRoute, (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final npiOk = isValidNpi(_c['npi']!.text.trim());
    final demo = _repo.demoMode;

    return PopScope(
      // Setup cannot be skipped: claims need a real billing identity.
      canPop: !widget.firstRun,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !widget.firstRun,
          title: Text(widget.firstRun ? 'Set up your practice' : 'Provider profile'),
          actions: [
            if (widget.firstRun)
              TextButton(key: const Key('setup_sign_out'), onPressed: _signOut, child: const Text('Sign out')),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              height: 52,
              child: FilledButton(
                key: const Key('profile_save'),
                onPressed: _save,
                child: Text(widget.firstRun ? 'Save and continue' : 'Save profile'),
              ),
            ),
          ),
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              if (widget.firstRun) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.badge_outlined, color: cs.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Claims carry your NPI, tax ID and practice address. Enter your NPI and SOLIS fills the rest it can from the '
                        'national NPI Registry. Patients and claims open once this is saved.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ] else
                Text(
                  'These details go on every claim: rendering provider (box 24J), tax ID (box 25) and billing provider (box 33).',
                  style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              const SizedBox(height: 20),
              _section(context, 'Clinician'),
              TextFormField(
                key: const Key('profile_npi'),
                controller: _c['npi'],
                keyboardType: TextInputType.number,
                maxLength: 10,
                onChanged: _onNpiChanged,
                decoration: InputDecoration(
                  labelText: 'Individual NPI',
                  counterText: '',
                  helperText: npiOk ? 'Valid NPI. Details are filled in from NPPES.' : '10 digits, from NPPES',
                  suffixIcon: _lookingUp
                      ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                      : TextButton(onPressed: npiOk ? _lookupNpi : null, child: Text(_lookedUpNpi == null ? 'Look up' : 'Look up again')),
                ),
                validator: (v) {
                  final t = (v ?? '').trim();
                  if (!isValidNpi(t)) return 'Enter a valid 10-digit NPI';
                  if (!demo && t == ProviderProfile.demoNpi) return 'This is the demo NPI. Enter your own.';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(flex: 3, child: _field('fullName', 'Full name', required: true)),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: _field('credentials', 'Credentials', hint: 'MD, DO, NP')),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                // Rebuilt when an NPI lookup picks the specialty, since a form
                // field reads its initial value only once.
                key: ValueKey('profile_specialty_$_specialty'),
                initialValue: _specialty,
                isExpanded: true,
                hint: const Text('Choose your specialty'),
                decoration: const InputDecoration(labelText: 'Specialty'),
                items: [for (final s in _specialties.keys) DropdownMenuItem(value: s, child: Text('$s  (${_specialties[s]})', overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setState(() => _specialty = v ?? _specialty),
                validator: (v) => v == null ? 'Choose a specialty (it sets the taxonomy code)' : null,
              ),
              const SizedBox(height: 24),
              _section(context, 'Practice and billing'),
              _field('practiceName', 'Practice name', required: true, focusNode: _practiceFocus),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('profile_tax_id'),
                controller: _c['taxId'],
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Tax ID (EIN)', hintText: '12-3456789'),
                validator: (v) {
                  if (!isValidEin(v ?? '')) return 'Format NN-NNNNNNN';
                  if (!demo && (v ?? '').trim() == ProviderProfile.demoTaxId) return 'This is the demo tax ID. Enter your own.';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _c['groupNpi'],
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Group NPI (optional)'),
                validator: (v) => (v == null || v.trim().isEmpty || isValidNpi(v.trim())) ? null : 'Invalid NPI',
              ),
              const SizedBox(height: 12),
              _field('address', 'Street address', required: true),
              const SizedBox(height: 12),
              _field('city', 'City', required: true),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _c['state'],
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 2,
                      decoration: const InputDecoration(labelText: 'State', counterText: ''),
                      validator: (v) => RegExp(r'^[A-Za-z]{2}$').hasMatch((v ?? '').trim()) ? null : '2 letters',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _c['zip'],
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'ZIP'),
                      validator: (v) {
                        final d = (v ?? '').replaceAll(RegExp(r'[^0-9]'), '');
                        return d.length == 5 || d.length == 9 ? null : '5 or 9 digits';
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _c['phone'],
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _pos,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Usual place of service'),
                items: [for (final p in placesOfService) DropdownMenuItem(value: p.code, child: Text(p.label, overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setState(() => _pos = v ?? _pos),
              ),
              const SizedBox(height: 24),
              _section(context, 'Insurance you accept'),
              Text(
                'Patients with other payers are flagged as possibly out of network before you bill.',
                style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in {..._payerOptions, ..._payers}.toList()..sort())
                    FilterChip(
                      label: Text(p),
                      selected: _payers.contains(p),
                      onSelected: (v) => setState(() => v ? _payers.add(p) : _payers.remove(p)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _field('customPayer', 'Add another payer')),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Add payer',
                    icon: const Icon(Icons.add_rounded),
                    onPressed: () {
                      final v = _c['customPayer']!.text.trim();
                      if (v.isEmpty) return;
                      setState(() {
                        _payers.add(v);
                        _c['customPayer']!.clear();
                      });
                    },
                  ),
                ],
              ),
              if (!widget.firstRun) ...[
                const SizedBox(height: 24),
                _section(context, 'Your prices'),
                ListTile(
                  key: const Key('open_charge_master'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.price_change_outlined),
                  title: const Text('Charge master'),
                  subtitle: Text('${_p.feeSchedule.length} ${_p.feeSchedule.length == 1 ? 'code' : 'codes'} priced. New claim lines use these.'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _openChargeMaster,
                ),
                const SizedBox(height: 24),
                _section(context, 'Saved places'),
                if (_places.isEmpty)
                  Text(
                    'Save a place from Session details during a visit. Visits started there then use its place of service.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  )
                else
                  for (final p in _places)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.place_outlined),
                      title: Text(p.name),
                      subtitle: Text('${placeOfService(p.placeOfService).label}${p.address == null ? '' : '\n${p.address}'}'),
                      trailing: IconButton(
                        tooltip: 'Remove ${p.name}',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(() => _places = _places.where((x) => x.id != p.id).toList()),
                      ),
                    ),
                const SizedBox(height: 24),
                _section(context, 'On this phone'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _preferOnDevice,
                  onChanged: (v) => setState(() => _preferOnDevice = v),
                  title: const Text('Write notes on this phone'),
                  subtitle: const Text('Uses the on-device engine for every visit. Without a connection SOLIS uses it anyway.'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _enforceSexEdits,
                  onChanged: (v) => setState(() => _enforceSexEdits = v),
                  title: const Text('Block sex-specific code conflicts'),
                  subtitle: const Text('Most commercial payers deny these. Turn off to show them as warnings instead.'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _blockScreenshots,
                  onChanged: (v) => setState(() => _blockScreenshots = v),
                  title: const Text('Block screenshots'),
                  subtitle: const Text('Stops screenshots, screen recording and app previews on this phone. Recommended once real patients are seen.'),
                ),
                const SizedBox(height: 24),
                const AccountSection(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(title, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
    );
  }

  Widget _field(String key, String label, {bool required = false, String? hint, FocusNode? focusNode}) => TextFormField(
        key: Key('profile_$key'),
        controller: _c[key],
        focusNode: focusNode,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(labelText: label, hintText: hint),
        validator: required ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null : null,
      );
}
