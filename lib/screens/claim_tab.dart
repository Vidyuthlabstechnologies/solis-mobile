import 'dart:async';

import 'package:flutter/material.dart';

import '../models/ambulance_transport.dart';
import '../models/claim_models.dart';
import '../models/patient_account.dart';
import '../models/provider_profile.dart';
import '../services/account_repository.dart';
import '../services/auth_service.dart';
import '../services/billing/cms_edi_edits.dart';
import '../services/billing/eligibility_service.dart';
import '../services/billing/x12_837p.dart' show claimFilingIndicatorFor, isAmbulancePos, isAmbulanceMileageCode;
import '../services/codesets/reference_data.dart';
import '../services/coding/claim_scrubber.dart';
import '../services/coding/clinical_coder.dart';
import '../services/coding/em_time.dart';
import '../services/coding/place_of_service.dart';
import '../services/coding/recent_codes.dart';
import '../services/coding/service_catalog.dart';
import '../services/nlm_coding_service.dart';
import '../theme/solis_theme.dart';
import '../widgets/encounter_widgets.dart';
import '../widgets/knowledge_widgets.dart';
import 'patients_screen.dart';

const _pointers = 'ABCDEFGHIJKL';

/// A claim change. [undoLabel] (for removals and replacements) makes the
/// screen offer Undo, as DESIGN.md asks instead of a confirmation.
typedef ClaimChanged = void Function(ClaimDraft claim, {String? undoLabel});

/// Applies a diagnosis change and keeps the claim consistent: recomputes
/// which symptoms are folded into confirmed diagnoses, the order (honoring a
/// physician-chosen primary) and every line's diagnosis pointers.
///
/// [dateOfService] (the visit's) selects the ICD-10-CM edition whose code
/// first notes order the diagnoses.
ClaimDraft reconcileClaim(ClaimDraft claim,
    {List<ClaimDiagnosis>? diagnoses, List<ServiceLine>? lines, String? primaryCode, DateTime? dateOfService}) {
  final primary = primaryCode ?? claim.primaryCode;
  final dx = ReferenceData.atDateOfService(dateOfService,
      () => ClinicalCoder.finalizeDiagnoses(diagnoses ?? claim.diagnoses, pinnedOrder: primary == null ? const [] : [primary]));
  final billable = dx.where((d) => d.status == DxStatus.billable).toList();
  return ClaimDraft(
    diagnoses: dx,
    lines: ClinicalCoder.assignPointers(lines ?? claim.lines, billable),
    generatedAtUtc: claim.generatedAtUtc,
    primaryCode: primary,
  );
}

/// Replaces the E/M code of [lineIndex] with [code] of the same family. The
/// diagnosis pointers and modifiers stay; the charge comes from the fee
/// schedule and the evidence says the physician chose the level.
ClaimDraft changeEmLevel(ClaimDraft claim, int lineIndex, String code, Map<String, double> fees) {
  final line = claim.lines[lineIndex];
  final updated = line.copyWith(
    code: code,
    description: emDescription(code),
    charge: fees[code] ?? line.charge,
    evidence: 'Level chosen by physician (coded as ${line.code})',
  );
  return claim.copyWith(lines: [...claim.lines]..[lineIndex] = updated);
}

/// Bills the office E/M line by [minutes] of total time on the date of
/// service: sets the level the time supports and adds (or updates, or
/// removes) the prolonged-service line, 99417 or Medicare's G2212. Null
/// when the claim has no office E/M line or the time is below its lowest
/// level. The note must document the total time.
ClaimDraft? applyTotalTime(ClaimDraft claim, int minutes, Map<String, double> fees, {required bool medicare}) {
  final i = claim.lines.indexWhere((l) => isOfficeEm(l.code));
  if (i < 0) return null;
  final level = officeEmForTime(claim.lines[i].code, minutes);
  if (level == null) return null;
  final em = claim.lines[i].copyWith(
    code: level,
    description: emDescription(level),
    charge: level == claim.lines[i].code ? claim.lines[i].charge : fees[level] ?? claim.lines[i].charge,
    evidence: 'Level by total time on the date of service: $minutes minutes',
  );
  final p = prolongedFor(level, minutes, medicare: medicare);
  final lines = <ServiceLine>[
    for (var j = 0; j < claim.lines.length; j++)
      if (j == i) em else if (!prolongedCodes.contains(claim.lines[j].code)) claim.lines[j],
  ];
  if (p != null) {
    lines.insert(
      i + 1,
      ServiceLine(
        code: p.code,
        description: p.code == 'G2212' ? 'Prolonged office visit, each additional 15 minutes (Medicare)' : 'Prolonged office visit, each additional 15 minutes',
        units: p.units,
        charge: fees[p.code] ?? 0,
        diagnosisCodes: em.diagnosisCodes,
        evidence: 'Total time $minutes minutes',
      ),
    );
  }
  return claim.copyWith(lines: lines);
}

/// Applies a fix that changes the claim with no judgment left (replacing a
/// code the checks named, or adding a modifier they require). Returns null
/// when [fix] is not such a fix or no longer applies.
ClaimDraft? applyClaimFix(ClaimDraft claim, IssueFix fix, Map<String, double> fees, {DateTime? dateOfService}) {
  switch (fix.kind) {
    case FixKind.replaceDiagnosis:
      final from = fix.code, to = fix.replacement;
      if (from == null || to == null || !claim.diagnoses.any((d) => d.code == from)) return null;
      return reconcileClaim(
        claim,
        dateOfService: dateOfService,
        diagnoses: [
          for (final d in claim.diagnoses)
            d.code == from
                ? ClaimDiagnosis(code: to, description: d.description, source: d.source, status: d.status, evidence: d.evidence, note: 'Corrected from $from')
                : d,
        ],
        lines: [for (final l in claim.lines) l.copyWith(diagnosisCodes: [for (final c in l.diagnosisCodes) c == from ? to : c])],
        primaryCode: claim.primaryCode == from ? to : null,
      );
    case FixKind.replaceService:
      final i = claim.lines.indexWhere((l) => l.code == fix.code);
      if (i < 0 || fix.replacement == null) return null;
      return emSettingOf(fix.replacement!) != null
          ? changeEmLevel(claim, i, fix.replacement!, fees)
          : claim.copyWith(lines: [...claim.lines]..[i] = claim.lines[i].copyWith(code: fix.replacement, charge: fees[fix.replacement] ?? claim.lines[i].charge));
    case FixKind.addService:
      final code = fix.replacement;
      final anchor = claim.lines.indexWhere((l) => l.code == fix.code);
      if (code == null || anchor < 0 || claim.lines.any((l) => l.code == code)) return null;
      return claim.copyWith(lines: [
        ...claim.lines,
        ServiceLine(
          code: code,
          description: serviceDescription(code) ?? code,
          charge: fees[code] ?? 0,
          diagnosisCodes: claim.lines[anchor].diagnosisCodes,
          evidence: 'Added from a claim check',
        ),
      ]);
    case FixKind.addModifier:
      final i = claim.lines.indexWhere((l) => l.code == fix.code);
      final m = fix.replacement;
      if (i < 0 || m == null || claim.lines[i].modifiers.contains(m) || claim.lines[i].modifiers.length >= 4) return null;
      return claim.copyWith(lines: [...claim.lines]..[i] = claim.lines[i].copyWith(modifiers: [...claim.lines[i].modifiers, m]));
    default:
      return null;
  }
}

