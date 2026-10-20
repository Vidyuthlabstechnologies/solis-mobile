import '../models/claim_models.dart';
import '../models/clinical_models.dart';
import 'coding/clinical_coder.dart';

/// A SOAP note written from a visit, plus documentation-improvement notes
/// derived from that note.
class NoteDraft {
  final String subjective;
  final String objective;
  final String assessment;
  final String plan;
  final List<String> cdiRecommendations;

  const NoteDraft({
    required this.subjective,
    required this.objective,
    required this.assessment,
    required this.plan,
    required this.cdiRecommendations,
  });
}

RegExp _re(String p) => RegExp(p, caseSensitive: false);

/// One symptom the note writer recognises in the patient's words.
class _SymptomDef {
  final String key;
  final int rank; // 0 = usual chief complaint, 1 = primary symptom, 2 = associated
  final RegExp pattern;
  final String label;
  final RegExp? exclude; // window text that means this is not the symptom
  const _SymptomDef(this.key, this.rank, this.pattern, this.label, {this.exclude});
}

class _Finding {
  final String key;
  final int rank;
  final int order;
  final String label;
  final List<String> windows = [];
  String? part; // body part for pain and injuries
  _Finding(this.key, this.rank, this.order, this.label);
}

class _Utterance {
  final String text;
  final String? question; // the physician question this answers, if any
  const _Utterance(this.text, {this.question});
}

/// Writes a SOAP note the way a physician would: a third-person HPI from what
/// the patient said, findings the physician stated, diagnoses exactly as the
/// coder found them (with their certainty), and the plan as discrete actions.
/// Nothing is added that was not said.
class NoteWriter {
  // ---------------------------------------------------------------------------
  // Vocabulary
  // ---------------------------------------------------------------------------

  static const _parts = r'feet|foot|toes?|hands?|fingers?|legs?|arms?|knees?|ankles?|back|neck|shoulders?|hips?|wrists?|elbows?|calf|calves|thighs?|throat|ears?';

  static final List<_SymptomDef> _defs = [
    _SymptomDef('chest_pain', 0,
        _re(r'(chest|retrosternal)[^.?!]{0,30}(pain|pressure|tight\w*|crush\w*|squeez\w*|heav\w*|hurt\w*|ache|aching|discomfort)|(crush\w*|squeez\w*|tight\w*|pressure|heav\w*)[^.?!]{0,20}(chest|retrosternal)|elephant[^.?!]{0,25}chest|retrosternal pain'),
        'chest pain'),
    _SymptomDef('headache', 0,
        _re(r'head\s*ache|migraine|(pain|throb\w*|pound\w*|ache)[^.?!]{0,30}(side of|behind|in) (my |the |his |her )?(head|temple|forehead)|head (is |was )?(pounding|killing|throbbing|hurting)'),
        'headache'),
    _SymptomDef('abdominal_pain', 0,
        _re(r'(stomach|belly|abdominal|abdomen|tummy|epigastric)[^.?!]{0,20}(pain|ache|hurt\w*|cramp\w*)|(pain|cramp\w*)[^.?!]{0,20}(stomach|belly|abdomen)'),
        'abdominal pain'),
    _SymptomDef('injury', 0,
        _re(r'(twist\w*|injur\w*|sprain\w*|rolled|banged|fell on)[^.?!]{0,25}\b(knee|ankle|wrist|shoulder|back|hip|elbow|foot|hand)\b|\b(knee|ankle|wrist|shoulder|hip|elbow)\b[^.?!]{0,20}(twist\w*|gave out|buckled|injur\w*|sprain\w*)'),
        'injury'),
    _SymptomDef('body_pain', 0,
        _re('\\b($_parts)\\b[^.?!]{0,30}\\b(pain\\w*|hurt\\w*|ache|aching|killing|sore)\\b|\\b(pain|ache|aching|soreness) (in|on) (both |my |the |his |her )*(left |right )?($_parts)\\b'),
        'pain'),
    _SymptomDef('syncope', 0, _re(r'passed out|fainted|blacked out'), 'syncope'),
    _SymptomDef('cough', 1, _re(r'\bcough\w*'), 'cough'),
    _SymptomDef('pleuritic', 1,
        _re(r'(sharp|stabbing)[^.?!]{0,40}(breathe|breath in|inhal\w*)|(breathe in|breath in|inhal\w*|deep breath)[^.?!]{0,50}(sharp|stabbing|pain|hurt\w*)|pleuritic|hurts to breathe'),
        'pleuritic chest pain'),
    _SymptomDef('dyspnea', 1,
        _re(r"short(ness)? of breath|winded|out of breath|(trouble|difficulty|hard time) (breathing|catching (my|your) breath)|can'?t (catch|get) my breath|dyspnea|breathless"),
        'shortness of breath'),
    _SymptomDef('fever', 1, _re(r'\bfevers?\b|febrile|feverish|temperature of'), 'fever'),
    _SymptomDef('paresthesia', 1, _re(r'pins and needles|tingl\w*|\bburning\b'), 'paresthesias',
        exclude: _re(r'pee|urinat|heartburn|chest|eyes')),
    _SymptomDef('dizziness', 1, _re(r'dizz\w*|light[- ]?headed|room (is )?spinning|vertigo'), 'dizziness'),
    _SymptomDef('sore_throat', 1, _re(r'sore throat|throat (hurts|is sore|pain)'), 'sore throat'),
    _SymptomDef('rash', 1, _re(r'\brash\b'), 'rash'),
    _SymptomDef('palpitations', 1, _re(r'palpitation\w*|heart (is )?(racing|pounding|fluttering)'), 'palpitations'),
    _SymptomDef('dysuria', 1, _re(r'(burn\w*|hurts?|pain)[^.?!]{0,20}(pee|urinat\w*)|dysuria'), 'dysuria'),
    _SymptomDef('diarrhea', 1, _re(r'diarrh\w*|loose stools?'), 'diarrhea'),
    _SymptomDef('chills', 2, _re(r'\bchills\b|rigors'), 'chills'),
    _SymptomDef('numbness', 2, _re(r'\bnumb(ness)?\b'), 'numbness'),
    _SymptomDef('weakness', 2, _re(r'\bweak(ness)?\b'), 'weakness'),
    _SymptomDef('diaphoresis', 2, _re(r'\b(sweat\w*|diaphore\w*|drenched|clammy)\b'), 'diaphoresis'),
    _SymptomDef('nausea', 2, _re(r'nause\w*|queasy|sick to (my|the|your) stomach'), 'nausea'),
    _SymptomDef('vomiting', 2, _re(r'vomit\w*|threw up|throwing up'), 'vomiting'),
    _SymptomDef('aura', 2, _re(r'zigzag|blind spots?|shimmering|seeing spots|visual aura|flashing lights|scintillat\w*'), 'visual aura'),
    _SymptomDef('photophobia', 2,
        _re(r'photophobia|sensitiv\w* to (bright )?light|\blight[^.?!]{0,20}(hurts?|bothers?|sensitiv\w*|feels like|kills)'), 'photophobia'),
    _SymptomDef('phonophobia', 2, _re(r'phonophobia|sensitiv\w* to (sound|noise)|(sound|noise)[^.?!]{0,15}(hurts?|bothers?)'), 'phonophobia'),
    _SymptomDef('swelling', 2, _re(r'swell\w*|swollen|softball|puffed up'), 'swelling'),
    _SymptomDef('pop', 2, _re(r'\bpop(ped|ping)?\b|\bsnap(ped)?\b'), 'audible pop'),
    _SymptomDef('fatigue', 2, _re(r'\b(tired|exhausted|fatigue\w*|wiped out|no energy)\b'), 'fatigue'),
    _SymptomDef('frequency', 2, _re(r'(pee|urinat\w*)[^.?!]{0,15}(all the time|a lot|frequently|constantly)|frequent urination'), 'urinary frequency'),
    _SymptomDef('congestion', 2, _re(r'stuffy nose|nasal congestion|congested'), 'nasal congestion'),
    _SymptomDef('insomnia', 2, _re(r"can'?t (fall |stay )?asleep|can'?t sleep|trouble sleeping|insomnia"), 'insomnia'),
    _SymptomDef('wheezing', 2, _re(r'wheez\w*'), 'wheezing'),
    _SymptomDef('neck_stiffness', 2, _re(r'stiff neck|neck (is |feels )?stiff\w*|neck stiffness'), 'neck stiffness'),
  ];

