/// Where a diagnosis came from. Drives how it is shown and whether it can be
/// billed without the physician confirming it.
enum DxSource {
  /// Symptom the patient described in their own words ("my head is pounding").
  patientReported,

  /// Diagnosis the physician stated without hedging.
  physicianConfirmed,

  /// Objective finding from the exam or vitals (effusion, hypotension).
  examFinding,

  /// Chronic condition the patient carries and the physician is managing.
  history,

  /// Added by hand on the claim screen.
  manual,
}

String dxSourceLabel(DxSource s) => switch (s) {
      DxSource.patientReported => 'Patient reported',
      DxSource.physicianConfirmed => 'Physician',
      DxSource.examFinding => 'Exam finding',
      DxSource.history => 'History',
      DxSource.manual => 'Added',
    };

enum DxStatus {
  /// Goes on the claim.
  billable,

  /// Physician used hedged language ("sounds like", "suspicious for"). Under
  /// ICD-10-CM outpatient guideline IV.H it is not coded until confirmed.
  uncertain,

  /// A symptom that is part of a confirmed diagnosis (chest pain with STEMI).
  /// Not coded separately.
  integral,
}

class ClaimDiagnosis {
  final String code; // ICD-10-CM with dot, e.g. I21.19
  final String description;
  final DxSource source;
  final DxStatus status;
  final String? evidence; // the words that support it
  final String? note; // why it is uncertain or integral

  const ClaimDiagnosis({
    required this.code,
    required this.description,
    required this.source,
    this.status = DxStatus.billable,
    this.evidence,
    this.note,
  });

  ClaimDiagnosis copyWith({DxStatus? status, String? note, DxSource? source}) => ClaimDiagnosis(
        code: code,
        description: description,
        source: source ?? this.source,
        status: status ?? this.status,
        evidence: evidence,
        note: note ?? this.note,
      );

  Map<String, dynamic> toJson() => {
        'code': code,
        'description': description,
        'source': source.name,
        'status': status.name,
        'evidence': evidence,
        'note': note,
      };

  factory ClaimDiagnosis.fromJson(Map<String, dynamic> j) => ClaimDiagnosis(
        code: j['code'],
        description: j['description'] ?? '',
        source: DxSource.values.firstWhere((s) => s.name == j['source'], orElse: () => DxSource.manual),
        status: DxStatus.values.firstWhere((s) => s.name == j['status'], orElse: () => DxStatus.billable),
        evidence: j['evidence'],
        note: j['note'],
      );
}

/// One CMS-1500 box 24 line / 837P loop 2400 SV1.
class ServiceLine {
  final String code; // CPT or HCPCS
  final String description;
  final List<String> modifiers;
  final int units;
  final double charge;
  final List<String> diagnosisCodes; // linked ICD-10 codes, in pointer order
  final String? evidence;

  /// Fractional units, for services billed in tenths (ambulance mileage,
  /// A0425, is reported to 0.1 mile). When set it is what the claim bills;
  /// [units] then holds the whole-unit count used by unit edits.
  final double? quantity;

  const ServiceLine({
    required this.code,
    required this.description,
    this.modifiers = const [],
    this.units = 1,
    this.charge = 0,
    this.diagnosisCodes = const [],
    this.evidence,
    this.quantity,
  });

  ServiceLine copyWith({
    List<String>? modifiers,
    int? units,
    double? charge,
    List<String>? diagnosisCodes,
    String? code,
    String? description,
    String? evidence,
    double? quantity,
    bool clearQuantity = false,
  }) =>
      ServiceLine(
        code: code ?? this.code,
        description: description ?? this.description,
        modifiers: modifiers ?? this.modifiers,
        units: units ?? this.units,
        charge: charge ?? this.charge,
        diagnosisCodes: diagnosisCodes ?? this.diagnosisCodes,
        evidence: evidence ?? this.evidence,
        quantity: clearQuantity ? null : (quantity ?? this.quantity),
      );

  /// Units the claim bills: [quantity] when set, otherwise [units].
  double get billedUnits => quantity ?? units.toDouble();

  /// Units as written on the claim: "7.3" or "2".
  String get unitsLabel {
    final q = billedUnits;
    return q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(1);
  }

  double get lineCharge => charge * billedUnits;

  bool get isEvaluationAndManagement {
    final n = int.tryParse(code);
    return n != null && n >= 99202 && n <= 99499;
  }

  Map<String, dynamic> toJson() => {
        'code': code,
        'description': description,
        'modifiers': modifiers,
        'units': units,
        'charge': charge,
        'diagnosisCodes': diagnosisCodes,
        'evidence': evidence,
        if (quantity != null) 'quantity': quantity,
      };

  factory ServiceLine.fromJson(Map<String, dynamic> j) => ServiceLine(
        code: j['code'],
        description: j['description'] ?? '',
        modifiers: List<String>.from(j['modifiers'] ?? const []),
        units: j['units'] ?? 1,
        charge: (j['charge'] as num?)?.toDouble() ?? 0,
        diagnosisCodes: List<String>.from(j['diagnosisCodes'] ?? const []),
        evidence: j['evidence'],
        quantity: (j['quantity'] as num?)?.toDouble(),
      );
}