/// The place of service picker, shared by the visit and the claim.
Future<String?> pickPlaceOfService(BuildContext context, String current) => showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
        child: SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text('Place of service', style: Theme.of(ctx).textTheme.titleLarge),
              ),
              for (final p in placesOfService)
                ListTile(
                  title: Text(p.name),
                  leading: SizedBox(width: 32, child: Text(p.code, style: Theme.of(ctx).textTheme.labelLarge)),
                  trailing: p.code == current ? const Icon(Icons.check_rounded) : null,
                  onTap: () => Navigator.pop(ctx, p.code),
                ),
            ],
          ),
        ),
      ),
    );

/// The billing view of a visit: what goes on the claim, why, and what would
/// make a payer deny it.
class ClaimTab extends StatelessWidget {
  final ClaimDraft claim;
  final PatientAccount account;
  final Visit visit;
  final ProviderProfile provider;
  final bool noteSigned;
  final bool claimReady;
  final bool demoMode;
  final ClaimChanged onClaimChanged;
  final ValueChanged<String> onPlaceOfServiceChanged;
  final ValueChanged<AmbulanceTransport>? onTransportChanged;

  /// Saves the referring provider and prior authorization number.
  final void Function(ReferringProvider? referring, String priorAuth)? onReferralChanged;

  /// Saves the service facility, or clears it (null).
  final ValueChanged<ServiceFacility?>? onFacilityChanged;

  /// Fixes the tab cannot run itself (sign, open the profile or the patient).
  final ValueChanged<IssueFix>? onFix;

  /// Put on the Checks card so the screen can scroll to it.
  final GlobalKey? checksKey;
  final bool eligibilityConfigured;
  final Widget? header;

  const ClaimTab({
    super.key,
    required this.claim,
    required this.account,
    required this.visit,
    required this.provider,
    required this.noteSigned,
    required this.claimReady,
    required this.onClaimChanged,
    required this.onPlaceOfServiceChanged,
    this.demoMode = false,
    this.onTransportChanged,
    this.onReferralChanged,
    this.onFacilityChanged,
    this.onFix,
    this.checksKey,
    this.eligibilityConfigured = false,
    this.header,
  });

  /// The visit's date of service. Every code-set lookup on this tab (edition,
  /// Tabular notes, 7th characters) uses it, never today's date.
  DateTime? get _dos => DateTime.tryParse(visit.dateOfService);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final issues = ClaimScrubber.check(claim: claim, account: account, visit: visit, provider: provider, noteSigned: noteSigned, demoMode: demoMode);
    final errors = issues.where((i) => i.severity == IssueSeverity.error).length;
    final warnings = issues.where((i) => i.severity == IssueSeverity.warning).length;
    final billable = claim.billable;
    final pos = placeOfService(visit.placeOfService);

