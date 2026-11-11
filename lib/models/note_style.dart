/// How the clinician wants notes written. Kept on the provider profile, so
/// it is remembered for every visit.
enum NoteTemplate {
  soap('SOAP'),
  primaryCare('Primary care'),
  urgentCare('Urgent care'),
  psych('Psychiatry and therapy');

  final String label;
  const NoteTemplate(this.label);
}

enum NoteLength {
  brief('Brief'),
  standard('Standard'),
  detailed('Detailed');

  final String label;
  const NoteLength(this.label);
}

enum AbbreviationMode {
  asWritten('As written'),
  spellOut('Spell out'),
  abbreviate('Abbreviate');

  final String label;
  const AbbreviationMode(this.label);
}

class NoteStyle {
  final NoteTemplate template;
  final NoteLength length;
  final AbbreviationMode abbreviations;

  const NoteStyle({this.template = NoteTemplate.soap, this.length = NoteLength.standard, this.abbreviations = AbbreviationMode.asWritten});

  bool get isDefault => template == NoteTemplate.soap && length == NoteLength.standard && abbreviations == AbbreviationMode.asWritten;

  /// "Psychiatry and therapy, brief" for the note tab.
  String get summary => [
        template.label,
        if (length != NoteLength.standard) length.label.toLowerCase(),
        if (abbreviations == AbbreviationMode.abbreviate) 'abbreviated',
        if (abbreviations == AbbreviationMode.spellOut) 'spelled out',
      ].join(', ');

  NoteStyle copyWith({NoteTemplate? template, NoteLength? length, AbbreviationMode? abbreviations}) => NoteStyle(
        template: template ?? this.template,
        length: length ?? this.length,
        abbreviations: abbreviations ?? this.abbreviations,
      );

  Map<String, dynamic> toJson() => {'template': template.name, 'length': length.name, 'abbreviations': abbreviations.name};

  static NoteStyle fromJson(Object? j) {
    if (j is! Map) return const NoteStyle();
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) => values.firstWhere((v) => v.name == name, orElse: () => fallback);
    return NoteStyle(
      template: pick(NoteTemplate.values, j['template'], NoteTemplate.soap),
      length: pick(NoteLength.values, j['length'], NoteLength.standard),
      abbreviations: pick(AbbreviationMode.values, j['abbreviations'], AbbreviationMode.asWritten),
    );
  }

  @override
  bool operator ==(Object other) => other is NoteStyle && other.template == template && other.length == length && other.abbreviations == abbreviations;

  @override
  int get hashCode => Object.hash(template, length, abbreviations);
}