  static const _painKeys = {'chest_pain', 'headache', 'abdominal_pain', 'body_pain', 'pleuritic', 'paresthesia', 'injury'};

  static final _qualities = <String, RegExp>{
    'crushing': _re(r'crush\w*'),
    'pressure-like': _re(r'elephant|pressure|squeez\w*|tight\w*|heav(y|iness)'),
    'sharp': _re(r'\bsharp\b'),
    'stabbing': _re(r'stabb\w*'),
    'throbbing': _re(r'throb\w*'),
    'pounding': _re(r'pound\w*'),
    'dull': _re(r'\bdull\b'),
    'aching': _re(r'\bach(e|ing)\b'),
    'shooting': _re(r'shoot\w*'),
    'cramping': _re(r'cramp\w*'),
  };

  static final _negationBefore = _re(r"\b(no|not|denies|denied|without|never|don'?t have|haven'?t had)\b[^.,;!?]{0,25}$");

  static final _windowBoundary = _re(r'[;!?]|\.(?!\d)|, and |, but | and then |, then ');

  static final _reportedHistory = _re(
    r'\b(patient|pt|he|she)\b[^.?!]{0,12}\b(has|had|reports?|complains?|presents?|states?|describes?|notes?|denies)\b|complains of|presents with|\bc/o\b',
  );

  static final _strongFinding = _re(
    r'\bon exam|crackles|rales|tender\w*|effusion|\bekg\b|\becg\b|st[- ]?(segment )?elevation|pupils|reflexes|lachman|mcmurray|murmur|wheez\w*|meningismus|breath sounds',
  );

  /// Sentence split that keeps "Dr. Martinez" in one piece.
  static List<String> _sentences(String text) {
    final protected = text.replaceAllMapped(RegExp(r'\b(Dr|Mr|Mrs|Ms|St|vs)\.', caseSensitive: false), (m) => '${m.group(1)}<dot>');
    return ClinicalCoder.splitSentences(protected).map((s) => s.replaceAll('<dot>', '.')).toList();
  }

  static const _numberWords = r'(?:\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|a couple of|a few|several|couple of|few)';
  static const _unit = r'(?:minutes?|hours?|days?|weeks?|months?|years?)';

  static final _duration = _re(
    '(?<!lasted |lasting |lasts |every |within |in |next )\\b(?:(about|around|roughly|almost|nearly|over) )?(?:for )?(?:(the )?(past|last) )?'
    '($_numberWords(?: (?:or|to) $_numberWords)? $_unit)(?![- ]old)( ago)?\\b',
  );

  static final _onset = _re(
    r'\b(?:started|began|came on|hit)\s+((?:yesterday|today|this morning|last night|last week|(?:on |last )?(?:mon|tues|wednes|thurs|fri|satur|sun)day)(?: (?:morning|afternoon|evening|night))?)',
  );

  static final _dayOnset = _re(r'\bon ((?:mon|tues|wednes|thurs|fri|satur|sun)day)\b');

  static final _context = [
    _re(r"\bwhile ([a-z' -]{3,40}?)(?=[,.;!?]| and |$)"),
    _re(r'\bi was ((?:playing|running|lifting|walking|working|mowing|carrying|climbing|moving|exercising|getting|reaching|bending|driving|cleaning|shoveling|gardening|hiking|biking|skiing|swimming|dancing)\b[^,.;!?]{0,40})'),
  ];

  static final _severity = _re(r'\b(severe|excruciating|unbearable|worst|debilitat\w*|killing me|terrible (?:pain|burning|headache|ache)|(\d+)\s*(?:out of|/)\s*10)\b');

  static const _genericMeds =
      r'ibuprofen|advil|motrin|tylenol|acetaminophen|aspirin|naproxen|aleve|nsaids?|metformin|insulin|lisinopril|amlodipine|losartan|metoprolol|'
      r'atorvastatin|simvastatin|rosuvastatin|levothyroxine|synthroid|albuterol|omeprazole|pantoprazole|famotidine|prednisone|gabapentin|sumatriptan|'
      r'ondansetron|zofran|augmentin|amoxicillin|azithromycin|z-pak|ticagrelor|heparin|clopidogrel|plavix|warfarin|eliquis|apixaban|nitroglycerin|'
      r'benadryl|cetirizine|claritin|loratadine|ceftriaxone|doxycycline|cephalexin|keflex|tramadol|oxycodone|morphine|ketorolac|toradol|jardiance|ozempic|glipizide';
  static final _med = _re('\\b($_genericMeds|\\w+(?:pril|olol|sartan|statin|dipine|formin|pentin|triptan|cillin|mycin|floxacin|cycline|prazole|tidine|semide|thiazide|setron|lukast|parin|grel|xaban))\\b');
  static final _dose = _re(r'\b\d+(?:\.\d+)?\s?(mg|mcg|g|units?|ml|l)\b');

  // ---------------------------------------------------------------------------
  // Entry point
  // ---------------------------------------------------------------------------

  static NoteDraft write({
    required List<SpeakerTurn> turns,
    required List<VitalSign> vitals,
    required CodingResult coding,
    String fullText = '',
  }) {
    final patientSide = <_Utterance>[];
    final doctorSide = <String>[];
    String? lastDoctorSentence;
    for (final t in turns) {
      final sentences = _sentences(t.text);
      final isDoctor = t.speaker == 'Doctor' || t.speaker == 'Nurse';
      if (isDoctor) {
        doctorSide.addAll(sentences);
        if (sentences.isNotEmpty) lastDoctorSentence = sentences.last;
      } else {
        for (var i = 0; i < sentences.length; i++) {
          final q = i == 0 && lastDoctorSentence != null && lastDoctorSentence.trim().endsWith('?') ? lastDoctorSentence : null;
          patientSide.add(_Utterance(sentences[i], question: q));
        }
      }
    }

    // Physician-reported history ("patient reports ...") belongs in the HPI.
    // A single-speaker dictation has no patient turns: then every dictated
    // sentence that is not an order is history or exam.
    final history = <_Utterance>[
      ...patientSide,
      for (final s in doctorSide)
        if (!s.trim().endsWith('?') && (patientSide.isEmpty ? !_isPlanSentence(s) : _reportedHistory.hasMatch(s))) _Utterance(s),
    ];

    final planItems = _planItems(doctorSide);
    final plan = planItems.isEmpty ? 'No plan documented.' : [for (var i = 0; i < planItems.length; i++) '${i + 1}. ${planItems[i]}'].join('\n');
    final allText = fullText.isNotEmpty ? fullText : turns.map((t) => t.text).join(' ');
    final assessmentLines = _assessment(coding, planItems);

    return NoteDraft(
      subjective: _subjective(history, allText),
      objective: _objective(doctorSide, vitals, allText, dictation: patientSide.isEmpty),
      assessment: assessmentLines.isEmpty ? 'No diagnosis stated.' : [for (var i = 0; i < assessmentLines.length; i++) '${i + 1}. ${assessmentLines[i]}'].join('\n'),
      plan: plan,
      cdiRecommendations: cdiFor(coding, plan),
    );
  }

