import '../../models/claim_models.dart';
import '../../models/clinical_models.dart';
import '../../models/patient_account.dart';
import '../codesets/icd_notes.dart';
import '../codesets/reference_data.dart';
import 'code_rules.dart';
import 'knowledge_checks.dart';
import 'place_of_service.dart';

/// Facts about the visit that change how it is coded.
class CodingContext {
  final String placeOfService;
  final bool newPatient;
  final PatientSex sex;
  final int? age;
  final Map<String, double> feeSchedule;
  final DateTime? dateOfService;

  /// Billable diagnosis codes from this patient's earlier visits, used to
  /// pick the 7th character of an injury that was already treated
  /// (CH19-INJ-01).
  final Set<String> priorDiagnosisCodes;

  const CodingContext({
    this.dateOfService,
    this.priorDiagnosisCodes = const {},
    this.placeOfService = '11',
    this.newPatient = false,
    this.sex = PatientSex.unknown,
    this.age,
    this.feeSchedule = const {},
  });
}

class CodingResult {
  final List<ClaimDiagnosis> diagnoses; // ordered: billable first (primary first), then uncertain, then integral
  final List<ServiceLine> lines;
  final MdmLevel mdm;
  final List<SpeakerTurn> turns;

  const CodingResult({required this.diagnoses, required this.lines, required this.mdm, required this.turns});

  List<ClaimDiagnosis> get billable => diagnoses.where((d) => d.status == DxStatus.billable).toList();
}

class _SymptomTerm {
  final RegExp pattern;
  final String code;
  final String description;
  const _SymptomTerm(this.pattern, this.code, this.description);
}

class _DiagnosisTerm {
  final RegExp pattern;
  final String code;
  final String description;
  final bool chronic;
  final RegExp? management; // medications or tests that show it is being managed
  final bool acuteHighRisk;
  const _DiagnosisTerm(this.pattern, this.code, this.description, {this.chronic = false, this.management, this.acuteHighRisk = false});
}

RegExp _re(String p) => RegExp(p, caseSensitive: false);

/// Converts a visit conversation into ICD-10-CM diagnoses and CPT/HCPCS
/// service lines, following the outpatient coding rules a certified coder
/// applies:
///
/// - The patient's own words ("my head is pounding") become symptom codes.
/// - Physician diagnoses are coded only when stated without hedging. Under
///   ICD-10-CM guideline IV.H, "sounds like", "suspicious for", "consistent
///   with" and similar terms mean the symptoms are coded instead.
/// - Symptoms that are part of a confirmed diagnosis are not coded separately.
/// - The E/M code comes from the place of service, new vs established status
///   and the level of medical decision making.
/// - Tests that are only ordered (MRI, outside X-ray) are not billed here.
class ClinicalCoder {
  static final _hedge = _re(
    r'\b(probable|probably|possible|possibly|suspect(ed)?|suspicious for|likely|rule out|r/o|consistent with|compatible with|'
    r'questionable|concern(ing)? for|may be|might be|could be|sounds like|presum\w*|working diagnosis|differential|versus|vs\.?)\b',
  );

  static final _negation = _re(r'\b(no|not|denies|denied|without|never|negative for|free of)\b[^.?!,;]{0,30}$');

  static final List<_SymptomTerm> _symptoms = [
    _SymptomTerm(_re(r'(chest|retrosternal)[^.?!]{0,30}(pressure|tight|crush|squeez|heavy)|(crush\w*|squeez\w*|tight\w*|heavy)[^.?!]{0,15}(chest|retrosternal)|elephant[^.?!]{0,25}chest'), 'R07.89', 'Other chest pain'),
    _SymptomTerm(_re(r'(chest|retrosternal)[^.?!]{0,25}(pain|hurt|ache)|pain[^.?!]{0,15}\bchest'), 'R07.9', 'Chest pain, unspecified'),
    _SymptomTerm(_re(r'(sharp|stabbing)[^.?!]{0,40}(breathe|breath in|inhale)|(breathe|breath) in[^.?!]{0,50}(sharp|stabbing)|pleuritic'), 'R07.81', 'Pleurodynia'),
    _SymptomTerm(_re(r'\bjaw\b[^.?!]{0,20}(pain|hurt|ache)|(pain|radiat\w*)[^.?!]{0,30}\bjaw\b'), 'R68.84', 'Jaw pain'),
    _SymptomTerm(_re(r'\b(sweating|diaphore\w*|drenched|sweaty)\b'), 'R61', 'Generalized hyperhidrosis'),
    _SymptomTerm(_re(r"short(ness)? of breath|winded|can'?t (catch|get) my breath|trouble breathing|difficulty breathing|out of breath|dyspnea"), 'R06.02', 'Shortness of breath'),
    _SymptomTerm(_re(r'\bwheez\w*'), 'R06.2', 'Wheezing'),
    _SymptomTerm(_re(r'\bcough\w*'), 'R05.9', 'Cough, unspecified'),
    _SymptomTerm(_re(r'\b(fever|feverish|chills|temperature of)\b'), 'R50.9', 'Fever, unspecified'),
    _SymptomTerm(_re(r'(nause\w*|queasy)[^.?!]{0,60}(vomit\w*|threw up|throwing up)|(vomit\w*|threw up|throwing up)[^.?!]{0,60}nause\w*'), 'R11.2', 'Nausea with vomiting, unspecified'),
    _SymptomTerm(_re(r'\b(nause\w*|queasy|sick to my stomach)\b'), 'R11.0', 'Nausea'),
    _SymptomTerm(_re(r'\b(vomit\w*|threw up|throwing up)\b'), 'R11.10', 'Vomiting, unspecified'),
    _SymptomTerm(_re(r'(epigastric|upper (stomach|belly|abdomen))[^.?!]{0,20}(pain|ache|burn)'), 'R10.13', 'Epigastric pain'),
    _SymptomTerm(_re(r'(stomach|belly|abdominal|abdomen|tummy)[^.?!]{0,20}(pain|ache|hurt|cramp)|(pain|cramp\w*)[^.?!]{0,20}(stomach|belly|abdomen)'), 'R10.9', 'Unspecified abdominal pain'),
    _SymptomTerm(_re(r'\b(diarrh\w*|loose stools?)\b'), 'R19.7', 'Diarrhea, unspecified'),
    _SymptomTerm(_re(r'\b(dizz\w*|light[- ]?headed|room (is )?spinning)\b'), 'R42', 'Dizziness and giddiness'),
    _SymptomTerm(_re(r"\b(i'?m|i am|i feel|i've been|feeling) (so |really |very )?(tired|exhausted|fatigued|wiped out)"), 'R53.83', 'Other fatigue'),
    _SymptomTerm(_re(r'\b(numb\w*)\b'), 'R20.0', 'Anesthesia of skin'),
    _SymptomTerm(_re(r'pins and needles|tingl\w*|burning (sensation|feeling)|terrible burning'), 'R20.2', 'Paresthesia of skin'),
    _SymptomTerm(_re(r'(head\s*ache|headache|migraine|head is (pounding|killing|throbbing)|pain[^.?!]{0,20}(side of|behind) my (head|eye)|throbbing, pounding pain)'), 'R51.9', 'Headache, unspecified'),
    _SymptomTerm(_re(r'(bright )?light[^.?!]{0,20}(hurts?|bothers?|sensitiv|feels like)|photophobia|sensitive to light'), 'H53.149', 'Visual discomfort, unspecified'),
    _SymptomTerm(_re(r'zigzag|blind spots|shimmering|seeing spots|visual aura'), 'H53.19', 'Other subjective visual disturbances'),
    _SymptomTerm(_re(r'(lower |low )back[^.?!]{0,15}(pain|hurt|ache)'), 'M54.50', 'Low back pain, unspecified'),
    _SymptomTerm(_re(r'\bneck[^.?!]{0,15}(pain|hurt|ache|stiff)'), 'M54.2', 'Cervicalgia'),
    _SymptomTerm(_re(r'sore throat|throat (hurts|is sore|pain)'), 'R07.0', 'Pain in throat'),
    _SymptomTerm(_re(r'\bear\b[^.?!]{0,15}(pain|hurt|ache)|earache'), 'H92.09', 'Otalgia, unspecified ear'),
    _SymptomTerm(_re(r'\brash\b'), 'R21', 'Rash and other nonspecific skin eruption'),
    _SymptomTerm(_re(r'palpitation\w*|heart (is )?(racing|pounding|fluttering)'), 'R00.2', 'Palpitations'),
    _SymptomTerm(_re(r'(burn\w*|hurts?|pain)[^.?!]{0,20}(pee|urinat\w*)|dysuria'), 'R30.0', 'Dysuria'),
    _SymptomTerm(_re(r'(pee|urinat\w*)[^.?!]{0,15}(all the time|a lot|frequently|constantly)|frequent urination'), 'R35.0', 'Frequency of micturition'),
    _SymptomTerm(_re(r"can'?t (fall |stay )?asleep|can'?t sleep|trouble sleeping|insomnia"), 'G47.00', 'Insomnia, unspecified'),
    _SymptomTerm(_re(r'(swollen|swelling)[^.?!]{0,20}(legs?|ankles?|feet)'), 'R60.0', 'Localized edema'),
    _SymptomTerm(_re(r'stuffy nose|nasal congestion|congested'), 'R09.81', 'Nasal congestion'),
    _SymptomTerm(_re(r'passed out|fainted|blacked out'), 'R55', 'Syncope and collapse'),
    _SymptomTerm(_re(r'\bweak(ness)?\b'), 'R53.1', 'Weakness'),
  ];