    final banner = claimReady
        ? const NoteBanner(icon: Icons.task_alt_rounded, title: 'Ready to bill', message: 'Marked ready. Copy the claim or send it from your billing system.', color: SolisTheme.success)
        : errors > 0
            ? Semantics(
                button: true,
                label: '$errors ${errors == 1 ? 'issue' : 'issues'} to fix before billing. Show checks.',
                excludeSemantics: true,
                child: InkWell(
                  key: const Key('claim_issues_banner'),
                  borderRadius: BorderRadius.circular(SolisTheme.radiusLg),
                  onTap: () {
                    final ctx = checksKey?.currentContext;
                    if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300));
                  },
                  child: NoteBanner(
                    icon: Icons.error_outline_rounded,
                    title: '$errors ${errors == 1 ? 'issue' : 'issues'} to fix before billing',
                    message: 'Each one would get the claim rejected or denied. The checks are listed first, each with its fix.',
                    color: SolisTheme.danger,
                  ),
                ),
              )
            : NoteBanner(
                icon: Icons.fact_check_outlined,
                title: warnings > 0 ? 'Billable, with $warnings ${warnings == 1 ? 'warning' : 'warnings'}' : 'Clean claim',
                message: warnings > 0 ? 'Review the warnings, then sign and send.' : 'No coding conflicts found.',
                color: warnings > 0 ? SolisTheme.warning : SolisTheme.success,
              );

    final elig = visit.eligibility;
    final eligState = EligibilityService.stateOf(elig);
    final checks = SectionCard(
      key: checksKey,
      title: 'Checks',
      icon: Icons.rule_rounded,
      child: issues.isEmpty
          ? Text('No issues found.', style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant))
          : Column(children: [
              for (final i in issues) _IssueRow(issue: i, dateOfService: _dos, onFix: i.fix == null ? null : () => _runFix(context, i.fix!)),
            ]),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        if (header != null) ...[header!, const SizedBox(height: 12)],
        banner,
        const SizedBox(height: 12),
        // When something blocks the claim, the checks and their fixes come first.
        if (errors > 0) ...[checks, const SizedBox(height: 12)],
        SectionCard(
          title: 'Visit',
          icon: Icons.event_note_outlined,
          child: Column(
            children: [
              _kv(context, 'Date of service', formatDos(visit.dateOfService)),
              _kv(
                context,
                'Place of service',
                pos.label,
                action: TextButton(onPressed: () => _pickPos(context), child: const Text('Change')),
              ),
              _kv(context, 'Patient', '${account.fullName}, ${account.ageSex}'),
              _kv(context, 'Payer', account.insurance == null ? 'No insurance on file' : '${account.insurance!.payerName}  |  ${account.insurance!.memberId}'),
              if (account.insurance != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        switch (eligState) {
                          EligibilityState.active => Icons.verified_outlined,
                          EligibilityState.inactive => Icons.block_rounded,
                          EligibilityState.failed => Icons.warning_amber_rounded,
                          EligibilityState.notChecked => Icons.help_outline_rounded,
                        },
                        size: 20,
                        color: switch (eligState) {
                          EligibilityState.active => SolisTheme.onTint(SolisTheme.success, isDark: dark),
                          EligibilityState.inactive => SolisTheme.onTint(SolisTheme.danger, isDark: dark),
                          EligibilityState.failed => SolisTheme.onTint(SolisTheme.warning, isDark: dark),
                          EligibilityState.notChecked => cs.onSurfaceVariant,
                        },
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(EligibilityService.describe(elig, configured: eligibilityConfigured), style: theme.textTheme.bodyMedium)),
                    ],
                  ),
                ),
              _kv(context, 'Rendering NPI', '${provider.npi}  |  ${provider.displayName}'),
            ],
          ),
        ),
        if (isAmbulancePos(visit.placeOfService)) ...[
          const SizedBox(height: 12),
          _TransportCard(transport: visit.transport, onEdit: onTransportChanged == null ? null : () => _editTransport(context)),
        ],
        const SizedBox(height: 12),
        SectionCard(
          title: 'Diagnoses (ICD-10-CM)',
          icon: Icons.local_hospital_outlined,
          actions: [TextButton.icon(onPressed: () => _addDiagnosis(context), icon: const Icon(Icons.add_rounded), label: const Text('Add'))],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (billable.isEmpty)
                Text('No billable diagnosis yet.', style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              for (var i = 0; i < billable.length; i++)
                _DxRow(
                  dx: billable[i],
                  pointer: i < 12 ? _pointers[i] : '-',
                  primary: i == 0,
                  dateOfService: _dos,
                  onMakePrimary: i == 0 ? null : () => onClaimChanged(reconcileClaim(claim, primaryCode: billable[i].code, dateOfService: _dos)),
                  onRemove: () => onClaimChanged(
                    reconcileClaim(
                      claim,
                      dateOfService: _dos,
                      diagnoses: claim.diagnoses.where((d) => d.code != billable[i].code).toList(),
                      primaryCode: claim.primaryCode == billable[i].code ? '' : null,
                    ),
                    undoLabel: 'Removed ${billable[i].code}',
                  ),
                ),
            ],
          ),
        ),
        if (claim.uncertain.isNotEmpty) ...[
          const SizedBox(height: 12),
          SectionCard(
            title: 'Waiting for your confirmation',
            icon: Icons.help_outline_rounded,
            child: Column(
              children: [
                for (final d in claim.uncertain) _PendingRow(dx: d, onConfirm: () => onClaimChanged(_confirm(d.code))),
              ],
            ),
          ),
        ],
        if (claim.integral.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              leading: const Icon(Icons.call_merge_rounded),
              title: Text('Not coded separately (${claim.integral.length})'),
              subtitle: const Text('Symptoms that are part of a confirmed diagnosis'),
              shape: const Border(),
              collapsedShape: const Border(),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 8, 12),
              children: [
                for (final d in claim.integral)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${d.code}  ${d.description}', style: theme.textTheme.bodyLarge),
                              if (d.note != null) Text(d.note!, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                            ],
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => onClaimChanged(reconcileClaim(
                          claim,
                          diagnoses: [
                            for (final x in claim.diagnoses) x.code == d.code ? x.copyWith(status: DxStatus.billable, source: DxSource.manual, note: 'Coded by physician') : x,
                          ],
                        )),
                        child: const Text('Code it'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        SectionCard(
          title: 'Services (CPT / HCPCS)',
          icon: Icons.medical_services_outlined,
          actions: [
            if (claim.lines.any((l) => isOfficeEm(l.code)))
              TextButton.icon(onPressed: () => _billByTime(context), icon: const Icon(Icons.timer_outlined), label: const Text('Time')),
            TextButton.icon(onPressed: () => _addService(context), icon: const Icon(Icons.add_rounded), label: const Text('Add')),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (claim.lines.isEmpty) Text('No services yet.', style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              for (var i = 0; i < claim.lines.length; i++)
                _LineRow(
                  line: claim.lines[i],
                  miles: isAmbulanceMileageCode(claim.lines[i].code) ? visit.transport?.loadedMiles : null,
                  pointers: claim.lines[i].diagnosisCodes.map((c) {
                    final idx = billable.indexWhere((d) => d.code == c);
                    return idx >= 0 && idx < 12 ? _pointers[idx] : '';
                  }).where((p) => p.isNotEmpty).join(', '),
                  onEdit: () => _editLine(context, i),
                  onRemove: () => onClaimChanged(
                    reconcileClaim(claim, dateOfService: _dos, lines: [...claim.lines]..removeAt(i)),
                    undoLabel: 'Removed ${claim.lines[i].code}',
                  ),
                  onLevel: emFamily(claim.lines[i].code).isEmpty
                      ? null
                      : (code) => onClaimChanged(
                            changeEmLevel(claim, i, code, provider.feeSchedule),
                            undoLabel: 'Changed ${claim.lines[i].code} to $code',
                          ),
                ),
              if (claim.lines.isNotEmpty) ...[
                const Divider(),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Expanded(child: Text('Total charge', style: theme.textTheme.titleSmall)),
                      Text('\$${claim.totalCharge.toStringAsFixed(2)}', style: theme.textTheme.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          key: const Key('referral_card'),
          title: 'Referral and authorization',
          icon: Icons.assignment_ind_outlined,
          actions: [
            if (onReferralChanged != null)
              TextButton(key: const Key('edit_referral'), onPressed: () => _editReferral(context), child: const Text('Edit')),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _kv(context, 'Referring provider',
                  visit.referringProvider == null ? 'None' : '${visit.referringProvider!.displayName}  |  NPI ${visit.referringProvider!.npi}'),
              _kv(context, 'Prior authorization', visit.priorAuthNumber ?? 'None'),
            ],
          ),
        ),
        if (visit.placeOfService != '12' && !isAmbulancePos(visit.placeOfService)) ...[
          const SizedBox(height: 12),
          SectionCard(
            key: const Key('facility_card'),
            title: 'Service facility',
            icon: Icons.apartment_outlined,
            actions: [
              if (onFacilityChanged != null)
                TextButton(key: const Key('edit_facility'), onPressed: () => _editFacility(context), child: Text(visit.serviceFacility == null ? 'Add' : 'Edit')),
            ],
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                visit.serviceFacility == null
                    ? 'Your practice address (${provider.city.isEmpty ? 'from your profile' : provider.city}). Add a facility when you saw the patient somewhere else.'
                    : '${visit.serviceFacility!.name}\n${visit.serviceFacility!.oneLine}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
        ],
        if (errors == 0) ...[const SizedBox(height: 12), checks],
      ],
    );
  }

  Future<void> _editFacility(BuildContext context) async {
    final result = await showDialog<(ServiceFacility?,)>(
      context: context,
      builder: (_) => FacilityDialog(initial: visit.serviceFacility, places: provider.savedPlaces),
    );
    if (result != null) onFacilityChanged?.call(result.$1);
  }

  ClaimDraft _confirm(String code) => reconcileClaim(
        claim,
        dateOfService: _dos,
        diagnoses: [
          for (final x in claim.diagnoses)
            x.code == code ? x.copyWith(status: DxStatus.billable, source: DxSource.physicianConfirmed, note: 'Confirmed by ${provider.displayName}') : x,
        ],
      );

  /// Runs a check's fix. Claim edits happen here (with Undo); fixes that
  /// open other screens go to [onFix].
  Future<void> _runFix(BuildContext context, IssueFix fix) async {
    switch (fix.kind) {
      case FixKind.confirmDiagnosis:
        if (fix.code != null) onClaimChanged(_confirm(fix.code!));
      case FixKind.choosePlaceOfService:
        await _pickPos(context);
      case FixKind.editLine:
        final i = claim.lines.indexWhere((l) => l.code == fix.code);
        if (i >= 0) await _editLine(context, i);
      case FixKind.editTransport:
        if (onTransportChanged != null) await _editTransport(context);
      case FixKind.replaceDiagnosis:
      case FixKind.replaceService:
      case FixKind.addModifier:
      case FixKind.addService:
        final updated = applyClaimFix(claim, fix, provider.feeSchedule, dateOfService: _dos);
        if (updated != null) onClaimChanged(updated, undoLabel: fix.label);
      default:
        onFix?.call(fix);
    }
  }

  Future<void> _editReferral(BuildContext context) async {
    final result = await showDialog<(ReferringProvider?, String)>(
      context: context,
      builder: (_) => ReferralDialog(referring: visit.referringProvider, priorAuth: visit.priorAuthNumber ?? ''),
    );
    if (result != null) onReferralChanged?.call(result.$1, result.$2);
  }

  Future<void> _editTransport(BuildContext context) async {
    final updated = await Navigator.push<AmbulanceTransport>(
      context,
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => TransportEditor(initial: visit.transport ?? const AmbulanceTransport())),
    );
    if (updated != null) onTransportChanged?.call(updated);
  }

  Widget _kv(BuildContext context, String k, String v, {Widget? action}) {
    final theme = Theme.of(context);
    final label = Text(k, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant));
    final value = Text(v, style: theme.textTheme.bodyLarge);
    return LayoutBuilder(
      builder: (context, c) {
        // Narrow phones and large text: label above value so values are not squeezed.
        final big = MediaQuery.textScalerOf(context).scale(16) > 22;
        if (c.maxWidth < 330 || big) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [label, value])),
                ?action,
              ],
            ),
          );
        }
        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Row(children: [SizedBox(width: 120, child: label), Expanded(child: value), ?action]),
        );
      },
    );
  }

  Future<void> _pickPos(BuildContext context) async {
    final picked = await pickPlaceOfService(context, visit.placeOfService);
    if (picked != null && picked != visit.placeOfService) onPlaceOfServiceChanged(picked);
  }

  Future<void> _addDiagnosis(BuildContext context) async {
    final picked = await showDialog<ClaimDiagnosis>(
      context: context,
      builder: (_) => _DiagnosisSearchDialog(dateOfService: DateTime.tryParse(visit.dateOfService) ?? DateTime.now()),
    );
    if (picked == null || claim.diagnoses.any((d) => d.code == picked.code && d.status == DxStatus.billable)) return;
    onClaimChanged(reconcileClaim(claim, dateOfService: _dos, diagnoses: [...claim.diagnoses.where((d) => d.code != picked.code), picked]));
  }

  /// Office E/M by total time on the date of service, with prolonged
  /// services past the top level.
  Future<void> _billByTime(BuildContext context) async {
    final minutes = await showDialog<int>(context: context, builder: (_) => const _TotalTimeDialog());
    if (minutes == null || !context.mounted) return;
    final medicare = claimFilingIndicatorFor(account.insurance) == 'MB';
    final updated = applyTotalTime(claim, minutes, provider.feeSchedule, medicare: medicare);
    if (updated == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$minutes minutes is below the lowest office visit level. Bill by medical decision making instead.')));
      return;
    }
    final em = updated.lines.firstWhere((l) => isOfficeEm(l.code));
    onClaimChanged(updated, undoLabel: 'Billed by time: ${em.code}, $minutes minutes');
  }

  Future<void> _addService(BuildContext context) async {
    final picked = await showDialog<CatalogService>(context: context, builder: (_) => const _ServiceSearchDialog());
    if (picked == null) return;
    final line = ServiceLine(code: picked.code, description: picked.description, charge: provider.feeSchedule[picked.code] ?? 0);
    onClaimChanged(reconcileClaim(claim, dateOfService: _dos, lines: [...claim.lines, line]));
  }

  Future<void> _editLine(BuildContext context, int index) async {
    final line = claim.lines[index];
    final charge = TextEditingController(text: line.charge == 0 ? '' : line.charge.toStringAsFixed(2));
    final units = TextEditingController(text: '${line.units}');
    final mods = TextEditingController(text: line.modifiers.join(' '));
    // Unlisted and NOC codes carry a description of the service (837P SV101-7).
    final needsDescription = CmsEdiEdits.requiresServiceDescription(line.code);
    final description = TextEditingController(text: needsDescription && !CmsEdiEdits.isGenericDescription(line.code, line.description) ? line.description : '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(line.code),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(line.description),
              if (needsDescription) ...[
                const SizedBox(height: 16),
                TextField(
                  key: const Key('line_description'),
                  controller: description,
                  maxLength: CmsEdiEdits.serviceDescriptionMax,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'What was done',
                    helperText: 'Sent to the payer with this unlisted code',
                    hintText: 'e.g. Ceftriaxone 1 g IM',
                  ),
                ),
              ],
              const SizedBox(height: 16),
              TextField(controller: charge, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Charge per unit', prefixText: '\$ ')),
              const SizedBox(height: 12),
              if (isAmbulanceMileageCode(line.code))
                const Text('Units for mileage are the loaded miles entered in Transport.')
              else
                TextField(controller: units, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Units')),
              const SizedBox(height: 12),
              TextField(controller: mods, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Modifiers', hintText: 'e.g. 25 95 RT')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    final values = (charge.text, units.text, mods.text);
    final describedAs = description.text.trim();
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      charge.dispose();
      units.dispose();
      mods.dispose();
      description.dispose();
    });
    if (ok != true) return;
    final updated = line.copyWith(
      charge: double.tryParse(values.$1.replaceAll(',', '')) ?? line.charge,
      units: (int.tryParse(values.$2) ?? line.units).clamp(1, 999),
      modifiers: values.$3.toUpperCase().split(RegExp(r'[\s,]+')).where((m) => RegExp(r'^[A-Z0-9]{2}$').hasMatch(m)).take(4).toList(),
      description: needsDescription && describedAs.isNotEmpty ? describedAs : null,
    );
    onClaimChanged(reconcileClaim(claim, dateOfService: _dos, lines: [...claim.lines]..[index] = updated));
  }
}