  // ---------------------------------------------------------------------------
  // Subjective
  // ---------------------------------------------------------------------------

  static String _window(String l, int start, int end) {
    var from = start - 60 < 0 ? 0 : start - 60;
    for (final b in _windowBoundary.allMatches(l)) {
      if (b.end <= start && b.end > from) from = b.end;
    }
    var to = end + 60 > l.length ? l.length : end + 60;
    for (final b in _windowBoundary.allMatches(l)) {
      if (b.start >= end && b.start < to) {
        to = b.start;
        break;
      }
    }
    return l.substring(from, to).trim();
  }

  static bool _negatedAt(String l, int start) {
    var from = 0;
    for (final b in _windowBoundary.allMatches(l)) {
      if (b.end <= start) from = b.end;
    }
    return _negationBefore.hasMatch(l.substring(from, start));
  }

  static String _normPart(String p) {
    switch (p) {
      case 'feet':
        return 'foot';
      case 'calves':
        return 'calf';
      default:
        return p.endsWith('s') && p != 'toes' ? p.substring(0, p.length - 1) : p;
    }
  }

  static String _subjective(List<_Utterance> utterances, String allText) {
    final findings = <String, _Finding>{};
    final negatives = <String>[];
    final statements = <String>[]; // non-question patient text, lower case
    final allLower = allText.toLowerCase();

    void addHit(_SymptomDef d, String l, RegExpMatch m, int order) {
      final w = _window(l, m.start, m.end);
      if (d.exclude != null && d.exclude!.hasMatch(w)) return;
      var key = d.key;
      String? part;
      if (d.key == 'body_pain' || d.key == 'injury') {
        final pm = _re('\\b($_parts|knee|ankle|wrist|shoulder|back|hip|elbow|foot|hand)\\b').firstMatch(m.group(0)!);
        if (pm == null) return;
        part = pm.group(1)!;
        if (d.key == 'body_pain') {
          if (part == 'throat') return; // sore throat has its own entry
          key = 'pain:${_normPart(part)}';
        }
      }
      final f = findings.putIfAbsent(key, () => _Finding(key, d.rank, order, d.label));
      f.windows.add(w);
      f.part ??= part;
    }

    for (var i = 0; i < utterances.length; i++) {
      final u = utterances[i];
      final l = u.text.toLowerCase().trim();
      final isQuestion = l.endsWith('?');
      if (isQuestion) continue;
      statements.add(l);
      final before = findings.length;
      for (final d in _defs) {
        for (final m in d.pattern.allMatches(l)) {
          if (_negatedAt(l, m.start)) {
            if (!negatives.contains(d.label)) negatives.add(d.label);
            break;
          }
          addHit(d, l, m, i * 1000 + m.start);
          break;
        }
      }

      // The answer to a physician's question about specific symptoms.
      if (u.question != null) {
        final q = u.question!.toLowerCase();
        final asked = [for (final d in _defs) if (d.pattern.hasMatch(q)) d];
        if (asked.isNotEmpty) {
          if (_re(r"^(no|nope|none|not really|nothing like that|negative)\b").hasMatch(l)) {
            for (final d in asked) {
              if (!findings.containsKey(d.key) && !negatives.contains(d.label)) negatives.add(d.label);
            }
          } else if (findings.length == before && _re(r'^(yes|yeah|yep|yup|i do|i have|correct)\b[.!]?$').hasMatch(l)) {
            for (final d in asked) {
              final m = d.pattern.firstMatch(q)!;
              addHit(d, q, m, i * 1000);
            }
          }
        }
      }
    }
    negatives.removeWhere((n) => findings.values.any((f) => f.label == n));

    final text = statements.join(' ');
    final sentences = <String>[];

    if (findings.isNotEmpty) {
      final ordered = findings.values.toList()..sort((a, b) => a.order.compareTo(b.order));
      final cc = ([...ordered]..sort((a, b) => a.rank != b.rank ? a.rank.compareTo(b.rank) : a.order.compareTo(b.order))).first;
      final used = <String>{cc.key};

      var ccPhrase = _render(cc, findings, allLower);
      final severity = _severity.firstMatch(text);
      if (severity != null && _painKeys.contains(cc.key.startsWith('pain:') ? 'body_pain' : cc.key)) {
        final n = severity.group(2);
        ccPhrase = n != null ? '$ccPhrase, rated $n/10' : 'severe $ccPhrase';
      }
      // "Foot pain ... burning and pins and needles in both feet" reads as one complaint.
      final par = findings['paresthesia'];
      if (cc.key.startsWith('pain:') && par != null && _locationOf(par.windows).contains(cc.key.substring(5) == 'foot' ? 'feet' : cc.key.substring(5))) {
        ccPhrase = '$ccPhrase, described as ${_render(par, findings, allLower)},';
        used.add('paresthesia');
      }
      if (_painKeys.contains(cc.key) || cc.key.startsWith('pain:')) {
        final rad = _radiation(text);
        if (rad != null) ccPhrase = '$ccPhrase radiating to $rad';
      }

      final timeParts = <String>[];
      final dur = _duration.firstMatch(text);
      final onset = _onset.firstMatch(text);
      String? contextPhrase;
      for (final c in _context) {
        final m = c.firstMatch(text);
        if (m != null) {
          contextPhrase = 'while ${_thirdPerson(m.group(1)!.trim())}';
          break;
        }
      }
      if (dur != null) {
        final span = dur.group(4)!;
        if (dur.group(5) != null) {
          timeParts.add('onset $span ago');
        } else if (dur.group(3) != null) {
          timeParts.add('for the past $span');
        } else {
          timeParts.add('for ${dur.group(1) != null ? '${dur.group(1)} ' : ''}$span');
        }
      }
      if (onset != null && !(contextPhrase ?? '').contains(onset.group(1)!)) {
        timeParts.add('onset ${onset.group(1)}');
      } else if (dur == null && onset == null) {
        final day = _dayOnset.firstMatch(text);
        if (day != null && !(contextPhrase ?? '').contains(day.group(0)!)) timeParts.add('on ${_capitalize(day.group(1)!)}');
      }
      var first = 'Patient presents with $ccPhrase';
      if (timeParts.isNotEmpty) first += '${first.endsWith(',') || timeParts.first.startsWith('for ') ? '' : ','} ${timeParts.join(', ')}';
      if (contextPhrase != null) first += ' ${contextPhrase.replaceAllMapped(_re(r'\b(mon|tues|wednes|thurs|fri|satur|sun)day\b'), (m) => _capitalize(m.group(0)!))}';
      first = first.replaceAll(RegExp(r',\s*$'), '');
      first = first.replaceAll(RegExp(r',,'), ',');
      sentences.add('$first.');

      final timing = <String>[];
      if (_re(r'\bat night|nighttime|nightly|into bed|in bed\b').hasMatch(text)) {
        timing.add(_re(r'especially|worse|mostly').hasMatch(text) ? 'worse at night' : 'occurs at night');
      }
      if (_re(r'worse in the morning').hasMatch(text)) timing.add('worse in the morning');
      if (_re(r'wakes? me up|waking me up|keeps me up').hasMatch(text)) timing.add('wakes patient from sleep');
      if (timing.isNotEmpty) sentences.add('${_capitalize(timing.join(' and '))}.');

      final associated = <String>[];
      for (final f in ordered) {
        if (used.contains(f.key)) continue;
        if (f.key == 'vomiting' && findings.containsKey('nausea')) continue;
        associated.add(_render(f, findings, allLower));
      }
      if (associated.isNotEmpty) sentences.add('Associated ${_list(associated)}.');
    }

    if (negatives.isNotEmpty) sentences.add('Denies ${_list(negatives, conjunction: 'or')}.');

    // Medications the patient has tried.
    for (final u in utterances) {
      final l = u.text.toLowerCase();
      final m = _med.firstMatch(l);
      if (m == null) continue;
      final name = _capitalize(m.group(1)!);
      if (_re(r"didn'?t (even )?(help|work|touch)|no relief|not help\w*|doesn'?t (help|work)|did nothing").hasMatch(l)) {
        sentences.add('$name without relief.');
      } else if (_re(r'\b(helps|helped|some relief)\b').hasMatch(l)) {
        sentences.add('$name with some relief.');
      } else if (_re(r"\b(i take|i'?m taking|i am taking|i'?ve been taking|i'?m on|takes|taking)\b").hasMatch(l)) {
        sentences.add('Takes ${m.group(1)}.');
      }
    }

    // Relevant history the patient mentions.
    final hx = <String>[];
    const historyTerms = {
      'diabetes': 'diabetes',
      'high blood pressure': 'hypertension',
      'hypertension': 'hypertension',
      'asthma': 'asthma',
      'copd': 'COPD',
      'high cholesterol': 'hyperlipidemia',
      'cholesterol': 'hyperlipidemia',
      'thyroid': 'thyroid disease',
      'heart failure': 'heart failure',
      'afib': 'atrial fibrillation',
      'atrial fibrillation': 'atrial fibrillation',
      'depression': 'depression',
      'anxiety': 'anxiety',
      'arthritis': 'arthritis',
    };
    for (final u in utterances) {
      final l = u.text.toLowerCase();
      historyTerms.forEach((k, v) {
        if (RegExp('\\bmy $k\\b').hasMatch(l) && !hx.contains(v)) hx.add(v);
      });
    }
    if (hx.isNotEmpty) sentences.add('History of ${_list(hx)}.');
    final sugar = _re(r"\b(sugars?|glucose)(?:'s| has| have| had| is| are)? (?:been )?(?:a little |running |really |way |a bit )?(higher|high|up|elevated|low|lower)\b").firstMatch(text);
    if (sugar != null) {
      final dir = sugar.group(2)!.startsWith('low') ? 'lower' : 'higher';
      final when = _re(r'\b(lately|recently)\b').firstMatch(text)?.group(1);
      sentences.add('Reports blood sugars have been $dir${when != null ? ' $when' : ''}.');
    }
    final exposure = _re(r"caught (?:something|a (?:cold|bug|virus)|it|this) from (?:my |the )?([a-z' ]+?)(?:\s+(last week|yesterday|\w+ days ago))?(?=[,.;!?]| and |$)").firstMatch(text);
    if (exposure != null) {
      sentences.add('Reports sick exposure at ${exposure.group(1)!.trim()}${exposure.group(2) != null ? ' ${exposure.group(2)}' : ''}.');
    }

    if (sentences.isEmpty) {
      // Nothing recognised: keep the patient's clinical statements, rewritten
      // in the third person, rather than inventing a summary.
      final clinical = _re(r'pain|hurt|ache|sore|fever|cough|sick|medic|pill|taking|since|days?|weeks?|months?|swell|bleed|blood|breath|sleep|appetite|weight|dizz|tired|vomit|nause|diarr|itch|lump|bump|cut|burn|fell|fall|injur');
      for (final u in utterances) {
        final s = u.text.trim();
        if (s.endsWith('?') || s.length < 15 || _isSmallTalk(s) || !clinical.hasMatch(s)) continue;
        sentences.add(_capitalize(_thirdPerson(s)));
        if (sentences.length == 3) break;
      }
    }
    if (sentences.isEmpty) return 'No history documented.';
    return sentences.join(' ').replaceAll(RegExp(r'\s{2,}'), ' ');
  }