  static final List<_DiagnosisTerm> _diagnoses = [
    _DiagnosisTerm(_re(r'inferior[^.?!]{0,25}(stemi|st[- ]?(segment )?elevation)|(stemi|st[- ]?elevation)[^.?!]{0,40}inferior'), 'I21.19',
        'ST elevation (STEMI) myocardial infarction involving other coronary artery of inferior wall', acuteHighRisk: true),
    _DiagnosisTerm(_re(r'\bstemi\b|st[- ]elevation myocardial'), 'I21.3', 'ST elevation (STEMI) myocardial infarction of unspecified site', acuteHighRisk: true),
    _DiagnosisTerm(_re(r'\bnstemi\b|non[- ]st[- ]elevation'), 'I21.4', 'Non-ST elevation (NSTEMI) myocardial infarction', acuteHighRisk: true),
    _DiagnosisTerm(_re(r'lobar pneumonia|pneumonia[^.?!]{0,40}\blobe\b|\blobe\b[^.?!]{0,20}pneumonia'), 'J18.1', 'Lobar pneumonia, unspecified organism'),
    _DiagnosisTerm(_re(r'pneumonia'), 'J18.9', 'Pneumonia, unspecified organism'),
    _DiagnosisTerm(_re(r'migraine with aura'), 'G43.109', 'Migraine with aura, not intractable, without status migrainosus'),
    _DiagnosisTerm(_re(r'migraine'), 'G43.909', 'Migraine, unspecified, not intractable, without status migrainosus'),
    _DiagnosisTerm(_re(r'tension(-type)? headache'), 'G44.209', 'Tension-type headache, unspecified, not intractable'),
    _DiagnosisTerm(_re(r'diabetic (peripheral )?(poly)?neuropathy'), 'E11.42', 'Type 2 diabetes mellitus with diabetic polyneuropathy', chronic: true),
    _DiagnosisTerm(_re(r'(uncontrolled|poorly controlled|out of control)[^.?!]{0,20}diabet|diabet\w*[^.?!]{0,20}hyperglyc'), 'E11.65', 'Type 2 diabetes mellitus with hyperglycemia', chronic: true),
    _DiagnosisTerm(_re(r'\bdiabet\w*'), 'E11.9', 'Type 2 diabetes mellitus without complications', chronic: true,
        management: _re(r'metformin|insulin|glipizide|jardiance|ozempic|a1c|glycemic|sugar')),
    _DiagnosisTerm(_re(r'hypertension|high blood pressure'), 'I10', 'Essential (primary) hypertension', chronic: true,
        management: _re(r'lisinopril|amlodipine|losartan|hydrochlorothiazide|metoprolol')),
    _DiagnosisTerm(_re(r'hyperlipidemia|high cholesterol'), 'E78.5', 'Hyperlipidemia, unspecified', chronic: true, management: _re(r'statin|atorvastatin|rosuvastatin')),
    _DiagnosisTerm(_re(r'hypothyroid\w*'), 'E03.9', 'Hypothyroidism, unspecified', chronic: true, management: _re(r'levothyroxine|synthroid')),
    _DiagnosisTerm(_re(r'asthma[^.?!]{0,20}(exacerbation|attack|flare)'), 'J45.901', 'Unspecified asthma with (acute) exacerbation'),
    _DiagnosisTerm(_re(r'\basthma\b'), 'J45.909', 'Unspecified asthma, uncomplicated', chronic: true, management: _re(r'albuterol|inhaler')),
    _DiagnosisTerm(_re(r'\bcopd\b|chronic obstructive'), 'J44.9', 'Chronic obstructive pulmonary disease, unspecified', chronic: true),
    _DiagnosisTerm(_re(r'\bgerd\b|acid reflux|reflux disease'), 'K21.9', 'Gastro-esophageal reflux disease without esophagitis', chronic: true,
        management: _re(r'omeprazole|pantoprazole|famotidine')),
    _DiagnosisTerm(_re(r'urinary tract infection|\buti\b'), 'N39.0', 'Urinary tract infection, site not specified'),
    _DiagnosisTerm(_re(r'strep throat|streptococcal pharyngitis'), 'J02.0', 'Streptococcal pharyngitis'),
    _DiagnosisTerm(_re(r'pharyngitis'), 'J02.9', 'Acute pharyngitis, unspecified'),
    _DiagnosisTerm(_re(r'sinusitis'), 'J01.90', 'Acute sinusitis, unspecified'),
    _DiagnosisTerm(_re(r'medial meniscal tear|tear of the medial meniscus|medial meniscus tear'), 'S83.24', 'Other tear of medial meniscus, current injury, knee'),
    _DiagnosisTerm(_re(r'hemarthrosis'), 'M25.06', 'Hemarthrosis, knee'),
    _DiagnosisTerm(_re(r'osteoarthritis[^.?!]{0,20}knee|knee osteoarthritis'), 'M17.9', 'Osteoarthritis of knee, unspecified'),
    _DiagnosisTerm(_re(r'gastroenteritis|stomach bug'), 'A09', 'Infectious gastroenteritis and colitis, unspecified'),
    _DiagnosisTerm(_re(r'heart failure'), 'I50.9', 'Heart failure, unspecified', chronic: true),
    _DiagnosisTerm(_re(r'end[- ]stage renal disease|end[- ]stage kidney disease|\besrd\b'), 'N18.6', 'End stage renal disease', chronic: true),
    _DiagnosisTerm(_re(r'(chronic kidney disease|\bckd\b),? stage (5|v)\b|stage (5|v) (chronic kidney disease|ckd)'), 'N18.5', 'Chronic kidney disease, stage 5', chronic: true),
    _DiagnosisTerm(_re(r'(chronic kidney disease|\bckd\b),? stage (4|iv)\b|stage (4|iv) (chronic kidney disease|ckd)'), 'N18.4', 'Chronic kidney disease, stage 4 (severe)', chronic: true),
    _DiagnosisTerm(_re(r'(chronic kidney disease|\bckd\b),? stage (3b|iiib)\b|stage (3b|iiib) (chronic kidney disease|ckd)'), 'N18.32', 'Chronic kidney disease, stage 3b', chronic: true),
    _DiagnosisTerm(_re(r'(chronic kidney disease|\bckd\b),? stage (3a|iiia)\b|stage (3a|iiia) (chronic kidney disease|ckd)'), 'N18.31', 'Chronic kidney disease, stage 3a', chronic: true),
    _DiagnosisTerm(_re(r'(chronic kidney disease|\bckd\b),? stage (3|iii)\b|stage (3|iii) (chronic kidney disease|ckd)'), 'N18.30', 'Chronic kidney disease, stage 3 unspecified', chronic: true),
    _DiagnosisTerm(_re(r'(chronic kidney disease|\bckd\b),? stage (2|ii)\b|stage (2|ii) (chronic kidney disease|ckd)'), 'N18.2', 'Chronic kidney disease, stage 2 (mild)', chronic: true),
    _DiagnosisTerm(_re(r'(chronic kidney disease|\bckd\b),? stage (1|i)\b|stage (1|i) (chronic kidney disease|ckd)'), 'N18.1', 'Chronic kidney disease, stage 1', chronic: true),
    _DiagnosisTerm(_re(r'chronic kidney disease|\bckd\b'), 'N18.9', 'Chronic kidney disease, unspecified', chronic: true),
    _DiagnosisTerm(_re(r'coronary artery disease|\bcad\b'), 'I25.10', 'Atherosclerotic heart disease of native coronary artery without angina pectoris', chronic: true),
    _DiagnosisTerm(_re(r'atrial fibrillation|\bafib\b|a-fib'), 'I48.91', 'Unspecified atrial fibrillation', chronic: true),
    _DiagnosisTerm(_re(r'allergic rhinitis|hay fever'), 'J30.9', 'Allergic rhinitis, unspecified'),
    _DiagnosisTerm(_re(r'otitis media|ear infection'), 'H66.90', 'Otitis media, unspecified, unspecified ear'),
    _DiagnosisTerm(_re(r'cellulitis'), 'L03.90', 'Cellulitis, unspecified'),
    _DiagnosisTerm(_re(r'\bdepression\b|depressive disorder'), 'F32.A', 'Depression, unspecified', chronic: true),
    _DiagnosisTerm(_re(r'anxiety disorder|generalized anxiety'), 'F41.9', 'Anxiety disorder, unspecified', chronic: true),
  ];