/// Ambulance transport on the claim: where from, where to, how far and why.
class _TransportCard extends StatelessWidget {
  final AmbulanceTransport? transport;
  final VoidCallback? onEdit;

  const _TransportCard({required this.transport, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final t = transport ?? const AmbulanceTransport();
    String or(String s) => s.trim().isEmpty ? 'Not entered' : s;
    Widget row(String label, String value, {bool missing = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              Text(
                value,
                style: theme.textTheme.bodyLarge?.copyWith(color: missing ? SolisTheme.onTint(SolisTheme.warning, isDark: theme.brightness == Brightness.dark) : null),
              ),
            ],
          ),
        );
    final miles = t.loadedMiles;
    return SectionCard(
      key: const Key('transport_card'),
      title: 'Transport',
      icon: Icons.airport_shuttle_outlined,
      actions: [if (onEdit != null) TextButton.icon(onPressed: onEdit, icon: const Icon(Icons.edit_outlined), label: const Text('Edit'))],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row('Pick-up', or(t.pickup.oneLine), missing: !t.pickup.isComplete),
          row('Drop-off', or(t.dropoff.oneLine), missing: !t.dropoff.isComplete),
          row(
            'Loaded miles',
            miles == null
                ? 'Not entered${t.gpsMiles != null ? ' (location fixes measured ${t.gpsMiles!.toStringAsFixed(1)})' : ''}'
                : '${miles.toStringAsFixed(1)} mi${t.milesSource == 'gps' ? ', from location fixes' : ''}',
            missing: miles == null,
          ),
          row('Reason', t.reasonCode == null ? 'Not entered' : '${t.reasonCode}: ${ambulanceTransportReasons[t.reasonCode]}', missing: t.reasonCode == null),
          row(
            'Origin and destination',
            t.modifier == null ? 'Not entered' : '${t.modifier}: ${ambulanceLocationCodes[t.originCode]} to ${ambulanceLocationCodes[t.destinationCode]}',
            missing: t.modifier == null,
          ),
          if (t.patientWeightLbs != null) row('Patient weight', '${t.patientWeightLbs} lb'),
          if (t.conditionCodes.isNotEmpty) row('Conditions', t.conditionCodes.map((c) => ambulanceConditionCodes[c] ?? c).join(', ')),
        ],
      ),
    );
  }
}