  static String _render(_Finding f, Map<String, _Finding> all, String allLower) {
    final w = f.windows.join(' | ');
    List<String> qualities() => [
          for (final e in _qualities.entries)
            if (e.value.hasMatch(w)) e.key,
        ];
    String sided() {
      final m = _re(r'\b(left|right)[- ]sided|\bon the (left|right) side|\b(left|right) side of').firstMatch(w);
      if (m == null) return '';
      return '${m.group(1) ?? m.group(2) ?? m.group(3)}-sided ';
    }

    String q(List<String> qs) => qs.isEmpty ? '' : '${qs.join(', ')} ';

    switch (f.key) {
      case 'chest_pain':
        final loc = w.contains('retrosternal') ? 'retrosternal ' : w.contains('substernal') ? 'substernal ' : '';
        return '${q(qualities())}$loc${sided()}chest pain';
      case 'headache':
        return '${q(qualities())}${sided()}headache';
      case 'pleuritic':
        return '${q(qualities())}${sided()}pleuritic chest pain';
      case 'abdominal_pain':
        final loc = _re(r'epigastric|upper|lower|right lower|left lower|right upper|left upper').firstMatch(w)?.group(0);
        return '${q(qualities())}${loc != null ? '$loc ' : ''}abdominal pain';
      case 'injury':
        final part = _normPart(f.part ?? '');
        final side = _sideFor(part, w, allLower);
        return w.contains('twist') ? 'twisting injury of the $side$part' : '$side$part injury';
      case 'cough':
        if (_re(r'phlegm|sputum|mucus|productive|coughing up').hasMatch(w)) {
          final s = _re(r'((?:thick|thin|copious)\s+)?((?:green|yellow|clear|white|brown|bloody|blood-tinged|rust\w*)\s+)?(phlegm|sputum|mucus)').firstMatch(w);
          final desc = s == null ? '' : '${s.group(1) ?? ''}${s.group(2) ?? ''}'.trim();
          return desc.isEmpty ? 'productive cough' : 'productive cough with $desc sputum';
        }
        return w.contains('dry') ? 'dry cough' : 'cough';
      case 'fever':
        final m = _re(r'\bfevers?\b|febrile|feverish|temperature of').firstMatch(w);
        final after = m == null ? '' : w.substring(m.end).split(RegExp(r'[,;]')).first;
        final v = RegExp(r'^[^0-9]{0,20}?(\d{2,3}(?:\.\d)?)').firstMatch(after);
        final when = _re(r'last night|this morning|yesterday|overnight').firstMatch(after)?.group(0);
        var s = 'fever';
        if (v != null) {
          final n = double.parse(v.group(1)!);
          if (n >= 35) s += ' to ${v.group(1)} ${n < 50 ? 'C' : 'F'}';
        }
        return when != null ? '$s $when' : s;
      case 'paresthesia':
        final parts = <String>[
          if (w.contains('burning')) 'burning',
          if (w.contains('pins and needles')) 'pins-and-needles paresthesias' else if (w.contains('tingl')) 'tingling',
        ];
        final loc = _locationOf(f.windows);
        final base = parts.length == 1 && parts.first == 'burning' ? 'burning sensation' : parts.join(' and ');
        return loc.isEmpty ? base : '$base $loc';
      case 'numbness':
      case 'swelling':
        final loc = _locationOf(f.windows);
        final when = _re(r'within (?:an|a|one|\d+|a few) (?:hour|hours|minutes)|right away|overnight|immediately').firstMatch(w)?.group(0);
        return [f.label, if (loc.isNotEmpty) loc, ?when].join(' ');
      case 'dyspnea':
        return _re(r'stairs|walk\w*|exert\w*|climb\w*|exercis\w*|activity').hasMatch(w) ? 'dyspnea on exertion' : 'shortness of breath';
      case 'aura':
        final desc = [
          for (final d in ['shimmering', 'flashing', 'zigzag']) if (w.contains(d)) d,
          if (w.contains('blind spot')) 'blind spots' else if (w.contains('spots')) 'spots',
        ];
        final lasting = _re(r'last(?:ed|ing|s) (?:about |for )?((?:\d+|[a-z]+) (?:seconds?|minutes?|hours?))').firstMatch(w)?.group(1);
        final inner = [if (desc.isNotEmpty) desc.join(' '), if (lasting != null) 'lasting $lasting'].join(' ');
        return inner.isEmpty ? 'visual aura' : 'visual aura ($inner)';
      case 'nausea':
        final vom = all['vomiting'];
        if (vom == null) return 'nausea';
        return 'nausea and ${_render(vom, all, allLower)}';
      case 'vomiting':
        final m = _re(r'\b(?:(?:once|twice|\w+ times)\s+)?(?:this morning|today|last night|yesterday)\b|\b(?:once|twice|\w+ times)\b').firstMatch(w);
        return m == null ? 'vomiting' : 'vomiting (${m.group(0)!.trim()})';
      default:
        if (f.key.startsWith('pain:')) {
          final part = f.key.substring(5);
          final plural = f.part != null && f.part != part && f.part != 'toes';
          final side = plural || w.contains('both') ? 'bilateral ' : _sideFor(part, w, allLower);
          return '${q(qualities())}$side$part pain';
        }
        return f.label;
    }
  }

