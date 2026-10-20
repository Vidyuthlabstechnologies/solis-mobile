import 'package:flutter/material.dart';

import '../models/claim_models.dart';
import '../services/codesets/icd_notes.dart';
import '../services/codesets/knowledge_base.dart';
import '../services/codesets/reference_data.dart';
import '../services/codesets/seventh_character.dart';
import '../theme/solis_theme.dart';

/// Opens the "Why" explanation of a claim check: the rule in plain English,
/// its official citations and the guideline text, all from the bundled
/// knowledge base (offline).
Future<void> showRuleExplanation(BuildContext context, ClaimIssue issue, {DateTime? dateOfService}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
      child: RuleExplanationSheet(issue: issue, knowledge: ReferenceData.knowledge, dateOfService: dateOfService),
    ),
  );
}

/// Body of the "Why" bottom sheet. Works with fewer details when the
/// knowledge base is not loaded: the check's own text and citation remain.
class RuleExplanationSheet extends StatelessWidget {
  final ClaimIssue issue;
  final KnowledgeBase? knowledge;

  /// The visit's date of service: the Tabular notes shown are from its
  /// ICD-10-CM edition (latest when null).
  final DateTime? dateOfService;

  const RuleExplanationSheet({super.key, required this.issue, this.knowledge, this.dateOfService});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final rule = issue.ruleId == null ? null : knowledge?.rule(issue.ruleId!);
    final citations = rule?.citations ?? [if (issue.citation != null) issue.citation!];
    final sections = <GuidelineSection>[
      for (final ref in rule?.guidelineRefs ?? const <String>[])
        ...?knowledge?.excerpt(ref),
    ];
    final seen = <String>{};
    final excerpt = [for (final s in sections) if (seen.add(s.id)) s];
    final notes = issue.code == null ? const <TabularNote>[] : codeNotesFor(issue.code!, dateOfService: dateOfService);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant);

    Widget heading(String text) => Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 6),
          child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: cs.primary)),
        );

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        Text(rule?.title ?? issue.title, style: theme.textTheme.titleLarge),
        if (issue.ruleId != null) ...[
          const SizedBox(height: 4),
          Text('Rule ${issue.ruleId}', style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
        ],
        heading('The rule'),
        Text(rule?.rule ?? issue.detail, style: theme.textTheme.bodyLarge),
        if (rule != null) ...[
          heading('On this claim'),
          Text(issue.detail, style: muted),
        ],
        if (citations.isNotEmpty) ...[
          heading('Official source'),
          for (final c in citations)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 8),
                    child: Icon(Icons.menu_book_outlined, size: 18, color: cs.onSurfaceVariant),
                  ),
                  Expanded(child: Text(c, style: theme.textTheme.bodyMedium)),
                ],
              ),
            ),
        ],
        if (excerpt.isNotEmpty) ...[
          heading('ICD-10-CM Official Guidelines FY2027'),
          for (final s in excerpt.take(8))
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(SolisTheme.radiusSm),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Section ${s.id}  ${s.title}', style: theme.textTheme.labelLarge),
                  if (s.text.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(s.text, style: theme.textTheme.bodyMedium),
                  ],
                ],
              ),
            ),
          if (excerpt.length > 8)
            Text('${excerpt.length - 8} more subsections in the guidelines.', style: muted),
        ],
        if (notes.isNotEmpty) ...[
          heading('Tabular notes for ${issue.code}'),
          CodeNotesList(notes: notes, dateOfService: dateOfService),
        ],
      ],
    );
  }
}

/// Tabular notes worth showing for [code]: everything at the code and its
/// categories, plus the actionable block and chapter notes (Excludes1, code
/// first, use additional code). [dateOfService] picks the ICD-10-CM edition
/// (FY2026 through 2026-09-30, FY2027 from 2026-10-01); latest when null.
List<TabularNote> codeNotesFor(String code, {DateTime? dateOfService}) {
  final notes = dateOfService == null ? ReferenceData.notes : ReferenceData.notesFor(dateOfService);
  if (notes == null) return const [];
  return [
    for (final n in notes.notesFor(code))
      if (!n.isRange || n.kind == NoteKind.excludes1 || n.kind == NoteKind.codeFirst || n.kind == NoteKind.useAdditional) n,
  ];
}

/// The notes grouped by kind (Excludes1, Excludes2, Code first, Use
/// additional code, Code also, Note), with where each comes from, plus the
/// 7th character values when the code needs one.
class CodeNotesList extends StatelessWidget {
  final List<TabularNote> notes;
  final String? seventhFor;
  final DateTime? dateOfService;

  const CodeNotesList({super.key, required this.notes, this.seventhFor, this.dateOfService});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final seventh = seventhFor == null ? null : _seventhTable(dateOfService)?.ruleFor(seventhFor!);
    final small = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final kind in NoteKind.values)
          if (notes.any((n) => n.kind == kind)) ...[
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: Text(noteKindLabel(kind), style: theme.textTheme.labelLarge),
            ),
            for (final n in notes.where((n) => n.kind == kind))
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 2),
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: n.text, style: theme.textTheme.bodyMedium),
                    TextSpan(text: '  (at ${n.at})', style: small),
                  ]),
                ),
              ),
          ],
        if (seventh != null) ...[
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Text('7th character (${seventh.prefix})', style: theme.textTheme.labelLarge),
          ),
          for (final e in seventh.characters.entries)
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 2),
              child: Text('${e.key}  ${e.value}', style: theme.textTheme.bodyMedium),
            ),
        ],
      ],
    );
  }
}

/// A compact, collapsible "Coding notes" section for one ICD-10-CM code.
/// Shows nothing when the code has no notes or the notes are not loaded.
class CodeNotesToggle extends StatefulWidget {
  final String code;
  final bool initiallyExpanded;
  final DateTime? dateOfService;

  const CodeNotesToggle({super.key, required this.code, this.initiallyExpanded = false, this.dateOfService});

  @override
  State<CodeNotesToggle> createState() => _CodeNotesToggleState();
}

class _CodeNotesToggleState extends State<CodeNotesToggle> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final notes = codeNotesFor(widget.code, dateOfService: widget.dateOfService);
    final seventh = _seventhTable(widget.dateOfService)?.ruleFor(widget.code);
    final count = notes.length + (seventh == null ? 0 : 1);
    if (count == 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.only(right: 8),
            alignment: Alignment.centerLeft,
          ),
          onPressed: () => setState(() => _open = !_open),
          icon: Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded),
          label: Text('Coding notes ($count)'),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: CodeNotesList(notes: notes, seventhFor: widget.code, dateOfService: widget.dateOfService),
          ),
      ],
    );
  }
}

/// The small "Why" text button under a claim check.
class WhyButton extends StatelessWidget {
  final ClaimIssue issue;
  final DateTime? dateOfService;

  const WhyButton({super.key, required this.issue, this.dateOfService});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.only(right: 8),
        alignment: Alignment.centerLeft,
      ),
      onPressed: () => showRuleExplanation(context, issue, dateOfService: dateOfService),
      icon: const Icon(Icons.help_outline_rounded, size: 18),
      label: const Text('Why'),
    );
  }
}

/// The 7th character definitions of the edition for [dateOfService] (latest
/// when null).
SeventhCharacters? _seventhTable(DateTime? dateOfService) =>
    dateOfService == null ? ReferenceData.seventh : ReferenceData.seventhFor(dateOfService);
