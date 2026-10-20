import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/clinical_models.dart';
import '../models/patient_account.dart';
import '../theme/solis_theme.dart';

bool _isDark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

/// Small semantic label (STAT, Urgent, ICD-10, Abnormal). Always text plus
/// color, never color alone.
class StatusTag extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;

  const StatusTag({super.key, required this.label, required this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    final fg = SolisTheme.onTint(color, isDark: dark);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: SolisTheme.tint(color, isDark: dark),
        borderRadius: BorderRadius.circular(SolisTheme.radiusSm - 2),
        border: Border.all(color: SolisTheme.tintBorder(color, isDark: dark)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Urgency tag for CPOE orders. Routine stays neutral so STAT stands out.
class UrgencyTag extends StatelessWidget {
  final String urgency;

  const UrgencyTag({super.key, required this.urgency});

  @override
  Widget build(BuildContext context) {
    final u = urgency.toLowerCase();
    if (u == 'stat') {
      return const StatusTag(label: 'STAT', color: SolisTheme.danger, icon: Icons.priority_high_rounded);
    }
    if (u == 'urgent') {
      return const StatusTag(label: 'Urgent', color: SolisTheme.warning, icon: Icons.schedule_rounded);
    }
    return StatusTag(label: urgency, color: Theme.of(context).colorScheme.onSurfaceVariant);
  }
}

/// Card with a title row and optional trailing actions, used for note
/// sections and grouped lists.
class SectionCard extends StatelessWidget {
  final String title;
  final IconData? icon;
  final List<Widget> actions;
  final Widget child;
  final EdgeInsetsGeometry padding;

  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.actions = const [],
    this.padding = const EdgeInsets.fromLTRB(16, 8, 8, 16),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 20, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
                    ),
                  ),
                  ...actions,
                ],
              ),
            ),
            Padding(padding: const EdgeInsets.only(right: 8), child: child),
          ],
        ),
      ),
    );
  }
}

/// Vitals grid. Abnormal values get red text plus a warning icon and the
/// word "Abnormal" for screen readers.
class VitalsPanel extends StatelessWidget {
  final List<VitalSign> vitals;

  const VitalsPanel({super.key, required this.vitals});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = _isDark(context);
    final abnormalColor = SolisTheme.onTint(SolisTheme.danger, isDark: dark);

    return SectionCard(
      title: 'Vitals',
      icon: Icons.monitor_heart_outlined,
      child: Wrap(
        spacing: 24,
        runSpacing: 12,
        children: [
          for (final v in vitals)
            Semantics(
              label: '${v.label} ${v.value}${v.isAbnormal ? ', abnormal' : ''}',
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(v.label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (v.isAbnormal) ...[
                        Icon(Icons.warning_amber_rounded, size: 16, color: abnormalColor),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        v.value,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: v.isAbnormal ? abnormalColor : theme.colorScheme.onSurface,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
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

/// The primary capture control: a large round microphone button. 96dp so it
/// can be hit without looking while facing the patient.
class RecordButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final double size;

  const RecordButton({super.key, required this.onPressed, this.size = 96});

  @override
  Widget build(BuildContext context) {
    // excludeSemantics drops the InkWell's own tap action, so the node needs
    // its own onTap or a TalkBack double-tap would do nothing.
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: 'Start recording',
      onTap: onPressed,
      excludeSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: SolisTheme.primaryBlue,
          shape: const CircleBorder(),
          elevation: 2,
          shadowColor: SolisTheme.primaryBlue.withAlpha(90),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Icon(Icons.mic_rounded, size: size * 0.42, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// Microphone level bars driven by the capture source. Each bar is one
/// recent level reading (0 to 1), newest on the right, so a silent or dead
/// microphone shows flat bars. Nothing here is animated for show.
class LevelMeter extends StatefulWidget {
  final ValueListenable<double> level;
  final bool active;
  final Color color;
  final int bars;

  const LevelMeter({super.key, required this.level, required this.active, required this.color, this.bars = 9});

  @override
  State<LevelMeter> createState() => _LevelMeterState();
}

class _LevelMeterState extends State<LevelMeter> {
  late List<double> _history = List.filled(widget.bars, 0);

  @override
  void initState() {
    super.initState();
    widget.level.addListener(_onLevel);
  }

  @override
  void didUpdateWidget(LevelMeter old) {
    super.didUpdateWidget(old);
    if (!identical(old.level, widget.level)) {
      old.level.removeListener(_onLevel);
      widget.level.addListener(_onLevel);
    }
    if (old.bars != widget.bars) _history = List.filled(widget.bars, 0);
  }

  @override
  void dispose() {
    widget.level.removeListener(_onLevel);
    super.dispose();
  }

  void _onLevel() {
    if (!mounted) return;
    setState(() => _history = [..._history.skip(1), widget.level.value.clamp(0.0, 1.0)]);
  }

  @override
  Widget build(BuildContext context) {
    final peak = _history.fold<double>(0, (m, v) => v > m ? v : m);
    return Semantics(
      label: widget.active ? 'Microphone level ${(peak * 100).round()} percent' : 'Microphone paused',
      excludeSemantics: true,
      child: SizedBox(
        height: 36,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (final v in _history)
              // Wide bars with a hairline gap: silence reads as a flat line,
              // not a row of dots.
              Container(
                width: 7,
                height: widget.active ? 3 + 31 * v : 3,
                margin: const EdgeInsets.symmetric(horizontal: 0.5),
                decoration: BoxDecoration(
                  color: widget.active ? widget.color : widget.color.withAlpha(90),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Color and icon for a visit status, shared by every list that shows one.
(Color, IconData) visitStatusStyle(VisitStatus s) => switch (s) {
      VisitStatus.inProgress => (SolisTheme.info, Icons.edit_note_rounded),
      VisitStatus.signed => (SolisTheme.teal, Icons.draw_outlined),
      VisitStatus.claimReady => (SolisTheme.success, Icons.task_alt_rounded),
      VisitStatus.queued => (SolisTheme.warning, Icons.schedule_send_outlined),
      VisitStatus.submitted => (SolisTheme.info, Icons.outbox_outlined),
      VisitStatus.rejected => (SolisTheme.danger, Icons.error_outline_rounded),
      VisitStatus.paid => (SolisTheme.success, Icons.payments_outlined),
      VisitStatus.denied => (SolisTheme.danger, Icons.block_rounded),
    };

/// A visit's status as icon plus word.
class VisitStatusTag extends StatelessWidget {
  final VisitStatus status;
  const VisitStatusTag({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = visitStatusStyle(status);
    return StatusTag(label: visitStatusLabel(status), color: color, icon: icon);
  }
}

/// Inline banner for draft / signed state at the top of the note.
class NoteBanner extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Color color;

  const NoteBanner({super.key, required this.icon, required this.title, required this.message, required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = _isDark(context);
    final fg = SolisTheme.onTint(color, isDark: dark);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SolisTheme.tint(color, isDark: dark),
        borderRadius: BorderRadius.circular(SolisTheme.radiusLg),
        border: Border.all(color: SolisTheme.tintBorder(color, isDark: dark)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: fg),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall?.copyWith(color: fg)),
                const SizedBox(height: 2),
                Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Centered empty state with an icon, a title and one line of guidance.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const EmptyState({super.key, required this.icon, required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(
        children: [
          Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