  static String _sideFor(String part, String window, String allLower) {
    final local = RegExp('\\b(left|right) $part').firstMatch(window);
    if (local != null) return '${local.group(1)} ';
    final right = RegExp('\\bright $part').hasMatch(allLower);
    final left = RegExp('\\bleft $part').hasMatch(allLower);
    if (right && !left) return 'right ';
    if (left && !right) return 'left ';
    return '';
  }

  static String _locationOf(List<String> windows) {
    for (final w in windows) {
      final m = _re('\\b(in|on|of|around|at|along)\\s+(both\\s+(?:of\\s+)?)?(?:my|the|his|her|your)?\\s*(left |right )?($_parts|eyes?)\\b').firstMatch(w);
      if (m != null) {
        return '${m.group(1)} ${m.group(2) != null ? 'both ' : 'the '}${m.group(3) ?? ''}${m.group(4)}';
      }
    }
    return '';
  }

  static String? _radiation(String text) {
    final m = _re(r'radiat\w*\s+([^.;!?]+)').firstMatch(text) ?? _re(r'(?:goes|shoots|spreads?)\s+((?:into|down|up|to)\s[^.;!?]+)').firstMatch(text);
    if (m == null) return null;
    final targets = <String>[];
    final span = m.group(1)!.split(_re(r'\s+(with|while|when|since|after|because)\s+')).first;
    for (var p in span.split(RegExp(r',\s*|\s+and\s+'))) {
      p = p
          .replaceAll(_re(r'\b(straight|all the way|directly)\b'), '')
          .replaceAll(_re(r'^\s*(into|to|down|up|through|toward|towards|across)\s+'), '')
          .replaceAll(_re(r'^\s*(into|to|down|up|through|toward|towards|across)\s+'), '')
          .replaceAll(_re(r'\b(my|the|his|her|your)\s+'), '')
          .trim();
      if (p.isNotEmpty && p.length < 25) targets.add(p);
    }
    if (targets.isEmpty) return null;
    return 'the ${_list(targets)}';
  }

  static bool _isSmallTalk(String s) => _re(
        r'basketball|warriors|\bgame\b|weather|grandson|granddaughter|vacation|haha|\blol\b|oh god|oh my god|good morning|good afternoon|\bhello\b|\bhi\b|how are you|nice to meet|take a seat|embarrassing',
      ).hasMatch(s);

  static String _thirdPerson(String s) {
    var t = s;
    final rules = <RegExp, String>{
      _re(r"\bI'm\b|\bI am\b"): 'patient is',
      _re(r"\bI've\b|\bI have\b"): 'patient has',
      _re(r'\bI was\b'): 'patient was',
      _re(r"\bI'll\b|\bI will\b"): 'patient will',
      _re(r"\bI'd\b"): 'patient would',
      _re(r"\bI can't\b|\bI cannot\b"): 'patient cannot',
      _re(r"\bI don't\b"): 'patient does not',
      RegExp(r'\bI\b'): 'patient',
      _re(r'\bmyself\b'): 'self',
      _re(r'\bmy\s+'): '',
      _re(r'\bme\b'): 'the patient',
    };
    rules.forEach((k, v) => t = t.replaceAll(k, v));
    return t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  }

  // ---------------------------------------------------------------------------
  // Objective
  // ---------------------------------------------------------------------------

  static final _vitalClause = _re(r'\b(bp|blood pressure|heart rate|pulse|hr|temp\w*|oxygen|o2|spo2|sats?|saturation|respiratory rate|rr|vitals?)\b|\d{2,3}\s*(/|over)\s*\d{2,3}');
  static final _lab = _re(
    r'\b(hba1c|hemoglobin a1c|a1c|troponin|glucose|blood sugar|creatinine|potassium|sodium|white (?:blood )?count|wbc|hemoglobin|ldl|tsh|inr|lactate|bnp|d-dimer)\b([^0-9?!.]{0,30}?)(\d+(?:\.\d+)?)',
  );
  static final _findingVocab = _re(
    r'crackles|rales|rhonchi|wheez\w*|breath sounds|\bclear\b|tender\w*|effusion|swelling|swollen|edema|erythema|murmur|gallop|rhythm|pupils|cranial nerves|reflexes|'
    r'sensation|vibration|strength|range of motion|lachman|mcmurray|drawer|meningismus|supple|intact|normal|reduced|decreased|diminished|elevation|depressions?|'
    r'consolidation|\bekg\b|\becg\b|12-lead|\blungs?\b|heart sounds|abdomen|bowel sounds|distended|guarding|rebound|\bjvd\b|capillary refill|pulses|\bstable\b|click|crepitus|'
    r'bruising|ecchymosis|deformity|laceration|lesion',
  );
  static final _diagnosisStatement = _re(
    r'\b(you are having|you have (an?|the) |this is (a|an|the)|it is (a|an)|presentation|sounds like|suspicious for|diagnos\w*|i think (you|it)|we think)\b',
  );

