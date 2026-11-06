import '../services/note_seal.dart';

class MedicalCode {
  final String code;
  final String description;
  final String type; // ICD10, CPT
  final bool verified;
  final double? rvu;
  final String? rationale;

  const MedicalCode({
    required this.code,
    required this.description,
    required this.type,
    this.verified = true,
    this.rvu,
    this.rationale,
  });

  Map<String, dynamic> toJson() => {
    'code': code,
    'description': description,
    'type': type,
    'verified': verified,
    'rvu': rvu,
    'rationale': rationale,
  };

  factory MedicalCode.fromJson(Map<String, dynamic> json) => MedicalCode(
    code: json['code'] ?? '',
    description: json['description'] ?? '',
    type: json['type'] ?? 'ICD10',
    verified: json['verified'] ?? true,
    rvu: (json['rvu'] as num?)?.toDouble(),
    rationale: json['rationale'],
  );
}

class VitalSign {
  final String label;
  final String value;
  final bool isAbnormal;

  const VitalSign({
    required this.label,
    required this.value,
    this.isAbnormal = false,
  });

  Map<String, dynamic> toJson() => {
    'label': label,
    'value': value,
    'isAbnormal': isAbnormal,
  };

  factory VitalSign.fromJson(Map<String, dynamic> json) => VitalSign(
    label: json['label'] ?? '',
    value: json['value'] ?? '',
    isAbnormal: json['isAbnormal'] ?? false,
  );
}

class SpeakerTurn {
  final String speaker; // "Doctor", "Patient", "Nurse", "Other"
  final String text;
  final String timestamp;

  const SpeakerTurn({
    required this.speaker,
    required this.text,
    this.timestamp = '',
  });

  Map<String, dynamic> toJson() => {
    'speaker': speaker,
    'text': text,
    'timestamp': timestamp,
  };

  factory SpeakerTurn.fromJson(Map<String, dynamic> json) => SpeakerTurn(
    speaker: json['speaker'] ?? 'Other',
    text: json['text'] ?? '',
    timestamp: json['timestamp'] ?? '',
  );
}

enum ActionCategory {
  order,
  prescription,
  referral,
  priorAuth,
  billing,
}

class ClinicalActionItem {
  final String id;
  final String linkedCode;
  final ActionCategory category;
  final String title;
  final String description;
  final String urgency;
  final String? detailPayload;

  /// Marked as sent by the clinician (there is no ordering integration).
  bool isCompleted;

  /// Included in the next "Mark as sent". Defaults to on for STAT and
  /// urgent orders so they are not forgotten; routine orders are opt-in.
  bool included;

  ClinicalActionItem({
    required this.id,
    required this.linkedCode,
    required this.category,
    required this.title,
    required this.description,
    this.urgency = 'Routine',
    this.detailPayload,
    this.isCompleted = false,
    bool? included,
  }) : included = included ?? defaultIncluded(urgency);

  static bool defaultIncluded(String urgency) => const {'stat', 'urgent'}.contains(urgency.toLowerCase());

  Map<String, dynamic> toJson() => {
    'id': id,
    'linkedCode': linkedCode,
    'category': category.name,
    'title': title,
    'description': description,
    'urgency': urgency,
    'detailPayload': detailPayload,
    'isCompleted': isCompleted,
    'included': included,
  };

  factory ClinicalActionItem.fromJson(Map<String, dynamic> json) => ClinicalActionItem(
    id: json['id'] ?? '',
    linkedCode: json['linkedCode'] ?? '',
    category: ActionCategory.values.firstWhere(
      (e) => e.name == json['category'],
      orElse: () => ActionCategory.order,
    ),
    title: json['title'] ?? '',
    description: json['description'] ?? '',
    urgency: json['urgency'] ?? 'Routine',
    detailPayload: json['detailPayload'],
    isCompleted: json['isCompleted'] ?? false,
    included: json['included'] as bool?,
  );

  ClinicalActionItem copyWith({
    String? id,
    String? linkedCode,
    ActionCategory? category,
    String? title,
    String? description,
    String? urgency,
    String? detailPayload,
    bool? isCompleted,
    bool? included,
  }) {
    return ClinicalActionItem(
      id: id ?? this.id,
      linkedCode: linkedCode ?? this.linkedCode,
      category: category ?? this.category,
      title: title ?? this.title,
      description: description ?? this.description,
      urgency: urgency ?? this.urgency,
      detailPayload: detailPayload ?? this.detailPayload,
      isCompleted: isCompleted ?? this.isCompleted,
      included: included ?? this.included,
    );
  }
}