  // ---------------------------------------------------------------------------
  // Speaker separation
  // ---------------------------------------------------------------------------

  static final _speakerTag = _re(r'^(doctor|dr\.?|patient|nurse|provider|caregiver|family|physician)\s*:\s*(.*)$');

  /// Splits a conversation into speaker turns. Uses "Doctor:" / "Patient:"
  /// labels when present; otherwise infers the speaker of each sentence from
  /// how it is phrased (questions, exam language and orders are the
  /// physician; first-person symptoms and answers are the patient). Live
  /// microphone text has no labels, so this is what keeps the patient's words
  /// from being attributed to the doctor.
  static List<SpeakerTurn> diarize(String text) {
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final hasTags = lines.any((l) => _speakerTag.hasMatch(l));
    final turns = <SpeakerTurn>[];

    if (hasTags) {
      var speaker = 'Doctor';
      final buffer = StringBuffer();
      void flush() {
        if (buffer.isEmpty) return;
        turns.add(SpeakerTurn(speaker: speaker, text: buffer.toString().trim(), timestamp: _ts(turns.length)));
        buffer.clear();
      }

      for (final line in lines) {
        final m = _speakerTag.firstMatch(line);
        if (m != null) {
          flush();
          speaker = _role(m.group(1)!);
          buffer.write(m.group(2) ?? '');
        } else {
          if (buffer.isNotEmpty) buffer.write(' ');
          buffer.write(line);
        }
      }
      flush();
      return turns;
    }

    final sentences = splitSentences(text);
    String? previous;
    var previousWasQuestion = false;
    for (final s in sentences) {
      final speaker = _inferSpeaker(s, previous: previous, previousWasQuestion: previousWasQuestion);
      if (turns.isNotEmpty && turns.last.speaker == speaker) {
        final last = turns.removeLast();
        turns.add(SpeakerTurn(speaker: speaker, text: '${last.text} $s', timestamp: last.timestamp));
      } else {
        turns.add(SpeakerTurn(speaker: speaker, text: s, timestamp: _ts(turns.length)));
      }
      previous = speaker;
      previousWasQuestion = s.trim().endsWith('?');
    }
    return turns;
  }

  static String _ts(int i) {
    final secs = i * 12;
    return '${(secs ~/ 60).toString().padLeft(2, '0')}:${(secs % 60).toString().padLeft(2, '0')}';
  }

  static String _role(String raw) {
    final r = raw.toLowerCase().replaceAll('.', '');
    if (r == 'doctor' || r == 'dr' || r == 'provider' || r == 'physician') return 'Doctor';
    if (r == 'patient') return 'Patient';
    if (r == 'nurse') return 'Nurse';
    return 'Caregiver';
  }