  static String _objective(List<String> doctorSide, List<VitalSign> vitals, String allText, {bool dictation = false}) {
    final lines = <String>[];
    if (vitals.isNotEmpty) {
      const names = {'Heart Rate': 'HR'};
      final roomAir = _re(r'\d{2,3}\s*(%|percent)\s+on room air').hasMatch(allText);
      lines.add('Vitals: ${vitals.map((v) => '${names[v.label] ?? v.label} ${v.value}${v.label == 'SpO2' && roomAir ? ' on room air' : ''}').join(', ')}.');
    }

    final labs = <String>[];
    final findings = <String>[];
    for (final raw in doctorSide) {
      final s = raw.trim();
      if (s.endsWith('?') || _isPlanSentence(s) || _diagnosisStatement.hasMatch(s)) continue;
      // Dictated history ("Patient has burning feet") goes in the HPI, not
      // the exam, unless it also carries an exam or test finding.
      if (_reportedHistory.hasMatch(s)) continue;
      if (dictation && _defs.any((d) => d.rank < 2 && d.pattern.hasMatch(s)) && !_strongFinding.hasMatch(s)) continue;
      for (final m in _lab.allMatches(s)) {
        final name = m.group(1)!.toLowerCase();
        final label = name.contains('a1c') ? 'HbA1c' : name.toUpperCase() == name ? name : '${name[0].toUpperCase()}${name.substring(1)}';
        final when = _re(r'last week|yesterday|today|this morning|last month').firstMatch(m.group(2)!)?.group(0);
        final entry = '$label ${m.group(3)}${name.contains('a1c') ? '%' : ''}${when != null ? ' ($when)' : ''}';
        if (!labs.contains(entry)) labs.add(entry);
      }
      var body = s;
      if (_vitalClause.hasMatch(s) || _lab.hasMatch(s)) {
        final clauses = s.replaceAll(RegExp(r'[.!]+$'), '').split(RegExp(r',\s*(?:and\s+)?'));
        body = clauses.where((c) => !_vitalClause.hasMatch(c) && !_lab.hasMatch(c)).join(', ');
      }
      if (body.trim().isEmpty || !_findingVocab.hasMatch(body)) continue;
      final cleaned = _cleanFinding(body);
      if (cleaned.length > 3 && !findings.contains(cleaned)) findings.add(cleaned);
    }
    if (labs.isNotEmpty) lines.add('Labs: ${labs.join(', ')}.');
    if (findings.isEmpty) {
      lines.add('No exam findings documented.');
    } else {
      lines.addAll(findings.take(8));
    }
    return lines.join('\n');
  }

  static String _cleanFinding(String s) {
    var t = s.trim().replaceAll(RegExp(r'[.!]+$'), '');
    t = t.replaceFirst(_re(r'^(okay|ok|so|alright|now|well|good)[,.]?\s+'), '');
    t = t.replaceFirst(_re(r'^on (physical )?(examination|exam)[,:]?\s*'), '');
    final look = _re(r'^(?:looking at|checking|reviewing|examining|listening to)\s+(?:your |the |his |her )?(.+?)(?: right here| here)?[,:]\s*(?:there is |there are |you have |it shows |which shows |shows )?(.*)$').firstMatch(t);
    if (look != null) {
      var obj = look.group(1)!;
      final withM = _re(r'^(.+?)\s+with\s+(?:the\s+)?(.+)$').firstMatch(obj);
      if (withM != null) obj = '${withM.group(1)} (${withM.group(2)})';
      t = '${_capitalize(obj)}: ${look.group(2)}';
    }
    t = t.replaceFirst(_re(r'^comparing [^:,]+[:,]\s*'), '');
    t = t.replaceFirst(_re(r"^(there is|there are|there's)\s+"), '');
    t = t.replaceFirst(_re(r'^(the|your)\s+'), '');
    t = t.replaceAll(_re(r'\byour\s+'), '');
    t = t.replaceAll(_re(r'\byou have\s+'), '');
    t = t.replaceFirst(_re(r',?\s*\b(consistent with|compatible with|suggestive of|concerning for|suspicious for)\b.*$'), '');
    return '${_capitalize(t.trim())}.';
  }

  // ---------------------------------------------------------------------------
  // Plan
  // ---------------------------------------------------------------------------

  static final _planCue = _re(
    r'\b(prescrib\w*|start\w*|administer|give|continue|stop|discontinue|increase|decrease|adjust|add|titrate|switch|order\w*|obtain|x-ray|xray|mri|ct scan|ultrasound|'
    r'labs?|blood work|refer\w*|referral|follow[- ]?up|come back|activate|cath(eterization)? lab|moving (directly )?to|prepare|nasal cannula|fluids|rest|ice|crutches|'
    r'weight[- ]bearing|dark (quiet )?room|go home|emergency room|call 911|tighten|code stemi|schedule|admit|discharge|avoid|elevate|keep [a-z ]{0,15}elevated|brace|splint|sling|hydrat\w*)\b',
  );
  static final _results = _re(r'\b(shows|showed|reveals|demonstrates|there is|there are|is clear|has prominent)\b');
  static final _returnPrecaution = _re(r"^(if|should)\b|go to the (er|emergency)|call 911|return (to the (er|clinic)|if)|come back (if|sooner)");

  static bool _isPlanSentence(String s) {
    final l = s.toLowerCase().trim();
    if (l.endsWith('?')) return false;
    // Observations ("I see you're using crutches") are not orders.
    if (_re(r"^(i see|i noticed?|i can see|looks like|you look|you're|you are)\b").hasMatch(l)) return false;
    if (_results.hasMatch(l)) return false;
    if (_diagnosisStatement.hasMatch(l) && !_dose.hasMatch(l)) return false;
    if (_re(r"\b(won'?t|didn'?t|doesn'?t|not)\b").hasMatch(l) && !_returnPrecaution.hasMatch(l) && !_re(r'\b(do not|don.t) (bear|put|lift|drive|eat|drink)').hasMatch(l)) {
      return false;
    }
    if (_returnPrecaution.hasMatch(l)) return true;
    return _planCue.hasMatch(l) || (_med.hasMatch(l) && _dose.hasMatch(l));
  }

  static List<String> _planItems(List<String> doctorSide) {
    final items = <String>[];
    for (final raw in doctorSide) {
      if (!_isPlanSentence(raw)) continue;
      var s = raw.trim().replaceAll(RegExp('\\s*[\u2014\u2013]\\s*'), ', ').replaceAll(RegExp(r'[.!]+$'), '');
      if (_returnPrecaution.hasMatch(s.toLowerCase())) {
        final body = _stripPronouns(s.replaceFirst(_re(r'^(okay|ok|and|also|so)[,]?\s+'), ''));
        items.add('Return precautions: ${body[0].toLowerCase()}${body.substring(1)}.');
        continue;
      }
      s = s.replaceFirst(_re(r'^(in the meantime|meanwhile|for now)\s*[:,]\s*'), '');
      final fragments = s.split(_re(r',\s*and\s+|;\s*|,?\s+plus\s+|,\s+'));

      String? verb;
      String? indication;
      for (var f in fragments) {
        f = f.trim();
        if (f.isEmpty) continue;
        final ind = _re(r'^(?:and\s+)?for\s+(?:the\s+)?(.+)$').firstMatch(f);
        if (ind != null && !_med.hasMatch(f) && !_planCue.hasMatch(f.replaceFirst(_re(r'^(and\s+)?for\s+'), ''))) {
          indication = ind.group(1);
          continue;
        }
        // "take one right now with water" belongs to the previous order.
        if (items.isNotEmpty && _re(r'^(take (one|it|1|two|2)|then\b|with (water|food|meals))').hasMatch(f)) {
          final last = items.removeLast();
          items.add('${last.substring(0, last.length - 1)}, ${_cleanPlan(f)[0].toLowerCase()}${_cleanPlan(f).substring(1)}');
          continue;
        }
        var item = _cleanPlan(f);
        final v = _re(r'^(Start|Administer|Continue|Give|Stop)\b').firstMatch(item)?.group(1);
        if (v != null) {
          verb = v;
        } else if (verb != null && _med.hasMatch(item) && _med.firstMatch(item)!.start == 0) {
          item = '$verb ${item[0].toLowerCase()}${item.substring(1)}';
        }
        if (!_planCue.hasMatch(item) && !_med.hasMatch(item) && !_re(r'\bcode\b').hasMatch(item)) continue;
        if (item.replaceAll(RegExp(r'[^A-Za-z]'), '').length < 4) continue;
        if (indication != null) {
          item = '${item.substring(0, item.length - 1)} for $indication.';
          indication = null;
        }
        if (!items.contains(item)) items.add(item);
      }
    }
    return items.take(14).toList();
  }