class ClinicalEncounter {
  final String id;
  final String patientName;
  final String mrn;
  final String ageGender;
  final String attendingPhysician;
  final String date;
  final List<VitalSign> vitals;
  final List<SpeakerTurn> transcript;
  final String subjective;
  final String objective;
  final String assessment;
  final String plan;
  final List<MedicalCode> codes;
  final List<ClinicalActionItem> nextSteps;
  final int latencyMs;
  final List<String> cdiRecommendations;
  /// Hex SHA-256 over the signed note text, the signer's NPI and the
  /// signing time ([signedAtUtc]). Empty until the note is signed.
  final String sha256Seal;
  final bool isSigned;
  final DateTime? signedAtUtc;
  final String rawTranscript;
  final Map<String, dynamic> gpsCoordinates;

  /// Addenda written after signing, oldest first. The signed note itself
  /// never changes once its claim is sent; corrections go here.
  final List<NoteAddendum> addenda;

  ClinicalEncounter({
    required this.id,
    required this.patientName,
    required this.mrn,
    required this.ageGender,
    required this.attendingPhysician,
    required this.date,
    required this.vitals,
    this.transcript = const [],
    required this.subjective,
    required this.objective,
    required this.assessment,
    required this.plan,
    required this.codes,
    this.nextSteps = const [],
    this.latencyMs = 12,
    this.cdiRecommendations = const [],
    this.sha256Seal = '',
    this.isSigned = false,
    this.signedAtUtc,
    this.rawTranscript = '',
    this.gpsCoordinates = const {},
    this.addenda = const [],
  });

  ClinicalEncounter copyWith({
    String? id,
    String? patientName,
    String? mrn,
    String? ageGender,
    String? attendingPhysician,
    String? date,
    List<VitalSign>? vitals,
    List<SpeakerTurn>? transcript,
    String? subjective,
    String? objective,
    String? assessment,
    String? plan,
    List<MedicalCode>? codes,
    List<ClinicalActionItem>? nextSteps,
    int? latencyMs,
    List<String>? cdiRecommendations,
    String? sha256Seal,
    bool? isSigned,
    DateTime? signedAtUtc,
    bool clearSignature = false,
    String? rawTranscript,
    Map<String, dynamic>? gpsCoordinates,
    List<NoteAddendum>? addenda,
  }) {
    return ClinicalEncounter(
      id: id ?? this.id,
      patientName: patientName ?? this.patientName,
      mrn: mrn ?? this.mrn,
      ageGender: ageGender ?? this.ageGender,
      attendingPhysician: attendingPhysician ?? this.attendingPhysician,
      date: date ?? this.date,
      vitals: vitals ?? this.vitals,
      transcript: transcript ?? this.transcript,
      subjective: subjective ?? this.subjective,
      objective: objective ?? this.objective,
      assessment: assessment ?? this.assessment,
      plan: plan ?? this.plan,
      codes: codes ?? this.codes,
      nextSteps: nextSteps ?? this.nextSteps,
      latencyMs: latencyMs ?? this.latencyMs,
      cdiRecommendations: cdiRecommendations ?? this.cdiRecommendations,
      sha256Seal: clearSignature ? '' : (sha256Seal ?? this.sha256Seal),
      isSigned: clearSignature ? false : (isSigned ?? this.isSigned),
      signedAtUtc: clearSignature ? null : (signedAtUtc ?? this.signedAtUtc),
      rawTranscript: rawTranscript ?? this.rawTranscript,
      gpsCoordinates: gpsCoordinates ?? this.gpsCoordinates,
      addenda: clearSignature ? const [] : (addenda ?? this.addenda),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'patientName': patientName,
    'mrn': mrn,
    'ageGender': ageGender,
    'attendingPhysician': attendingPhysician,
    'date': date,
    'vitals': vitals.map((v) => v.toJson()).toList(),
    'rawTranscript': rawTranscript,
    'transcript': transcript.map((t) => t.toJson()).toList(),
    'subjective': subjective,
    'objective': objective,
    'assessment': assessment,
    'plan': plan,
    'codes': codes.map((c) => c.toJson()).toList(),
    'nextSteps': nextSteps.map((n) => n.toJson()).toList(),
    'latencyMs': latencyMs,
    'cdiRecommendations': cdiRecommendations,
    'sha256Seal': sha256Seal,
    'isSigned': isSigned,
    'signedAtUtc': signedAtUtc?.toIso8601String(),
    'gpsCoordinates': gpsCoordinates,
    if (addenda.isNotEmpty) 'addenda': [for (final a in addenda) a.toJson()],
    'syncedAt': DateTime.now().toUtc().toIso8601String(),
  };

  factory ClinicalEncounter.fromJson(Map<String, dynamic> j) => ClinicalEncounter(
        id: j['id'] ?? '',
        patientName: j['patientName'] ?? '',
        mrn: j['mrn'] ?? '',
        ageGender: j['ageGender'] ?? '',
        attendingPhysician: j['attendingPhysician'] ?? '',
        date: j['date'] ?? '',
        vitals: [for (final v in (j['vitals'] as List? ?? const [])) VitalSign.fromJson((v as Map).cast<String, dynamic>())],
        transcript: [for (final t in (j['transcript'] as List? ?? const [])) SpeakerTurn.fromJson((t as Map).cast<String, dynamic>())],
        subjective: j['subjective'] ?? '',
        objective: j['objective'] ?? '',
        assessment: j['assessment'] ?? '',
        plan: j['plan'] ?? '',
        codes: [for (final c in (j['codes'] as List? ?? const [])) MedicalCode.fromJson((c as Map).cast<String, dynamic>())],
        nextSteps: [for (final n in (j['nextSteps'] as List? ?? const [])) ClinicalActionItem.fromJson((n as Map).cast<String, dynamic>())],
        latencyMs: j['latencyMs'] ?? 12,
        cdiRecommendations: List<String>.from(j['cdiRecommendations'] ?? const []),
        sha256Seal: j['sha256Seal'] ?? '',
        isSigned: j['isSigned'] == true,
        signedAtUtc: DateTime.tryParse(j['signedAtUtc'] ?? ''),
        rawTranscript: j['rawTranscript'] ?? '',
        gpsCoordinates: ((j['gpsCoordinates'] as Map?) ?? const {}).cast<String, dynamic>(),
        addenda: [for (final a in (j['addenda'] as List? ?? const [])) NoteAddendum.fromJson((a as Map).cast<String, dynamic>())],
      );

  Map<String, List<String>> get soapSections => {
    'Subjective': subjective.split('\n').where((s) => s.trim().isNotEmpty).toList(),
    'Objective': objective.split('\n').where((s) => s.trim().isNotEmpty).toList(),
    'Assessment': assessment.split('\n').where((s) => s.trim().isNotEmpty).toList(),
    'Plan': plan.split('\n').where((s) => s.trim().isNotEmpty).toList(),
  };

  bool get isLocalEngine => latencyMs < 150;

  String get attending => attendingPhysician;
}

/// A note added after signing. It is sealed on its own: the SHA-256 covers
/// the addendum text, the signer's NPI, its time and the seal of the note
/// it amends, so neither can change without the seal showing it.
class NoteAddendum {
  final String text;
  final DateTime atUtc;
  final String signerName;
  final String signerNpi;
  final String seal;