/// Edits the ambulance transport. Every field is the crew's; location
/// fixes only prefill what was empty.
class TransportEditor extends StatefulWidget {
  final AmbulanceTransport initial;
  const TransportEditor({super.key, required this.initial});

  @override
  State<TransportEditor> createState() => _TransportEditorState();
}

class _TransportEditorState extends State<TransportEditor> {
  final _form = GlobalKey<FormState>();
  late final AmbulanceTransport _t = widget.initial;
  late final Map<String, TextEditingController> _c = {
    'pName': TextEditingController(text: _t.pickup.name ?? ''),
    'pLine': TextEditingController(text: _t.pickup.line1),
    'pCity': TextEditingController(text: _t.pickup.city),
    'pState': TextEditingController(text: _t.pickup.state),
    'pZip': TextEditingController(text: _t.pickup.zip),
    'dName': TextEditingController(text: _t.dropoff.name ?? ''),
    'dLine': TextEditingController(text: _t.dropoff.line1),
    'dCity': TextEditingController(text: _t.dropoff.city),
    'dState': TextEditingController(text: _t.dropoff.state),
    'dZip': TextEditingController(text: _t.dropoff.zip),
    'miles': TextEditingController(text: _t.loadedMiles?.toStringAsFixed(1) ?? ''),
    'weight': TextEditingController(text: _t.patientWeightLbs?.toString() ?? ''),
  };
  late String? _reason = _t.reasonCode;
  late String? _origin = _t.originCode;
  late String? _dest = _t.destinationCode;
  late final Set<String> _conditions = {..._t.conditionCodes};

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) return;
    String t(String k) => _c[k]!.text.trim();
    final miles = double.tryParse(t('miles'));
    final typedMiles = miles == null ? null : roundUpTenth(miles);
    final weight = int.tryParse(t('weight'));
    final result = _t.copyWith(
      pickup: TransportAddress(name: t('pName').isEmpty ? null : t('pName'), line1: t('pLine'), city: t('pCity'), state: t('pState').toUpperCase(), zip: t('pZip')),
      dropoff: TransportAddress(name: t('dName').isEmpty ? null : t('dName'), line1: t('dLine'), city: t('dCity'), state: t('dState').toUpperCase(), zip: t('dZip')),
      loadedMiles: typedMiles,
      clearMiles: typedMiles == null,
      milesSource: typedMiles == null ? null : (typedMiles == _t.loadedMiles ? _t.milesSource : 'entered'),
      reasonCode: _reason,
      patientWeightLbs: weight,
      clearWeight: weight == null,
      originCode: _origin,
      destinationCode: _dest,
      conditionCodes: _conditions.toList()..sort(),
    );
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget field(String key, String label, {TextInputType? type, String? Function(String?)? validator, int? maxLength}) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextFormField(
            key: Key('transport_$key'),
            controller: _c[key],
            keyboardType: type,
            maxLength: maxLength,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: label, counterText: ''),
            validator: validator,
          ),
        );
    String? zip(String? v) {
      final d = (v ?? '').replaceAll(RegExp(r'[^0-9]'), '');
      return d.isEmpty || d.length == 5 || d.length == 9 ? null : '5 or 9 digits';
    }

    String? state(String? v) => (v ?? '').trim().isEmpty || RegExp(r'^[A-Za-z]{2}$').hasMatch(v!.trim()) ? null : '2 letters';
    Widget heading(String s) => Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
          child: Text(s, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
        );
    Widget address(String p) => Column(
          children: [
            field('${p}Name', p == 'p' ? 'Place name (optional)' : 'Facility name'),
            field('${p}Line', 'Street address'),
            field('${p}City', 'City'),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: field('${p}State', 'State', validator: state, maxLength: 2)),
                const SizedBox(width: 12),
                Expanded(child: field('${p}Zip', 'ZIP', type: TextInputType.number, validator: zip)),
              ],
            ),
          ],
        );
    DropdownButtonFormField<String> codePicker(String label, String? value, ValueChanged<String?> onChanged, {bool destination = false}) =>
        DropdownButtonFormField<String>(
          initialValue: value,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: [
            for (final e in ambulanceLocationCodes.entries)
              if (destination || e.key != 'X') DropdownMenuItem(value: e.key, child: Text('${e.key}: ${e.value}', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: onChanged,
        );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transport'),
        actions: [TextButton(key: const Key('transport_save'), onPressed: _save, child: const Text('Save'))],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            heading('Pick-up (837P loop 2310E)'),
            address('p'),
            heading('Drop-off (837P loop 2310F)'),
            address('d'),
            heading('Trip'),
            field('miles', 'Loaded miles', type: const TextInputType.numberWithOptions(decimal: true), validator: (v) {
              if ((v ?? '').trim().isEmpty) return null;
              final m = double.tryParse(v!.trim());
              return m == null || m <= 0 || m > 2000 ? 'Miles, for example 7.3' : null;
            }),
            if (_t.gpsMiles != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('Location fixes during the visit measured ${_t.gpsMiles!.toStringAsFixed(1)} mi.', style: theme.textTheme.bodySmall),
              ),
            DropdownButtonFormField<String>(
              key: const Key('transport_reason'),
              initialValue: _reason,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Transport reason (CR104)'),
              items: [
                for (final e in ambulanceTransportReasons.entries) DropdownMenuItem(value: e.key, child: Text('${e.key}: ${e.value}', overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _reason = v),
            ),
            const SizedBox(height: 12),
            codePicker('Origin', _origin, (v) => setState(() => _origin = v)),
            const SizedBox(height: 12),
            codePicker('Destination', _dest, (v) => setState(() => _dest = v), destination: true),
            const SizedBox(height: 12),
            field('weight', 'Patient weight in pounds (if known)', type: TextInputType.number, validator: (v) {
              if ((v ?? '').trim().isEmpty) return null;
              final w = int.tryParse(v!.trim());
              return w == null || w <= 0 || w > 1500 ? 'Whole pounds' : null;
            }),
            heading('Ambulance certification (CRC)'),
            for (final e in ambulanceConditionCodes.entries)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _conditions.contains(e.key),
                title: Text(e.value),
                onChanged: (v) => setState(() {
                  if (v == true) {
                    if (_conditions.length < 5) _conditions.add(e.key);
                  } else {
                    _conditions.remove(e.key);
                  }
                }),
              ),
          ],
        ),
      ),
    );
  }
}