  static String _stripPronouns(String s) => s
      .replaceAll(_re(r'\byour\s+'), '')
      .replaceAll(_re(r'\bwith me\b\s*'), '')
      .replaceAll(_re(r'\bfor the\s+'), 'for ')
      .replaceAll(_re(r'\bright now\b'), 'now')
      .replaceAll(_re(r'\bright (down the hall|here)\b\s*'), '')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();

  static String _cleanPlan(String f) {
    var t = f.trim().replaceAll(RegExp(r'[.!]+$'), '');
    final lead = _re(r'^(yes|yeah|okay|ok|so|alright|and|also|now|then|team|nursing|nurse|great|good)\b[,:]?\s*');
    while (lead.hasMatch(t)) {
      t = t.replaceFirst(lead, '');
    }
    final rules = <RegExp, String>{
      _re(r"^(?:i am|i'm|we are|we're) (?:going to |gonna )?(?:start(?:ing)?|put(?:ting)?) (?:you|him|her|them) on\s+"): 'Start ',
      _re(r"^(?:i|we) (?:want|would like|'d like|need) to start (?:you|him|her|them) on\s+"): 'Start ',
      _re(r'^(?:start|put) (?:you|him|her|them) on\s+'): 'Start ',
      _re(r"^(?:i am|i'm|we are|we're) (?:going to |gonna )?(?:prescrib\w*|giving you|sending you home with)\s+"): '',
      _re(r"^(?:i am|i'm|we are|we're) putting in\s+(?:an?\s+)?"): '',
      _re(r"^(?:i am|i'm|we are|we're) (?:going to |gonna )?(?:get|order|obtain|draw|send)\s+(?:you\s+)?(?:an?\s+|the\s+)?"): 'Obtain ',
      _re(r"^(?:let'?s )?make sure (?:you |to )?(?:take|keep taking|continue)\s+"): 'Continue ',
      _re(r"^(?:we are|we're|we will|we'll) (?:moving|going|heading)\b"): 'Proceed',
      _re(r"^(?:i want|i'd like|we want|we'd like)(?: you)? to\s+"): '',
      _re(r'^(?:we need|i need|need|you need|you should|you will need|please)(?: to)?\s+'): '',
      _re(r'^(?:an?|the)\s+'): '',
    };
    rules.forEach((k, v) => t = t.replaceFirst(k, v));
    t = _stripPronouns(t);
    t = t.replaceAllMapped(RegExp(r'(\d)(mg|mcg|ml|g)\b', caseSensitive: false), (m) => '${m.group(1)} ${m.group(2)!.toLowerCase()}');
    final o2 = _re(r'^start (\d+(?:\.\d+)?)\s?l\b\s*(?:via\s+)?(nasal cannula|non-?rebreather|face mask|nc)\b(.*)$').firstMatch(t);
    if (o2 != null) t = 'Supplemental oxygen ${o2.group(1)} L via ${o2.group(2)}${o2.group(3)}';
    t = t.trim();
    if (t.isEmpty) return t;
    return '${_capitalize(t)}.';
  }

  // ---------------------------------------------------------------------------
  // Assessment
  // ---------------------------------------------------------------------------

  static const _plainSymptom = {
    'R20.0': 'numbness',
    'R20.2': 'paresthesias',
    'R61': 'diaphoresis',
    'R07.81': 'pleuritic chest pain',
    'R07.89': 'chest pain',
    'R07.9': 'chest pain',
    'R06.02': 'shortness of breath',
    'R05.9': 'cough',
    'R50.9': 'fever',
    'H53.149': 'photophobia',
    'H53.19': 'visual disturbance',
    'R11.2': 'nausea with vomiting',
    'R11.0': 'nausea',
    'R11.10': 'vomiting',
    'R51.9': 'headache',
    'R68.84': 'jaw pain',
    'R00.0': 'tachycardia',
    'I95.9': 'hypotension',
    'R09.02': 'hypoxemia',
    'R53.83': 'fatigue',
    'R53.1': 'weakness',
    'R42': 'dizziness',
    'R10.9': 'abdominal pain',
    'R10.13': 'epigastric pain',
  };

  static const _stopwords = {
    'unspecified', 'other', 'without', 'involving', 'current', 'injury', 'initial', 'encounter', 'organism', 'intractable', 'status', 'complications',
    'artery', 'coronary', 'mellitus', 'elevation', 'migrainosus', 'specified', 'native', 'disease', 'disorder', 'right', 'left',
  };

  static String _plainName(ClaimDiagnosis d) {
    final p = _plainSymptom[d.code];
    if (p != null) return p;
    final eff = RegExp(r'^Effusion, (\w+) knee$').firstMatch(d.description);
    if (eff != null) return eff.group(1) == 'unspecified' ? 'knee effusion' : '${eff.group(1)} knee effusion';
    final pain = RegExp(r'^Pain in (\w+) knee$').firstMatch(d.description);
    if (pain != null) return pain.group(1) == 'unspecified' ? 'knee pain' : '${pain.group(1)} knee pain';
    return d.description.replaceAll(RegExp(r',\s*unspecified\b.*$'), '').toLowerCase();
  }

  static bool _sharesKeyword(String phrase, String description) {
    final p = phrase.toLowerCase();
    final words = description.toLowerCase().replaceAll(RegExp(r'[^a-z ]'), ' ').split(RegExp(r'\s+'));
    for (final w in words) {
      if (w.length < 5 || _stopwords.contains(w)) continue;
      if (p.contains(w.substring(0, 5))) return true;
    }
    return false;
  }

  static final _leadIn = _re(
    r"\b(?:you are having|you have|you've got|this is|it is|it's|that is|that's|diagnosis is|consistent with|compatible with|presentation of|sounds like|"
    r'suspicious for|suspect|likely|probably|probable|possible|possibly|concerning for|concern for|rule out|has|with)\s+',
  );

  /// The diagnosis in the physician's own words, from the sentence that
  /// supports it, or null when no matching phrase can be isolated.
  static String? _statedPhrase(String? evidence, String description) {
    if (evidence == null || evidence.isEmpty) return null;
    for (final m in _leadIn.allMatches(evidence)) {
      var rest = evidence.substring(m.end).split(RegExp(r'[,;.!?]')).first.trim();
      final strip = _re(r'^(an?|the|classic|typical|textbook|strongly|very|presentation of)\s+');
      while (strip.hasMatch(rest)) {
        rest = rest.replaceFirst(strip, '');
      }
      rest = rest.replaceAll(_re(r'\byour\b'), 'the');
      if (rest.isEmpty || rest.length > 70) continue;
      if (_sharesKeyword(rest, description)) return rest;
    }
    return null;
  }

  static String _withLaterality(String phrase, String description) {
    final side = RegExp(r'\b(right|left) (\w+)').firstMatch(description);
    if (side == null || _re(r'\b(right|left)\b').hasMatch(phrase)) return phrase;
    return '$phrase, ${side.group(1)} ${side.group(2)}';
  }