  static List<String> splitSentences(String text) => text
      .replaceAll('\n', ' ')
      .split(RegExp(r'(?<=[.!?])\s+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  static final _doctorCues = _re(
    r"^(how|what|when|where|which|any|do you|does it|did you|have you|are you|is it|can you|tell me|let'?s|let me|i'?m going to|i want|i am prescribing|"
    r"we('| a)re going|we need|we will|we'?ll|take a deep|on exam|looking at|nurse|team)|"
    r'\b(exam\w*|vitals?|blood pressure|heart rate|oxygen saturation|prescrib\w*|diagnos\w*|consistent with|presentation|'
    r'follow up|refer\w*|order\w*|x-ray|mri|ekg|ecg|mg\b|tablets?|capsules?|twice a day|at bedtime|lungs|auscultat\w*|tenderness|effusion|'
    r'cranial nerves|reflexes|lachman|mcmurray|we are moving|activate|cath lab|stat\b|required|indicated|recommend\w*)',
  );

  static final _patientCues = _re(
    r"^(yes|yeah|no|nope|oh|ugh|um|well|about|maybe|i think|doc|doctor,)|\b(i have|i've|i'?m|i feel|i felt|i can'?t|i was|i got|i heard|i caught|"
    r'my (head|chest|feet|foot|knee|back|stomach|throat|ear|arm|leg|sugar|diabetes|grandson|daughter|wife|husband)|it hurts|it started|it feels|hurts)\b',
  );

  static String _inferSpeaker(String s, {String? previous, bool previousWasQuestion = false}) {
    final l = s.toLowerCase().trim();
    final doctorScore = _doctorCues.allMatches(l).length + (l.endsWith('?') && !l.startsWith('is that') && !l.startsWith('should i') ? 1 : 0);
    final patientScore = _patientCues.allMatches(l).length + (previousWasQuestion && previous == 'Doctor' ? 1 : 0);
    if (patientScore > doctorScore) return 'Patient';
    if (doctorScore > patientScore) return 'Doctor';
    // Tie: an answer follows a question; otherwise the same person is still
    // talking (dictation is one speaker).
    if (previousWasQuestion) return previous == 'Doctor' ? 'Patient' : 'Doctor';
    return previous ?? 'Doctor';
  }

  // ---------------------------------------------------------------------------
  // Coding
  // ---------------------------------------------------------------------------

  static CodingResult code({
    required List<SpeakerTurn> turns,
    required List<VitalSign> vitals,
    required CodingContext context,
  }) =>
      // Tabular notes and Excludes1 pairs follow the visit's date of service.
      ReferenceData.atDateOfService(context.dateOfService, () => _code(turns: turns, vitals: vitals, context: context));

  static CodingResult _code({
    required List<SpeakerTurn> turns,
    required List<VitalSign> vitals,
    required CodingContext context,
  }) {
    final setting = placeOfService(context.placeOfService).setting;
    final inpatient = setting == EmSetting.inpatient;

    final patientSentences = <String>[];
    final doctorSentences = <String>[];
    for (final t in turns) {
      final target = t.speaker == 'Doctor' || t.speaker == 'Nurse' ? doctorSentences : patientSentences;
      target.addAll(splitSentences(t.text));
    }
    final doctorText = doctorSentences.join(' ').toLowerCase();
    final allText = [...patientSentences, ...doctorSentences].join(' ').toLowerCase();

    final found = <String, ClaimDiagnosis>{};
    void add(ClaimDiagnosis d) {
      final existing = found[d.code];
      // Prefer the strongest source: physician over exam over patient.
      if (existing == null || (existing.status != DxStatus.billable && d.status == DxStatus.billable)) {
        found[d.code] = d;
      }
    }

    // 1. Physician diagnoses, with certainty.
    final laterality = _laterality(allText);
    for (final term in _diagnoses) {
      String? confirmedSentence;
      String? hedgedSentence;
      for (final s in doctorSentences) {
        if (s.trim().endsWith('?')) continue;
        if (!term.pattern.hasMatch(s)) continue;
        if (_isNegated(s, term.pattern)) continue;
        if (_hedge.hasMatch(s) && !inpatient) {
          hedgedSentence ??= s;
        } else {
          confirmedSentence ??= s;
        }
      }
      // Chronic conditions the patient reports ("my diabetes") and the
      // physician is actively managing are coded as history.
      String? historySentence;
      if (confirmedSentence == null && term.chronic && term.management != null) {
        for (final s in patientSentences) {
          if (_re(r'\bmy\b[^.?!]{0,15}').hasMatch(s) && term.pattern.hasMatch(s) && term.management!.hasMatch(doctorText)) {
            historySentence = s;
            break;
          }
        }
      }
      final initial = _withLaterality(term.code, laterality);
      final code = _withLaterality(term.code, laterality, seventh: _injurySeventh(initial, context.priorDiagnosisCodes, doctorText));
      final description = _describeLaterality(term.description, code);
      if (confirmedSentence != null) {
        add(ClaimDiagnosis(code: code, description: description, source: DxSource.physicianConfirmed, evidence: confirmedSentence));
      } else if (historySentence != null) {
        add(ClaimDiagnosis(code: code, description: description, source: DxSource.history, evidence: historySentence));
      } else if (hedgedSentence != null) {
        final hedge = _hedge.firstMatch(hedgedSentence)!.group(0)!;
        add(ClaimDiagnosis(
          code: code,
          description: description,
          source: DxSource.physicianConfirmed,
          status: DxStatus.uncertain,
          evidence: hedgedSentence,
          note: 'Documented as "$hedge". Outpatient rule IV.H codes the symptoms until you confirm it.',
        ));
      }
    }
    // Keep only the most specific code when a family matched twice
    // (E11.42 beats E11.9, I21.19 beats I21.3, J18.1 beats J18.9).
    _dropLessSpecific(found);
    // Hypertension with heart failure or CKD is a combination code.
    combineHypertension(found, doctorSentences);
    // ICD-COMBO-01: other combination codes the Index lists with "with".
    combineFromIndex(found, context.dateOfService ?? DateTime.now());
    // CH4-DM-01: long-term diabetes drug codes.
    addLongTermDrugCodes(found, [...patientSentences, ...doctorSentences]);
    // OP-PREOP-01: preoperative evaluation, Z01.81- first.
    final preop = doctorSentences.where(_preop.hasMatch).firstOrNull;
    if (preop != null) {
      final (code, description) = _re(r'cardi|heart|ekg|ecg').hasMatch(preop)
          ? ('Z01.810', 'Encounter for preprocedural cardiovascular examination')
          : _re(r'pulmonar|respirat|lung').hasMatch(preop)
              ? ('Z01.811', 'Encounter for preprocedural respiratory examination')
              : ('Z01.818', 'Encounter for other preprocedural examination');
      add(ClaimDiagnosis(
        code: code,
        description: description,
        source: DxSource.physicianConfirmed,
        evidence: preop,
        note: 'Preoperative evaluation: Z01.81- is listed first, then the reason for surgery (guideline IV.M).',
      ));
    }

    // 2. Patient-reported symptoms, in the patient's own words, plus symptoms
    // the physician reports in dictation ("patient has burning feet").
    final reported = _re(r'\b(patient|pt|he|she)\b[^.?!]{0,12}\b(has|had|reports?|complains?|presents?|states?|describes?|notes?)\b|complains of|presents with|\bc/o\b');
    // A single-speaker dictation has no patient turns; then every dictated
    // sentence is a candidate.
    final symptomSentences = patientSentences.isEmpty ? doctorSentences : [...patientSentences, ...doctorSentences.where(reported.hasMatch)];
    for (final s in symptomSentences) {
      if (s.trim().endsWith('?') && !_re(r'^(is|should|can|could|will|do)\b').hasMatch(s.trim().toLowerCase())) continue;
      // Code symptoms in the order they were said, so the complaint the
      // patient led with becomes the primary diagnosis.
      final hits = <(int, _SymptomTerm)>[];
      for (final term in _symptoms) {
        final m = term.pattern.firstMatch(s);
        if (m == null || _isNegated(s.substring(0, m.start + 1 > s.length ? s.length : m.start + 1), null)) continue;
        hits.add((m.start, term));
      }
      hits.sort((a, b) => a.$1.compareTo(b.$1));
      for (final (_, term) in hits) {
        add(ClaimDiagnosis(code: term.code, description: term.description, source: DxSource.patientReported, evidence: s));
      }
      // Outside the built-in vocabulary: look the patient's words up in the
      // official ICD-10-CM index. Offered for confirmation, never billed on
      // its own, because index matches on free speech can be wrong.
      if (hits.isEmpty) {
        final dos = context.dateOfService ?? DateTime.now();
        final index = ReferenceData.indexFor(dos);
        final icd = ReferenceData.icdFor(dos);
        if (index != null && icd != null) {
          for (final sug in index.suggest(s, limit: 2)) {
            if (!icd.isBillable(sug.code) || found.containsKey(sug.code)) continue;
            add(ClaimDiagnosis(
              code: sug.code,
              description: icd.description(sug.code) ?? sug.path.replaceAll('|', ', '),
              source: DxSource.patientReported,
              status: DxStatus.uncertain,
              evidence: s,
              note: 'Suggested from the ICD-10-CM index ("${sug.path.replaceAll('|', ', ')}"). Confirm if it applies.',
            ));
            break;
          }
        }
      }
    }
    // Nausea with vomiting replaces the separate codes.
    if (found.containsKey('R11.2')) {
      found.remove('R11.0');
      found.remove('R11.10');
    } else if (found.containsKey('R11.0') && found.containsKey('R11.10')) {
      final ev = found['R11.0']!.evidence;
      found.remove('R11.0');
      found.remove('R11.10');
      add(ClaimDiagnosis(code: 'R11.2', description: 'Nausea with vomiting, unspecified', source: DxSource.patientReported, evidence: ev));
    }
    if (found.containsKey('R07.89')) found.remove('R07.9');

    // Knee pain needs laterality.
    if (_re(r'knee[^.?!]{0,30}(pain|hurt|ache|twist|injur|swoll|pop)|(twist|injur|pop)[^.?!]{0,30}knee').hasMatch(allText)) {
      final code = laterality == 'right' ? 'M25.561' : laterality == 'left' ? 'M25.562' : 'M25.569';
      final side = laterality ?? 'unspecified';
      add(ClaimDiagnosis(
        code: code,
        description: 'Pain in ${side == 'unspecified' ? 'unspecified' : side} knee',
        source: DxSource.patientReported,
        evidence: patientSentences.firstWhere((s) => s.toLowerCase().contains('knee'), orElse: () => ''),
      ));
    }

    // 3. Objective findings from the exam and vitals.
    if (_re(r'effusion|(knee|joint)[^.?!]{0,30}(swelling|swollen)|(swelling|swollen)[^.?!]{0,30}knee').hasMatch(doctorText) && doctorText.contains('knee')) {
      final code = laterality == 'right' ? 'M25.461' : laterality == 'left' ? 'M25.462' : 'M25.469';
      add(ClaimDiagnosis(
        code: code,
        description: 'Effusion, ${laterality ?? 'unspecified'} knee',
        source: DxSource.examFinding,
        evidence: doctorSentences.firstWhere((s) => _re(r'effusion|swell|swollen').hasMatch(s), orElse: () => ''),
      ));
    }
    for (final v in vitals) {
      final n = int.tryParse(RegExp(r'\d+').firstMatch(v.value)?.group(0) ?? '');
      if (n == null) continue;
      if (v.label == 'BP' && n < 90) {
        add(ClaimDiagnosis(code: 'I95.9', description: 'Hypotension, unspecified', source: DxSource.examFinding, evidence: 'BP ${v.value}'));
      }
      if (v.label == 'Heart Rate' && n > 100) {
        add(ClaimDiagnosis(code: 'R00.0', description: 'Tachycardia, unspecified', source: DxSource.examFinding, evidence: 'Heart rate ${v.value}'));
      }
      if (v.label == 'SpO2' && n < 90) {
        add(ClaimDiagnosis(code: 'R09.02', description: 'Hypoxemia', source: DxSource.examFinding, evidence: 'SpO2 ${v.value}'));
      }
      if (v.label == 'Temp' && v.isAbnormal) {
        add(ClaimDiagnosis(code: 'R50.9', description: 'Fever, unspecified', source: DxSource.examFinding, evidence: 'Temperature ${v.value}'));
      }
    }

    final diagnoses = finalizeDiagnoses(found.values.toList());

    // 6. Services.
    final billableDx = diagnoses.where((d) => d.status == DxStatus.billable).toList();
    final mdm = _mdm(doctorText, billableDx);
    final lines = <ServiceLine>[];
    double fee(String c) => context.feeSchedule[c] ?? 0;

    final em = emCodeFor(setting, newPatient: context.newPatient, mdm: mdm);
    if (em != null) {
      lines.add(ServiceLine(
        code: em,
        description: emDescription(em),
        charge: fee(em),
        modifiers: isTelehealthPos(context.placeOfService) ? const ['95'] : const [],
        evidence: 'Place of service ${context.placeOfService}, ${context.newPatient ? 'new' : 'established'} patient, ${mdm.name} medical decision making',
      ));
    } else if (setting == EmSetting.ambulance) {
      final als = _re(r'cardiac monitor|\biv\b|ekg|ecg|intubat|medication|aspirin|nitro').hasMatch(allText);
      final code = als ? 'A0427' : 'A0429';
      lines.add(ServiceLine(
        code: code,
        description: als ? 'Ambulance service, advanced life support, emergency transport, level 1 (ALS1)' : 'Ambulance service, basic life support, emergency transport (BLS)',
        charge: fee(code),
      ));
      lines.add(ServiceLine(code: 'A0425', description: 'Ground mileage, per statute mile', charge: fee('A0425'), evidence: 'Enter loaded miles as units'));
    }

    final facility = {'19', '21', '22', '23'}.contains(context.placeOfService);
    if (_re(r'(looking at|reviewed?|perform\w*|interpret\w*|shows|right here)[^.?!]{0,40}(12[- ]lead|ekg|ecg|electrocardiogram)|(12[- ]lead|ekg|ecg)[^.?!]{0,30}(shows|reveals|right here|demonstrates)').hasMatch(doctorText)) {
      final code = facility ? '93010' : '93000';
      lines.add(ServiceLine(
        code: code,
        description: facility ? 'Electrocardiogram, interpretation and report only' : 'Electrocardiogram, routine ECG with at least 12 leads; with interpretation and report',
        charge: fee(code),
        evidence: doctorSentences.firstWhere((s) => _re(r'ekg|ecg|12-lead').hasMatch(s), orElse: () => ''),
      ));
    }
    if (_re(r'(aspirat\w*|inject\w*|arthrocentesis)[^.?!]{0,40}(knee|shoulder|hip)|(knee|shoulder|hip)[^.?!]{0,30}(aspirat\w*|injection)').hasMatch(doctorText) &&
        !_re(r'(will|going to|plan to|may need)[^.?!]{0,20}(aspirat|inject)').hasMatch(doctorText)) {
      lines.add(ServiceLine(code: '20610', description: 'Arthrocentesis, aspiration and/or injection, major joint or bursa', charge: fee('20610')));
    }
    if (_re(r'nebuli[sz]\w*').hasMatch(doctorText) && !facility) {
      lines.add(ServiceLine(code: '94640', description: 'Pressurized or nonpressurized inhalation treatment (nebulizer)', charge: fee('94640')));
    }
    if (_re(r'rapid strep').hasMatch(doctorText) && !facility) {
      lines.add(ServiceLine(code: '87880', description: 'Infectious agent antigen detection, Streptococcus group A (rapid strep)', charge: fee('87880')));
    }
    if (_re(r'urine dip|dipstick').hasMatch(doctorText) && !facility) {
      lines.add(ServiceLine(code: '81002', description: 'Urinalysis, non-automated, without microscopy', charge: fee('81002')));
    }

    return CodingResult(
      diagnoses: diagnoses,
      lines: assignPointers(lines, billableDx),
      mdm: mdm,
      turns: turns,
    );
  }

  static final _preop = _re(r'pre-?op(erative)? (evaluation|exam\w*|clearance|visit|assessment)|(surgical|medical|cardiac) clearance|clearance for (surgery|the procedure)');

  static final _insulin = _re(r'\binsulin\b|lantus|glargine|humalog|novolog|lispro|aspart|levemir|tresiba');
  static final _insulinTemporary = _re(r'temporar\w*|sliding scale|one[- ]time|stat dose|in the office today|just today');
  static final _oralAntidiabetic = _re(r'metformin|glucophage|glipizide|glyburide|glimepiride|sitagliptin|januvia|pioglitazone|actos|'
      r'jardiance|empagliflozin|dapagliflozin|farxiga|canagliflozin|invokana|rybelsus|linagliptin|tradjenta');
  static final _injectableNonInsulin = _re(r'ozempic|trulicity|dulaglutide|liraglutide|victoza|mounjaro|tirzepatide|exenatide|byetta|bydureon|semaglutide injection');
  static final _currentUse = _re(r'\b(take|takes|taking|on|continue|continuing|refill\w*|uses?|using|my)\b');
  static final _stopped = _re(r'\b(stop\w*|discontinu\w*|quit|no longer|off)\b');

  /// CH4-DM-01 (guideline I.C.4.a.3; Tabular "use additional code" at
  /// E08-E13). Adds Z79.4, Z79.84 and Z79.85 when a billable diabetes code is
  /// present and the conversation documents current use of insulin, oral
  /// hypoglycemics or injectable non-insulin antidiabetic drugs. Insulin given
  /// only temporarily during the encounter is not long-term use.
  static void addLongTermDrugCodes(Map<String, ClaimDiagnosis> found, List<String> sentences) {
    final diabetes = found.values.any((d) => d.status == DxStatus.billable && RegExp(r'^E(08|09|10|11|13)').hasMatch(d.code));
    if (!diabetes) return;
    String? evidence(RegExp drug, {RegExp? exclude}) => sentences
        .where((s) => drug.hasMatch(s) && _currentUse.hasMatch(s) && !_stopped.hasMatch(s) && !(exclude?.hasMatch(s) ?? false) && !s.trim().endsWith('?'))
        .firstOrNull;
    void addZ(String code, String description, String? ev) {
      if (ev == null || found.containsKey(code)) return;
      found[code] = ClaimDiagnosis(
        code: code,
        description: description,
        source: DxSource.history,
        evidence: ev,
        note: 'Long-term (current) drug use with diabetes (guideline I.C.4.a.3).',
      );
    }

    addZ('Z79.4', 'Long term (current) use of insulin', evidence(_insulin, exclude: _insulinTemporary));
    addZ('Z79.84', 'Long term (current) use of oral hypoglycemic drugs', evidence(_oralAntidiabetic));
    addZ('Z79.85', 'Long-term (current) use of injectable non-insulin antidiabetic drugs', evidence(_injectableNonInsulin));
  }

  /// ICD-COMBO-01 (guidelines I.B.9, I.A.15). Two confirmed diagnoses that
  /// the Alphabetic Index joins with "with" become the combination code, in
  /// place of the first. The second is kept only when the combination code's
  /// own "use additional code" or "code also" note asks for it, or when the
  /// Tabular notes are not loaded.
  static void combineFromIndex(Map<String, ClaimDiagnosis> found, DateTime dateOfService) {
    final index = ReferenceData.indexFor(dateOfService);
    final icd = ReferenceData.icdFor(dateOfService);
    if (index == null || icd == null) return;
    final confirmed = [
      for (final d in found.values)
        if (d.status == DxStatus.billable && (d.source == DxSource.physicianConfirmed || d.source == DxSource.history) && _isDefinitive(d.code)) d,
    ];
    for (final a in confirmed) {
      for (final b in confirmed) {
        if (a.code == b.code || a.code.substring(0, 3) == b.code.substring(0, 3) || a.code.startsWith('I10')) continue;
        if (!found.containsKey(a.code) || !found.containsKey(b.code)) continue;
        if (!(a.code[0] == b.code[0] || RegExp(r'^E(08|09|10|11|13)').hasMatch(a.code))) continue;
        final hit = KnowledgeChecks.combinationFor(a.code, b.code, index);
        if (hit == null || !icd.isBillable(hit.$2) || found.containsKey(hit.$2)) continue;
        final (path, code) = hit;
        final notes = ReferenceData.notes;
        final keepB = notes == null ||
            notes.notesFor(code, ranges: false).any((n) => (n.kind == NoteKind.useAdditional || n.kind == NoteKind.codeAlso) && n.names(b.code));
        final combined = ClaimDiagnosis(
          code: code,
          description: icd.description(code) ?? a.description,
          source: a.source,
          evidence: a.evidence,
          note: 'The ICD-10-CM Index lists "${path.replaceAll('|', ', ')}" as $code, one combination code for ${a.code} and ${b.code} (guideline I.B.9).',
        );
        final entries = found.entries.toList();
        found
          ..clear()
          ..addEntries([
            for (final e in entries)
              if (e.key == a.code) MapEntry(code, combined) else if (e.key != b.code || keepB) e,
          ]);
      }
    }
  }

  /// Recomputes which symptoms are part of a confirmed diagnosis and puts the
  /// list in claim order: confirmed acute, confirmed chronic or history, exam
  /// findings, symptoms, Z codes; then uncertain and integral at the end.
  /// Called after coding and again whenever the physician confirms, removes or
  /// reorders a diagnosis. Manually added codes are never folded away.
  static List<ClaimDiagnosis> finalizeDiagnoses(List<ClaimDiagnosis> input, {List<String> pinnedOrder = const []}) {
    // Re-open previously folded symptoms so a removed owner releases them.
    final list = [
      for (final d in input)
        d.status == DxStatus.integral && d.note != null && d.note!.startsWith('Part of ') ? d.copyWith(status: DxStatus.billable, note: '') : d,
    ];
    final confirmed = list
        .where((d) => d.status == DxStatus.billable && _isDefinitive(d.code) && (d.source == DxSource.physicianConfirmed || d.source == DxSource.history))
        .toList();
    for (var i = 0; i < list.length; i++) {
      final d = list[i];
      if (d.status != DxStatus.billable || d.source == DxSource.physicianConfirmed || d.source == DxSource.history || d.source == DxSource.manual) continue;
      final owner = _integralTo(d.code, confirmed);
      if (owner != null) {
        list[i] = d.copyWith(status: DxStatus.integral, note: 'Part of ${owner.code} ${owner.description}. Not coded separately.');
      }
    }

    int rank(ClaimDiagnosis d) {
      if (d.status == DxStatus.uncertain) return 10;
      if (d.status == DxStatus.integral) return 11;
      final pinned = pinnedOrder.indexOf(d.code);
      if (pinned >= 0) return -100 + pinned;
      // CH21-Z-01: Z codes that may only be first-listed go first;
      // ICD-EXTCAUSE-01, ICD-SECONDARY-ONLY-01, CH1-SEPSIS-01 and
      // ICD-MANIF-01 codes are never first.
      if (isFirstListedOnly(d.code)) return -50;
      // CH15-OB-02 (guideline I.C.15.a.1): Chapter 15 codes have sequencing priority.
      if (d.code.startsWith('O')) return -40;
      if (isNeverFirstListed(d.code)) return 6;
      if (d.source == DxSource.physicianConfirmed || d.source == DxSource.manual) return _isChronicCode(d.code) ? 1 : 0;
      if (d.source == DxSource.history) return 2;
      if (d.source == DxSource.examFinding) return 3;
      if (d.code.startsWith('Z')) return 5;
      return 4;
    }

    final order = {for (var i = 0; i < list.length; i++) list[i].code: i};
    list.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : order[a.code]!.compareTo(order[b.code]!);
    });
    _applyCodeFirst(list, pinnedOrder);
    return list;
  }

  /// ICD-CODEFIRST-01 and ICD-MANIF-01 (guidelines I.A.13, I.B.7). Moves a
  /// billable code that another billable code's "Code first" note names in
  /// front of that code. A physician-pinned first code stays first.
  static void _applyCodeFirst(List<ClaimDiagnosis> list, List<String> pinnedOrder) {
    final notes = ReferenceData.notes;
    if (notes == null) return;
    for (var pass = 0; pass < list.length; pass++) {
      var moved = false;
      for (var i = 0; i < list.length && !moved; i++) {
        final a = list[i];
        if (a.status != DxStatus.billable || pinnedOrder.contains(a.code) || a.code.startsWith('Z3A')) continue;
        final lines = notes.of(a.code, NoteKind.codeFirst).where((n) => n.refs.isNotEmpty && !n.isQualified).toList();
        if (lines.isEmpty) continue;
        for (var j = i + 1; j < list.length; j++) {
          final b = list[j];
          if (b.status != DxStatus.billable || b.code == a.code || !lines.any((n) => n.names(b.code))) continue;
          list.insert(i, list.removeAt(j));
          moved = true;
          break;
        }
      }
      if (!moved) return;
    }
  }

  /// Links each service line to up to four supporting diagnoses (box 24E).
  /// E/M lines point at the primary diagnosis first; procedures point only at
  /// diagnoses in a compatible body system.
  static List<ServiceLine> assignPointers(List<ServiceLine> lines, List<ClaimDiagnosis> billable) {
    return [
      for (final l in lines)
        l.copyWith(
          diagnosisCodes: [
            for (final d in billable)
              if (l.isEvaluationAndManagement || diagnosisSupportsProcedure(d.code, l.code)) d.code,
          ].take(4).toList(),
        ),
    ];
  }

  static String? _laterality(String text) {
    final right = RegExp(r'\bright (knee|leg|side|foot|lower lobe)').hasMatch(text);
    final left = RegExp(r'\bleft (knee|leg|side|foot|lower lobe)').hasMatch(text);
    if (right && !left) return 'right';
    if (left && !right) return 'left';
    return null;
  }

  static final _activeTreatment = _re(r'surg\w*|repair|reduction|arthroscop\w*|operat\w*|re-?injur\w*|new injury|emergency');

  /// CH19-INJ-01 (guidelines I.C.19.a, I.C.19.c.1). 7th character A while
  /// the injury gets active treatment; D once it was coded on an earlier
  /// visit and this visit is routine care during healing.
  static String _injurySeventh(String stem, Set<String> prior, String doctorText) {
    if (!stem.startsWith('S') && !stem.startsWith('T')) return 'A';
    final base = stem.replaceAll('.', '').toUpperCase();
    if (base.length != 7) return 'A';
    final key = base.substring(0, 6);
    final seen = prior.any((c) {
      final n = c.replaceAll('.', '').toUpperCase();
      return n.length == 7 && n.startsWith(key);
    });
    return seen && !_activeTreatment.hasMatch(doctorText) ? 'D' : 'A';
  }

  /// Fills in laterality and 7th characters for code stems.
  static String _withLaterality(String code, String? side, {String seventh = 'A'}) {
    switch (code) {
      case 'S83.24':
        return '${side == 'right' ? 'S83.241' : side == 'left' ? 'S83.242' : 'S83.249'}$seventh';
      case 'M25.06':
        return side == 'right' ? 'M25.061' : side == 'left' ? 'M25.062' : 'M25.069';
      default:
        return code;
    }
  }

  static String _describeLaterality(String description, String code) {
    if (code.startsWith('S83.24') || code.startsWith('M25.06')) {
      final c = code.startsWith('S') ? code.substring(0, code.length - 1) : code;
      final side = c.endsWith('1') ? 'right' : c.endsWith('2') ? 'left' : 'unspecified';
      final encounter = code.endsWith('D') ? 'subsequent encounter' : 'initial encounter';
      return description.replaceFirst('knee', '$side knee${code.startsWith('S') ? ', $encounter' : ''}');
    }
    return description;
  }

  static bool _isNegated(String sentence, RegExp? term) {
    final s = sentence.toLowerCase();
    if (term != null) {
      final m = term.firstMatch(s);
      if (m == null) return false;
      return _negation.hasMatch(s.substring(0, m.start));
    }
    return _negation.hasMatch(s);
  }

  static void _dropLessSpecific(Map<String, ClaimDiagnosis> found) {
    const families = {
      'E11.9': ['E11.42', 'E11.65'],
      'I21.3': ['I21.19', 'I21.4'],
      'J18.9': ['J18.1'],
      'G43.909': ['G43.109'],
      'J45.909': ['J45.901'],
      'J02.9': ['J02.0'],
      'N18.9': ['N18.1', 'N18.2', 'N18.30', 'N18.31', 'N18.32', 'N18.4', 'N18.5', 'N18.6'],
      'N18.30': ['N18.31', 'N18.32', 'N18.6'],
      // CH14-CKD-01, guideline I.C.14.a.1: a CKD stage documented with ESRD
      // is coded N18.6 only.
      'N18.1': ['N18.6'],
      'N18.2': ['N18.6'],
      'N18.31': ['N18.6'],
      'N18.32': ['N18.6'],
      'N18.4': ['N18.6'],
      'N18.5': ['N18.6'],
    };
    families.forEach((general, specific) {
      if (!found.containsKey(general)) return;
      for (final s in specific) {
        final match = found.keys.where((k) => k == s);
        if (match.isNotEmpty) {
          final g = found[general]!;
          final sp = found[match.first]!;
          // Only drop the general code when the specific one is at least as certain.
          if (sp.status == DxStatus.billable || g.status != DxStatus.billable) {
            found.remove(general);
            return;
          }
        }
      }
    });
  }

  static final _unrelatedToHypertension = _re(
    r'\b(not|un)[- ]?(related|due|caused|secondary|from|attributable)\b[^.?!]{0,30}(hypertension|high blood pressure|\bhtn\b)|'
    r'\bnot (because of|a result of) (his |her |their |the )?(hypertension|high blood pressure|\bhtn\b)',
  );

  /// CH9-HTN-01/02/03 (guidelines I.C.9.a.1 to I.C.9.a.3). ICD-10-CM
  /// presumes a causal link between hypertension and heart failure or chronic
  /// kidney disease, so I10 is replaced by the combination code (I11.0,
  /// I12.0/I12.9 or I13.0/I13.2) and the I50/N18 code stays as the additional
  /// code. A link the physician says is absent ("heart failure is not due to
  /// his hypertension") is respected. Only confirmed (billable) codes are
  /// combined. Works in place and keeps the position of I10.
  static void combineHypertension(Map<String, ClaimDiagnosis> found, List<String> doctorSentences) {
    final htn = found['I10'];
    if (htn == null || htn.status != DxStatus.billable) return;
    ClaimDiagnosis? confirmed(String prefix) =>
        found.values.where((d) => d.status == DxStatus.billable && d.code.startsWith(prefix)).firstOrNull;
    bool unrelated(RegExp organ) => doctorSentences.any((s) => _unrelatedToHypertension.hasMatch(s) && organ.hasMatch(s));
    final hf = confirmed('I50');
    final ckd = confirmed('N18');
    final heart = hf != null && !unrelated(_re(r'heart|cardiac|\bchf\b|\bhf\b'));
    final kidney = ckd != null && !unrelated(_re(r'kidney|renal|\bckd\b|\besrd\b'));
    if (!heart && !kidney) return;
    final stage5 = ckd != null && (ckd.code == 'N18.5' || ckd.code == 'N18.6');
    final (String code, String description, String guideline) = heart && kidney
        ? stage5
            ? ('I13.2', 'Hypertensive heart and chronic kidney disease with heart failure and with stage 5 chronic kidney disease, or end stage renal disease', 'I.C.9.a.3')
            : ('I13.0', 'Hypertensive heart and chronic kidney disease with heart failure and stage 1 through stage 4 chronic kidney disease, or unspecified chronic kidney disease', 'I.C.9.a.3')
        : heart
            ? ('I11.0', 'Hypertensive heart disease with heart failure', 'I.C.9.a.1')
            : stage5
                ? ('I12.0', 'Hypertensive chronic kidney disease with stage 5 chronic kidney disease or end stage renal disease', 'I.C.9.a.2')
                : ('I12.9', 'Hypertensive chronic kidney disease with stage 1 through stage 4 chronic kidney disease, or unspecified chronic kidney disease', 'I.C.9.a.2');
    final also = [if (heart) hf.code, if (kidney) ckd.code].join(' and ');
    final combined = ClaimDiagnosis(
      code: code,
      description: description,
      source: htn.source,
      evidence: htn.evidence,
      note: 'Hypertension with ${heart && kidney ? 'heart failure and chronic kidney disease' : heart ? 'heart failure' : 'chronic kidney disease'} '
          'is coded $code plus $also; ICD-10-CM presumes they are linked (guideline $guideline). Use I10 only if the record says they are unrelated.',
    );
    final entries = found.entries.toList();
    found
      ..clear()
      ..addEntries([for (final e in entries) e.key == 'I10' ? MapEntry(code, combined) : e]);
  }

  static bool _isDefinitive(String code) => !code.startsWith('R') && !code.startsWith('Z') && !code.startsWith('H53.1');

  static bool _isChronicCode(String code) =>
      _diagnoses.any((t) => t.chronic && t.code == code) || code.startsWith('I11') || code.startsWith('I12') || code.startsWith('I13');

  static ClaimDiagnosis? _integralTo(String symptom, List<ClaimDiagnosis> confirmed) {
    if (confirmed.isEmpty) return null;
    // ICD-SYMPTOM-01 (guidelines I.B.5, I.C.18.b): an Excludes1 note of the
    // confirmed code that names the symptom says it is part of the diagnosis.
    final ex = ReferenceData.excludes1;
    if (ex != null && symptom.startsWith('R')) {
      for (final c in confirmed) {
        if (ex.conflicts([c.code, symptom]).isNotEmpty) return c;
      }
    }
    final s = icdSystems(symptom);
    for (final c in confirmed) {
      // Chronic conditions (hypertension) do not absorb new symptoms, except
      // diabetes combination codes, whose manifestation is the symptom.
      final manifestation = RegExp(r'^E(08|09|10|11|13)\.[2-6]').hasMatch(c.code);
      if (_isChronicCode(c.code) && !manifestation) continue;
      final cs = manifestation ? icdSystems(c.code).difference({BodySystem.endocrine}) : icdSystems(c.code);
      if (cs.intersection(s).isNotEmpty) return c;
    }
    // General symptoms (fever, sweating, fatigue) and sensory complaints that
    // routinely accompany an acute diagnosis belong to it.
    final general = s.contains(BodySystem.general) || symptom.startsWith('H53.1') || symptom.startsWith('R11');
    if (general) {
      for (final c in confirmed) {
        if (!_isChronicCode(c.code)) return c;
      }
    }
    return null;
  }

  static MdmLevel _mdm(String doctorText, List<ClaimDiagnosis> billable) {
    final highRisk = _diagnoses.any((t) => t.acuteHighRisk && billable.any((d) => d.code == t.code)) ||
        _re(r'cath(eterization)? lab|code stemi|intubat|sepsis|admit (him|her|you|the patient)|life[- ]threatening|emergency surgery').hasMatch(doctorText);
    if (highRisk) return MdmLevel.high;
    final rxManagement = _re(
      r'prescrib\w*|start (you|him|her) on|\b\d+\s?mg\b|refill|increase (your|the) dose|tablets?|'
      r'\b(adjust|add|start|continue|stop|increase|decrease|titrate)\b[^.?!]{0,25}\b\w*(pril|olol|statin|formin|pentin|triptan|cillin|mycin|zole|sartan|dipine|tidine|prazole|semide|thiazide|insulin)\b',
    ).hasMatch(doctorText);
    final workup = _re(r'\bmri\b|ct scan|x-ray|ultrasound|referral|refer (you|him|her)').hasMatch(doctorText);
    if (rxManagement || (workup && billable.length >= 2) || billable.length >= 3) return MdmLevel.moderate;
    if (billable.isNotEmpty || workup) return MdmLevel.low;
    return MdmLevel.straightforward;
  }
}