class _DxRow extends StatelessWidget {
  final ClaimDiagnosis dx;
  final String pointer;
  final bool primary;
  final DateTime? dateOfService;
  final VoidCallback? onMakePrimary;
  final VoidCallback onRemove;

  const _DxRow({
    required this.dx,
    required this.pointer,
    required this.primary,
    required this.onMakePrimary,
    required this.onRemove,
    this.dateOfService,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: primary ? cs.primary : cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(SolisTheme.radiusSm),
            ),
            child: Text(pointer, style: theme.textTheme.labelLarge?.copyWith(color: primary ? cs.onPrimary : cs.onSurface)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(dx.code, style: theme.textTheme.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                    StatusTag(label: dxSourceLabel(dx.source), color: dx.source == DxSource.patientReported ? SolisTheme.teal : cs.onSurfaceVariant),
                    if (primary) const StatusTag(label: 'Primary', color: SolisTheme.info),
                  ],
                ),
                const SizedBox(height: 2),
                Text(dx.description, style: theme.textTheme.bodyMedium),
                if (dx.evidence != null && dx.evidence!.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '"${dx.evidence!.trim()}"',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontStyle: FontStyle.italic),
                  ),
                ],
                CodeNotesToggle(key: ValueKey('notes-${dx.code}'), code: dx.code, dateOfService: dateOfService),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Options for ${dx.code}',
            onSelected: (v) => v == 'primary' ? onMakePrimary?.call() : onRemove(),
            itemBuilder: (_) => [
              if (onMakePrimary != null) const PopupMenuItem(value: 'primary', child: Text('Make primary')),
              const PopupMenuItem(value: 'remove', child: Text('Remove from claim')),
            ],
          ),
        ],
      ),
    );
  }
}

class _PendingRow extends StatelessWidget {
  final ClaimDiagnosis dx;
  final VoidCallback onConfirm;

  const _PendingRow({required this.dx, required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${dx.code}  ${dx.description}', style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
          if (dx.note != null) ...[
            const SizedBox(height: 2),
            Text(dx.note!, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          ],
          if (dx.evidence != null) ...[
            const SizedBox(height: 4),
            Text('"${dx.evidence!.trim()}"', maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic, color: cs.onSurfaceVariant)),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(onPressed: onConfirm, icon: const Icon(Icons.check_rounded), label: const Text('Confirm diagnosis')),
          ),
        ],
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  final ServiceLine line;
  final String pointers;
  final double? miles;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  /// Set for E/M lines: picks another level of the same family.
  final ValueChanged<String>? onLevel;

  const _LineRow({required this.line, required this.pointers, required this.onEdit, required this.onRemove, this.onLevel, this.miles});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final noDx = pointers.isEmpty;
    final family = emFamily(line.code);
    final unitsText = isAmbulanceMileageCode(line.code)
        ? (miles == null ? 'miles not entered' : '${roundUpTenth(miles!).toStringAsFixed(1)} mi x \$${line.charge.toStringAsFixed(2)}')
        : '${line.unitsLabel} x \$${line.charge.toStringAsFixed(2)}';
    return InkWell(
      borderRadius: BorderRadius.circular(SolisTheme.radiusSm),
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [line.code, ...line.modifiers].join('-'),
                    style: theme.textTheme.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                  const SizedBox(height: 2),
                  Text(line.description, style: theme.textTheme.bodyMedium),
                  if (line.isEvaluationAndManagement && (line.evidence ?? '').isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text('Why this level: ${line.evidence}', style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 12,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(noDx ? Icons.link_off_rounded : Icons.link_rounded, size: 16, color: noDx ? SolisTheme.onTint(SolisTheme.danger, isDark: dark) : cs.onSurfaceVariant),
                          const SizedBox(width: 4),
                          Text(
                            noDx ? 'No supporting diagnosis' : 'Diagnosis $pointers',
                            style: theme.textTheme.bodySmall?.copyWith(color: noDx ? SolisTheme.onTint(SolisTheme.danger, isDark: dark) : cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                      Text(unitsText, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
                    ],
                  ),
                  if (onLevel != null && family.length > 1) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final c in family)
                          ChoiceChip(
                            key: Key('em_level_$c'),
                            label: Text(c),
                            tooltip: emDescription(c),
                            selected: c == line.code,
                            onSelected: c == line.code ? null : (_) => onLevel!(c),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            IconButton(tooltip: 'Remove ${line.code}', icon: const Icon(Icons.close_rounded), onPressed: onRemove),
          ],
        ),
      ),
    );
  }
}

