import 'package:flutter/material.dart';

import '../models/claim_models.dart';
import '../theme/solis_theme.dart';
import 'knowledge_widgets.dart';

/// What the clinician chose in the sign sheet.
class SignSheetResult {
  final bool markOrders;
  const SignSheetResult({required this.markOrders});
}

/// The final review before signing: attestation, the claim that will be
/// billed, every error and warning with its Why, coverage, and the orders to
/// mark as sent. One button signs and, when the claim is clean and a
/// clearinghouse is connected, sends it. With errors it only signs, and the
/// visit opens on the claim checks.
class SignAndSendSheet extends StatefulWidget {
  final String attestation;
  final String? claimId;
  final String? primaryDiagnosis;
  final List<String> services;
  final double? total;
  final List<ClaimIssue> errors;
  final List<ClaimIssue> warnings;
  final String? eligibility;
  final int ordersToMark;
  final bool connected;
  final bool testMode;
  final String? payerName;

  const SignAndSendSheet({
    super.key,
    required this.attestation,
    required this.claimId,
    required this.primaryDiagnosis,
    required this.services,
    required this.total,
    required this.errors,
    required this.warnings,
    required this.eligibility,
    required this.ordersToMark,
    required this.connected,
    required this.testMode,
    required this.payerName,
  });

  /// The main button's words for these inputs.
  static String actionLabel({required bool hasClaim, required bool hasErrors, required bool connected, required bool testMode}) {
    if (!hasClaim || hasErrors) return 'Sign note';
    if (connected) return testMode ? 'Sign and send test claim' : 'Sign and send claim';
    return 'Sign and mark ready';
  }

  @override
  State<SignAndSendSheet> createState() => _SignAndSendSheetState();
}

class _SignAndSendSheetState extends State<SignAndSendSheet> {
  late bool _markOrders = widget.ordersToMark > 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final hasClaim = widget.claimId != null;
    final hasErrors = widget.errors.isNotEmpty;
    final label = SignAndSendSheet.actionLabel(hasClaim: hasClaim, hasErrors: hasErrors, connected: widget.connected, testMode: widget.testMode);

    Widget row(IconData icon, String text, {Color? color, TextStyle? style}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 20, color: color ?? cs.onSurfaceVariant)),
              const SizedBox(width: 12),
              Expanded(child: Text(text, style: style ?? theme.textTheme.bodyMedium)),
            ],
          ),
        );

    Widget issue(ClaimIssue i, bool error) {
      final color = SolisTheme.onTint(error ? SolisTheme.danger : SolisTheme.warning, isDark: dark);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(error ? Icons.error_outline_rounded : Icons.warning_amber_rounded, size: 20, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(i.title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  if (i.ruleId != null || i.citation != null) WhyButton(issue: i),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                children: [
                  Text('Review and sign', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(widget.attestation, style: theme.textTheme.bodyLarge),
                  if (hasClaim) ...[
                    const SizedBox(height: 16),
                    Text('Claim ${widget.claimId}', style: theme.textTheme.titleSmall?.copyWith(color: cs.primary)),
                    const SizedBox(height: 4),
                    if (widget.primaryDiagnosis != null) row(Icons.local_hospital_outlined, widget.primaryDiagnosis!),
                    for (final s in widget.services) row(Icons.medical_services_outlined, s),
                    if (widget.total != null)
                      row(Icons.receipt_long_outlined, 'Total \$${widget.total!.toStringAsFixed(2)}${widget.payerName == null ? '' : ' to ${widget.payerName}'}',
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    if (widget.eligibility != null) row(Icons.verified_outlined, widget.eligibility!),
                    const SizedBox(height: 12),
                    if (!hasErrors && widget.warnings.isEmpty)
                      row(Icons.fact_check_outlined, 'All claim checks pass.', color: SolisTheme.onTint(SolisTheme.success, isDark: dark)),
                    if (hasErrors)
                      row(Icons.error_outline_rounded,
                          '${widget.errors.length} ${widget.errors.length == 1 ? 'issue stops' : 'issues stop'} the claim. Signing opens the claim checks next.',
                          color: SolisTheme.onTint(SolisTheme.danger, isDark: dark)),
                    for (final i in widget.errors) issue(i, true),
                    for (final i in widget.warnings) issue(i, false),
                  ],
                  if (widget.ordersToMark > 0) ...[
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      key: const Key('sign_mark_orders'),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _markOrders,
                      onChanged: (v) => setState(() => _markOrders = v ?? false),
                      title: Text('Mark ${widget.ordersToMark} ${widget.ordersToMark == 1 ? 'order' : 'orders'} as sent'),
                      subtitle: const Text('Enter them in your EHR or ordering system.'),
                    ),
                  ],
                  if (hasClaim && !hasErrors && widget.connected && widget.testMode) ...[
                    const SizedBox(height: 4),
                    row(Icons.science_outlined, 'Test mode: the clearinghouse checks the claim but no payer pays it.'),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: LayoutBuilder(builder: (context, c) {
                final confirm = SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    key: const Key('sign_confirm'),
                    onPressed: () => Navigator.pop(context, SignSheetResult(markOrders: _markOrders)),
                    icon: Icon(label.contains('send') ? Icons.outbox_outlined : Icons.draw_outlined),
                    label: Text(label, overflow: TextOverflow.ellipsis),
                  ),
                );
                final keep = TextButton(onPressed: () => Navigator.pop(context), child: const Text('Keep reviewing'));
                // Narrow phones and large text: the main action gets the full width.
                if (c.maxWidth < 380 || MediaQuery.textScalerOf(context).scale(16) > 22) {
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [confirm, const SizedBox(height: 4), keep]);
                }
                return Row(children: [keep, const SizedBox(width: 8), Expanded(child: confirm)]);
              }),
            ),
          ],
        ),
      ),
    );
  }
}