  static String _qualifier(ClaimDiagnosis d) {
    final hedge = RegExp(r'Documented as "([^"]+)"').firstMatch(d.note ?? '')?.group(1)?.toLowerCase() ?? '';
    if (RegExp(r'^(probable|probably|likely|presum)').hasMatch(hedge)) return 'Probable';
    if (RegExp(r'^(possible|possibly|may be|might be|could be|questionable)').hasMatch(hedge)) return 'Possible';
    if (RegExp(r'^(rule out|r/o)').hasMatch(hedge)) return 'Rule out';
    if (RegExp(r'^(consistent with|compatible with)').hasMatch(hedge)) return 'Findings consistent with';
    if (RegExp(r'^(versus|vs|differential)').hasMatch(hedge)) return 'Differential includes';
    return 'Suspected';
  }

  static final _testWord = _re(r'x-ray|xray|\bmri\b|\bct\b|ct scan|ultrasound|echocardiogram|biopsy|\blabs?\b|blood work|culture|panel');

  static String? _pendingTest(String phrase, List<String> planItems) {
    String? pick;
    for (final item in planItems) {
      if (!_testWord.hasMatch(item)) continue;
      final l = item.toLowerCase();
      final words = phrase.toLowerCase().split(RegExp(r'[^a-z]+')).where((w) => w.length > 3);
      if (l.contains('confirm') || words.any(l.contains)) {
        pick = item;
        break;
      }
      pick ??= item;
    }
    if (pick == null) return null;
    var t = pick.replaceAll(RegExp(r'\.$'), '').split(_re(r'\s+to (confirm|evaluate|rule|assess|look)\b|\s+for\s+|,\s*')).first;
    t = t.replaceFirst(_re(r'^(obtain|order|get|schedule|start)\s+'), '');
    t = t.replaceAll(_re(r'\b(urgent|stat|expedited|immediate|emergent)\s+'), '');
    return t.trim().isEmpty ? null : t.trim();
  }

  static List<String> _assessment(CodingResult coding, List<String> planItems) {
    final lines = <String>[];
    final seen = <String>{};
    final confirmed = coding.diagnoses.where((d) => d.status == DxStatus.billable && (d.source == DxSource.physicianConfirmed || d.source == DxSource.manual));
    for (final d in confirmed) {
      final phrase = _withLaterality(_statedPhrase(d.evidence, d.description) ?? d.description, d.description);
      if (seen.add(phrase.toLowerCase())) lines.add(_capitalize(phrase));
    }
    for (final d in coding.diagnoses.where((d) => d.status == DxStatus.billable && d.source == DxSource.history)) {
      final m = RegExp(r'\bmy ([a-z ]{3,30}?)(?=[?.!,]|$)', caseSensitive: false).firstMatch(d.evidence ?? '');
      final term = m != null && _sharesKeyword(m.group(1)!, d.description) ? m.group(1)! : d.description;
      final line = 'History of ${term.toLowerCase()}';
      if (seen.add(line.toLowerCase())) lines.add(line);
    }
    for (final d in coding.diagnoses.where((d) => d.status == DxStatus.uncertain)) {
      final phrase = _withLaterality(_statedPhrase(d.evidence, d.description) ?? d.description.toLowerCase(), d.description);
      // Two codes from one hedged sentence ("meniscal tear with hemarthrosis") are one assessment.
      if (!seen.add('u:${d.evidence ?? phrase}')) continue;
      final pending = _pendingTest(phrase, planItems);
      lines.add('${_qualifier(d)} $phrase${pending != null ? '; $pending pending' : ''}');
    }
    final hasDefinitive = lines.isNotEmpty;
    final hasUncertain = coding.diagnoses.any((d) => d.status == DxStatus.uncertain);
    final symptoms = <String>{
      for (final d in coding.diagnoses)
        if (d.status == DxStatus.billable && (d.source == DxSource.patientReported || d.source == DxSource.examFinding)) _plainName(d),
    }.toList();
    if (symptoms.isNotEmpty) {
      if (hasUncertain) {
        lines.add('Coded as symptoms until confirmed: ${symptoms.join(', ')}');
      } else if (hasDefinitive) {
        lines.add('Also documented: ${symptoms.join(', ')}');
      } else {
        lines.add('No diagnosis stated; presenting symptoms: ${symptoms.join(', ')}');
      }
    }
    return lines;
  }

  // ---------------------------------------------------------------------------
  // Clinical documentation improvement
  // ---------------------------------------------------------------------------

  static bool _isSymptomCode(String code) =>
      code.startsWith('R') || code.startsWith('H53.1') || code.startsWith('M25.4') || code.startsWith('M25.5') || code == 'I95.9';

  /// Documentation gaps found in this note. Empty when there are none.
  static List<String> cdiFor(CodingResult coding, String plan) {
    final out = <String>[];
    final uncertain = coding.diagnoses.where((d) => d.status == DxStatus.uncertain).toList();
    final seenEvidence = <String>{};
    for (final d in uncertain) {
      if (!seenEvidence.add(d.evidence ?? d.code)) continue;
      final phrase = _statedPhrase(d.evidence, d.description) ?? d.description.toLowerCase();
      final test = _pendingTest(phrase, plan.split('\n').map((l) => l.replaceFirst(RegExp(r'^\d+\.\s*'), '')).toList());
      out.add(test != null
          ? '${_qualifier(d)} $phrase is coded as its symptoms (outpatient guideline IV.H). When the $test result is back, document the diagnosis as confirmed or ruled out.'
          : '${_qualifier(d)} $phrase is coded as its symptoms (outpatient guideline IV.H). Document it without hedging if it is confirmed.');
    }

    final billable = coding.billable;
    for (final d in billable) {
      if (RegExp(r'unspecified (knee|ear|eye|side|hip|shoulder|ankle|foot|hand|arm|leg|wrist|elbow)', caseSensitive: false).hasMatch(d.description)) {
        out.add('Laterality is not documented for ${_plainName(d)} (${d.code}). State right or left.');
      }
    }

    if (billable.isNotEmpty) {
      final primary = billable.first;
      if (!_isSymptomCode(primary.code) && primary.description.toLowerCase().contains('unspecified')) {
        out.add('The primary diagnosis ${primary.code} (${primary.description}) is an unspecified code. Document type, site, cause or acuity if known.');
      }
      if (uncertain.isEmpty && billable.every((d) => _isSymptomCode(d.code))) {
        out.add('Only symptoms are documented. If a diagnosis was reached, state it explicitly so it can be coded.');
      }
    }

    for (final line in plan.split('\n')) {
      final item = line.replaceFirst(RegExp(r'^\d+\.\s*'), '');
      if (_re(r'^(follow up|return precautions)').hasMatch(item)) continue;
      for (final m in _med.allMatches(item)) {
        if (_dose.hasMatch(item.substring(m.start))) continue;
        final name = m.group(1)!;
        final msg = '${_capitalize(name)} is in the plan without a dose. Document dose, route, frequency and duration.';
        if (!out.contains(msg)) out.add(msg);
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static String _capitalize(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  static String _list(List<String> items, {String conjunction = 'and'}) {
    if (items.isEmpty) return '';
    if (items.length == 1) return items.first;
    final sep = items.any((i) => i.contains(',')) ? '; ' : ', ';
    if (items.length == 2 && sep == ', ') return '${items[0]} $conjunction ${items[1]}';
    return '${items.sublist(0, items.length - 1).join(sep)}$sep$conjunction ${items.last}';
  }
}