/// The billable output of a visit: diagnoses (box 21) and services (box 24).
class ClaimDraft {
  final List<ClaimDiagnosis> diagnoses; // all, including uncertain and integral
  final List<ServiceLine> lines;
  final DateTime generatedAtUtc;
  final String? primaryCode; // set when the physician picks the primary diagnosis

  const ClaimDraft({required this.diagnoses, required this.lines, required this.generatedAtUtc, this.primaryCode});

  /// Diagnoses that go on the claim, primary first (box 21 A..L).
  List<ClaimDiagnosis> get billable => diagnoses.where((d) => d.status == DxStatus.billable).toList();
  List<ClaimDiagnosis> get uncertain => diagnoses.where((d) => d.status == DxStatus.uncertain).toList();
  List<ClaimDiagnosis> get integral => diagnoses.where((d) => d.status == DxStatus.integral).toList();

  double get totalCharge => lines.fold(0, (s, l) => s + l.lineCharge);

  ClaimDraft copyWith({List<ClaimDiagnosis>? diagnoses, List<ServiceLine>? lines, String? primaryCode}) => ClaimDraft(
        diagnoses: diagnoses ?? this.diagnoses,
        lines: lines ?? this.lines,
        generatedAtUtc: generatedAtUtc,
        primaryCode: primaryCode ?? this.primaryCode,
      );

  Map<String, dynamic> toJson() => {
        'diagnoses': diagnoses.map((d) => d.toJson()).toList(),
        'lines': lines.map((l) => l.toJson()).toList(),
        'generatedAtUtc': generatedAtUtc.toIso8601String(),
        'primaryCode': primaryCode,
      };

  factory ClaimDraft.fromJson(Map<String, dynamic> j) => ClaimDraft(
        diagnoses: [for (final d in (j['diagnoses'] as List? ?? const [])) ClaimDiagnosis.fromJson((d as Map).cast<String, dynamic>())],
        lines: [for (final l in (j['lines'] as List? ?? const [])) ServiceLine.fromJson((l as Map).cast<String, dynamic>())],
        generatedAtUtc: DateTime.tryParse(j['generatedAtUtc'] ?? '') ?? DateTime.now().toUtc(),
        primaryCode: j['primaryCode'],
      );
}

enum IssueSeverity { error, warning, info }

/// What a check's fix button does. Only fixes that need no clinical
/// judgment change the claim by themselves; the others open the place where
/// the physician decides.
enum FixKind {
  /// Opens the sign step.
  signNote,

  /// Moves an uncertain diagnosis onto the claim ([IssueFix.code]).
  confirmDiagnosis,

  /// Opens the place of service picker.
  choosePlaceOfService,

  /// Opens the patient's details ([IssueFix.field] says which).
  editPatient,

  /// Opens the insurance card scanner.
  scanCard,

  /// Opens the provider profile.
  editProvider,

  /// Opens the ambulance transport details.
  editTransport,

  /// Opens the service line editor for [IssueFix.code].
  editLine,

  /// Replaces diagnosis [IssueFix.code] with [IssueFix.replacement].
  replaceDiagnosis,

  /// Replaces service [IssueFix.code] with [IssueFix.replacement].
  replaceService,

  /// Adds modifier [IssueFix.replacement] to service [IssueFix.code].
  addModifier,

  /// Adds service [IssueFix.replacement], pointing to the diagnoses of
  /// service [IssueFix.code]. Offered on a tap, never applied on its own.
  addService,
}

/// A one-tap fix offered next to a check.
class IssueFix {
  final FixKind kind;
  final String label;
  final String? code;
  final String? replacement;
  final String? field;

  const IssueFix(this.kind, this.label, {this.code, this.replacement, this.field});

  /// Fixes that change the claim with no decision left to the physician.
  bool get changesClaim => kind == FixKind.replaceDiagnosis || kind == FixKind.replaceService || kind == FixKind.addModifier;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'label': label,
        if (code != null) 'code': code,
        if (replacement != null) 'replacement': replacement,
        if (field != null) 'field': field,
      };
}

/// One finding from the claim scrubber.
class ClaimIssue {
  final IssueSeverity severity;
  final String title;
  final String detail;
  final String? code; // the code the issue is about, when there is one

  /// Id of the knowledge-base rule the check enforces (knowledge/rules/
  /// rule_catalog.json, or a CLAIM- form rule), for the "Why" explanation.
  final String? ruleId;

  /// Short official citation, for example "ICD-10-CM Guidelines IV.H".
  final String? citation;

  /// One-tap fix, when the check has a deterministic one.
  final IssueFix? fix;

  const ClaimIssue(this.severity, this.title, this.detail, {this.code, this.ruleId, this.citation, this.fix});

  ClaimIssue withRule(String id, String? cite) =>
      ClaimIssue(severity, title, detail, code: code, ruleId: ruleId ?? id, citation: citation ?? cite, fix: fix);

  ClaimIssue withFix(IssueFix? f) => ClaimIssue(severity, title, detail, code: code, ruleId: ruleId, citation: citation, fix: f);

  Map<String, dynamic> toJson() => {
        'severity': severity.name,
        'title': title,
        'detail': detail,
        'code': code,
        if (ruleId != null) 'ruleId': ruleId,
        if (citation != null) 'citation': citation,
        if (fix != null) 'fix': fix!.toJson(),
      };
}