  const NoteAddendum({required this.text, required this.atUtc, required this.signerName, required this.signerNpi, required this.seal});

  /// The text that is hashed: the amended note's seal, then the addendum.
  static String sealedText(String noteSeal, String text) => 'ADDENDUM TO $noteSeal\n$text';

  factory NoteAddendum.create({
    required String text,
    required DateTime atUtc,
    required String signerName,
    required String signerNpi,
    required String noteSeal,
  }) {
    final t = text.trim();
    return NoteAddendum(
      text: t,
      atUtc: atUtc.toUtc(),
      signerName: signerName,
      signerNpi: signerNpi,
      seal: NoteSeal.compute(noteText: sealedText(noteSeal, t), signerNpi: signerNpi, signedAtUtc: atUtc.toUtc()),
    );
  }

  bool verify(String noteSeal) => NoteSeal.verify(seal: seal, noteText: sealedText(noteSeal, text), signerNpi: signerNpi, signedAtUtc: atUtc);

  Map<String, dynamic> toJson() => {
        'text': text,
        'atUtc': atUtc.toIso8601String(),
        'signerName': signerName,
        'signerNpi': signerNpi,
        'seal': seal,
      };

  factory NoteAddendum.fromJson(Map<String, dynamic> j) => NoteAddendum(
        text: '${j['text'] ?? ''}',
        atUtc: DateTime.tryParse('${j['atUtc'] ?? ''}')?.toUtc() ?? DateTime.utc(1970),
        signerName: '${j['signerName'] ?? ''}',
        signerNpi: '${j['signerNpi'] ?? ''}',
        seal: '${j['seal'] ?? ''}',
      );
}