class _IssueRow extends StatelessWidget {
  final ClaimIssue issue;
  final VoidCallback? onFix;
  final DateTime? dateOfService;

  const _IssueRow({required this.issue, this.onFix, this.dateOfService});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final (icon, color) = switch (issue.severity) {
      IssueSeverity.error => (Icons.error_outline_rounded, SolisTheme.danger),
      IssueSeverity.warning => (Icons.warning_amber_rounded, SolisTheme.warning),
      IssueSeverity.info => (Icons.info_outline_rounded, SolisTheme.info),
    };
    final fix = issue.fix;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: SolisTheme.onTint(color, isDark: dark)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(issue.title, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(issue.detail, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (fix != null && onFix != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: FilledButton.tonal(key: Key('fix_${issue.ruleId}_${issue.code ?? ''}'), onPressed: onFix, child: Text(fix.label)),
                      ),
                    if (issue.ruleId != null || issue.citation != null) WhyButton(issue: issue, dateOfService: dateOfService),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for the total time on the date of service, in minutes.
class _TotalTimeDialog extends StatefulWidget {
  const _TotalTimeDialog();

  @override
  State<_TotalTimeDialog> createState() => _TotalTimeDialogState();
}

class _TotalTimeDialogState extends State<_TotalTimeDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  int? get _minutes {
    final n = int.tryParse(_c.text.trim());
    return n == null || n < 1 || n > 600 ? null : n;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Bill by total time'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your total time on the date of service, face to face and not, including notes and orders. '
            'The note must state it.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _c,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Total minutes', suffixText: 'min'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_minutes != null) Navigator.pop(context, _minutes);
            },
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _minutes == null ? null : () => Navigator.pop(context, _minutes), child: const Text('Apply')),
      ],
    );
  }
}

/// ICD-10-CM search: live NIH NLM results with the local list as fallback.
class _DiagnosisSearchDialog extends StatefulWidget {
  final DateTime dateOfService;
  const _DiagnosisSearchDialog({required this.dateOfService});

  @override
  State<_DiagnosisSearchDialog> createState() => _DiagnosisSearchDialogState();
}

class _DiagnosisSearchDialogState extends State<_DiagnosisSearchDialog> {
  final _q = TextEditingController();
  Timer? _debounce;
  bool _loading = false;
  List<(String, String)> _results = [];
  final Set<String> _open = {};

  // Before anything is typed: the diagnoses this clinician billed most
  // recently, valid on this visit's date of service.
  late final List<(String, String)> _recent = recentDiagnoses(
    AccountRepository.instance.accounts,
    includeSamples: AuthService.instance.isDemo,
    isValid: (code) => ReferenceData.icdFor(widget.dateOfService)?.isBillable(code) ?? true,
  );

  Map<String, String> get _favorites => AccountRepository.instance.provider.favoriteDiagnoses;

  Future<void> _toggleFavorite(String code, String desc) async {
    final repo = AccountRepository.instance;
    await repo.saveProvider(repo.provider.toggleFavoriteDiagnosis(code, desc));
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _search(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() {
        _results = [];
        _loading = false;
      });
      return;
    }
    // Official code set for the visit's date of service, offline.
    final icd = ReferenceData.icdFor(widget.dateOfService);
    if (icd != null) {
      setState(() {
        _loading = false;
        _results = [for (final e in icd.search(q, limit: 30)) if (e.billable) (e.code, e.description)];
      });
      return;
    }
    setState(() => _loading = true);
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final codes = await NlmCodingService.searchCodes(q);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _results = [for (final c in codes) if (c.type == 'ICD10') (c.code, c.description)];
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a diagnosis'),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _q,
              autofocus: true,
              onChanged: _search,
              decoration: InputDecoration(
                hintText: 'Condition or ICD-10 code',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _loading ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))) : null,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (_q.text.trim().length < 2 && _favorites.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 4),
                      child: Text('Favorites', style: Theme.of(context).textTheme.labelLarge),
                    ),
                  if (_q.text.trim().length < 2 && _recent.any((r) => !_favorites.containsKey(r.$1.toUpperCase())))
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 4),
                      child: Text('Recent', style: Theme.of(context).textTheme.labelLarge),
                    ),
                  for (final (code, desc) in _q.text.trim().length < 2
                      ? [
                          // A starred code that is not billable on this date of service is left out.
                          for (final e in _favorites.entries)
                            if (ReferenceData.icdFor(widget.dateOfService)?.isBillable(e.key) ?? true) (e.key, e.value),
                          ..._recent.where((r) => !_favorites.containsKey(r.$1.toUpperCase()))]
                      : _results) ...[
                    ListTile(
                      key: Key('dx_option_$code'),
                      contentPadding: EdgeInsets.zero,
                      leading: IconButton(
                        key: Key('dx_star_$code'),
                        tooltip: _favorites.containsKey(code.toUpperCase()) ? 'Remove $code from favorites' : 'Add $code to favorites',
                        icon: Icon(_favorites.containsKey(code.toUpperCase()) ? Icons.star_rounded : Icons.star_outline_rounded),
                        color: _favorites.containsKey(code.toUpperCase()) ? Theme.of(context).colorScheme.primary : null,
                        onPressed: () => _toggleFavorite(code, desc),
                      ),
                      title: Text(code),
                      subtitle: Text(desc),
                      trailing: codeNotesFor(code, dateOfService: widget.dateOfService).isEmpty &&
                              ReferenceData.seventhFor(widget.dateOfService)?.ruleFor(code) == null
                          ? null
                          : IconButton(
                              tooltip: _open.contains(code) ? 'Hide coding notes for $code' : 'Coding notes for $code',
                              icon: Icon(_open.contains(code) ? Icons.expand_less_rounded : Icons.info_outline_rounded),
                              onPressed: () => setState(() => _open.contains(code) ? _open.remove(code) : _open.add(code)),
                            ),
                      onTap: () => Navigator.pop(context, ClaimDiagnosis(code: code, description: desc, source: DxSource.manual)),
                    ),
                    if (_open.contains(code))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: CodeNotesList(
                          notes: codeNotesFor(code, dateOfService: widget.dateOfService),
                          seventhFor: code,
                          dateOfService: widget.dateOfService,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}

class _ServiceSearchDialog extends StatefulWidget {
  const _ServiceSearchDialog();

  @override
  State<_ServiceSearchDialog> createState() => _ServiceSearchDialogState();
}

class _ServiceSearchDialogState extends State<_ServiceSearchDialog> {
  String _q = '';

  // Recently billed services are listed first until something is typed.
  late final List<String> _recent = recentServiceCodes(AccountRepository.instance.accounts, includeSamples: AuthService.instance.isDemo);

  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    var results = serviceCatalog.where((s) => q.isEmpty || s.code.toLowerCase().contains(q) || s.description.toLowerCase().contains(q)).toList();
    final favorites = AccountRepository.instance.provider.favoriteServices;
    if (q.isEmpty && (_recent.isNotEmpty || favorites.isNotEmpty)) {
      final first = [...favorites, ..._recent.where((c) => !favorites.contains(c))];
      results = [
        for (final code in first) ...results.where((s) => s.code == code),
        ...results.where((s) => !first.contains(s.code)),
      ];
    }
    return AlertDialog(
      title: const Text('Add a service'),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _q = v),
              decoration: const InputDecoration(hintText: 'CPT or HCPCS code, or description', prefixIcon: Icon(Icons.search_rounded)),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final s in results)
                    ListTile(
                      key: Key('svc_option_${s.code}'),
                      contentPadding: EdgeInsets.zero,
                      leading: IconButton(
                        key: Key('svc_star_${s.code}'),
                        tooltip: favorites.contains(s.code) ? 'Remove ${s.code} from favorites' : 'Add ${s.code} to favorites',
                        icon: Icon(favorites.contains(s.code) ? Icons.star_rounded : Icons.star_outline_rounded),
                        color: favorites.contains(s.code) ? Theme.of(context).colorScheme.primary : null,
                        onPressed: () async {
                          final repo = AccountRepository.instance;
                          await repo.saveProvider(repo.provider.toggleFavoriteService(s.code));
                          if (mounted) setState(() {});
                        },
                      ),
                      title: Text(s.code),
                      subtitle: Text(s.description),
                      onTap: () => Navigator.pop(context, s),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}

/// Edits the referring provider (box 17, 2310A) and the prior authorization
/// number (box 23, REF*G1). Leaving the referring NPI empty removes it.
class ReferralDialog extends StatefulWidget {
  final ReferringProvider? referring;
  final String priorAuth;

  const ReferralDialog({super.key, this.referring, this.priorAuth = ''});

  @override
  State<ReferralDialog> createState() => _ReferralDialogState();
}

class _ReferralDialogState extends State<ReferralDialog> {
  late final _first = TextEditingController(text: widget.referring?.firstName ?? '');
  late final _last = TextEditingController(text: widget.referring?.lastName ?? '');
  late final _npi = TextEditingController(text: widget.referring?.npi ?? '');
  late final _auth = TextEditingController(text: widget.priorAuth);
  String? _npiError;
  String? _lastError;

  @override
  void dispose() {
    for (final c in [_first, _last, _npi, _auth]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final npi = _npi.text.trim();
    final last = _last.text.trim();
    setState(() {
      _npiError = npi.isEmpty && last.isEmpty ? null : (isValidNpi(npi) ? null : 'Enter a valid 10-digit NPI');
      _lastError = npi.isNotEmpty && last.isEmpty ? 'Last name is required' : null;
    });
    if (_npiError != null || _lastError != null) return;
    final referring = npi.isEmpty ? null : ReferringProvider(firstName: _first.text.trim(), lastName: last, npi: npi);
    Navigator.pop(context, (referring, _auth.text.trim()));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Referral and authorization'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(key: const Key('referring_first'), controller: _first, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Referring provider first name')),
              TextField(key: const Key('referring_last'), controller: _last, textCapitalization: TextCapitalization.words, decoration: InputDecoration(labelText: 'Last name', errorText: _lastError)),
              TextField(key: const Key('referring_npi'), controller: _npi, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'Referring NPI', errorText: _npiError)),
              const SizedBox(height: 8),
              TextField(key: const Key('prior_auth'), controller: _auth, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Prior authorization number')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const Key('referral_save'), onPressed: _save, child: const Text('Save')),
        ],
      );
}

