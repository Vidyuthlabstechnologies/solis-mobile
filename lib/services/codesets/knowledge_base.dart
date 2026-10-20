// The coding knowledge base the claim checks are explained from, offline:
//
//   rule_catalog.tsv.gz       id, title, severity, short citation, all
//                             citations, plain-English rule, guideline refs
//                             (knowledge/rules/rule_catalog.json plus the
//                             claim-form rules of tool/build_code_assets.py)
//   guidelines_fy2027.tsv.gz  section id, title, text of the ICD-10-CM
//                             Official Guidelines for Coding and Reporting
//                             FY2027 (public domain, CMS and NCHS)
//
// The guideline text keeps paragraphs as a literal "\n" in the TSV.

import 'code_set_loader.dart';

/// One rule of the catalog.
class RuleInfo {
  const RuleInfo({
    required this.id,
    required this.title,
    required this.severity,
    required this.citation,
    required this.citations,
    required this.rule,
    this.guidelineRefs = const [],
  });

  final String id;
  final String title;

  /// "error", "warning" or "info".
  final String severity;

  /// Primary short citation, for example "ICD-10-CM Guidelines IV.H".
  final String citation;

  /// Every source, short form, for example "ICD-10-CM Guidelines I.A.13;
  /// MCE v44 edit 6".
  final List<String> citations;

  /// The rule in plain English, paraphrased from the cited official text.
  final String rule;

  /// ICD-10-CM guideline sections the rule cites, for example "IV.H".
  final List<String> guidelineRefs;
}

/// One section of the ICD-10-CM Official Guidelines.
class GuidelineSection {
  const GuidelineSection(this.id, this.title, this.text);

  /// Section id, for example "I.C.4.a.3".
  final String id;
  final String title;

  /// Paragraphs separated by a newline.
  final String text;
}

class KnowledgeBase {
  KnowledgeBase._(this._rules, this._sections, this._order);

  factory KnowledgeBase.parse({String? rules, String? guidelines}) {
    final r = <String, RuleInfo>{};
    for (final row in tsvRows(rules ?? '')) {
      if (row.length < 6) continue;
      r[row[0]] = RuleInfo(
        id: row[0],
        title: row[1],
        severity: row[2],
        citation: row[3],
        citations: row[4].split('; ').where((c) => c.isNotEmpty).toList(),
        rule: row[5],
        guidelineRefs: row.length > 6 && row[6].isNotEmpty ? row[6].split(',') : const [],
      );
    }
    final s = <String, GuidelineSection>{};
    final order = <String>[];
    for (final row in tsvRows(guidelines ?? '')) {
      if (row.length < 2) continue;
      final text = row.length > 2 ? row[2].replaceAll(r'\n', '\n') : '';
      if (!s.containsKey(row[0])) order.add(row[0]);
      s[row[0]] = GuidelineSection(row[0], row[1], text);
    }
    return KnowledgeBase._(r, s, order);
  }

  /// Both assets, or null when neither is bundled.
  static Future<KnowledgeBase?> load() async {
    final rules = await CodeSetLoader.load(CodeSetFiles.ruleCatalog, _text);
    final guidelines = await CodeSetLoader.load(CodeSetFiles.guidelines, _text);
    if (rules == null && guidelines == null) return null;
    return KnowledgeBase.parse(rules: rules?.value, guidelines: guidelines?.value);
  }

  static _Text _text(String s) => _Text(s);

  final Map<String, RuleInfo> _rules;
  final Map<String, GuidelineSection> _sections;
  final List<String> _order;

  int get ruleCount => _rules.length;
  int get sectionCount => _sections.length;

  RuleInfo? rule(String id) => _rules[id];

  GuidelineSection? section(String id) => _sections[id];

  /// The guideline section [id] with its subsections, in document order. A
  /// reference deeper than the extracted headings falls back to the nearest
  /// enclosing section. Empty when nothing matches.
  List<GuidelineSection> excerpt(String id) {
    var key = id.trim();
    while (key.isNotEmpty && !_sections.containsKey(key)) {
      final dot = key.lastIndexOf('.');
      if (dot <= 0) return const [];
      key = key.substring(0, dot);
    }
    if (key.isEmpty) return const [];
    return [
      for (final s in _order)
        if (s == key || s.startsWith('$key.')) _sections[s]!,
    ];
  }
}

/// Wrapper so raw text can go through [CodeSetLoader.load], which caches by
/// result type.
class _Text {
  const _Text(this.value);
  final String value;
}