/// Edits the service facility (box 32, 2310C). A saved place fills the
/// name and, when it has one, the address. Pops with (facility,) or (null,)
/// to go back to the practice address.
class FacilityDialog extends StatefulWidget {
  final ServiceFacility? initial;
  final List<SavedPlace> places;

  const FacilityDialog({super.key, this.initial, this.places = const []});

  @override
  State<FacilityDialog> createState() => _FacilityDialogState();
}

class _FacilityDialogState extends State<FacilityDialog> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _line1 = TextEditingController(text: widget.initial?.line1 ?? '');
  late final _city = TextEditingController(text: widget.initial?.city ?? '');
  late final _state = TextEditingController(text: widget.initial?.state ?? '');
  late final _zip = TextEditingController(text: widget.initial?.zip ?? '');
  bool _tried = false;

  ServiceFacility get _facility => ServiceFacility(
        name: _name.text.trim(),
        line1: _line1.text.trim(),
        city: _city.text.trim(),
        state: _state.text.trim().toUpperCase(),
        zip: _zip.text.trim(),
      );

  @override
  void dispose() {
    for (final c in [_name, _line1, _city, _state, _zip]) {
      c.dispose();
    }
    super.dispose();
  }

  void _usePlace(SavedPlace p) {
    final parsed = ServiceFacility.parse(p.name, p.address);
    setState(() {
      _name.text = p.name;
      if (parsed != null) {
        _line1.text = parsed.line1;
        _city.text = parsed.city;
        _state.text = parsed.state;
        _zip.text = parsed.zip;
      }
    });
  }

  void _save() {
    setState(() => _tried = true);
    if (!_facility.isComplete) return;
    Navigator.pop(context, (_facility,));
  }

  Widget _f(String key, TextEditingController c, String label, {TextInputType? type, TextCapitalization caps = TextCapitalization.words}) => TextField(
        key: Key('facility_$key'),
        controller: c,
        keyboardType: type,
        textCapitalization: caps,
        decoration: InputDecoration(labelText: label),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Service facility'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.places.isNotEmpty) ...[
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final p in widget.places) ActionChip(avatar: const Icon(Icons.place_outlined, size: 18), label: Text(p.name), onPressed: () => _usePlace(p))],
              ),
              const SizedBox(height: 8),
            ],
            _f('name', _name, 'Facility name'),
            _f('line1', _line1, 'Street'),
            _f('city', _city, 'City'),
            Row(
              children: [
                Expanded(child: _f('state', _state, 'State', caps: TextCapitalization.characters)),
                const SizedBox(width: 12),
                Expanded(child: _f('zip', _zip, 'ZIP', type: TextInputType.number)),
              ],
            ),
            if (_tried && !_facility.isComplete)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Fill in the name, street, city, a 2-letter state and a 5-digit ZIP.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        if (widget.initial != null) TextButton(onPressed: () => Navigator.pop(context, (null,)), child: const Text('Use practice address')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const Key('facility_save'), onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
