import 'package:flutter/material.dart';

import '../services/billing/integration_settings.dart';
import '../services/billing/x12_837p.dart';
import '../services/integrations.dart';
import '../theme/solis_theme.dart';
import '../widgets/code_sets_card.dart';
import '../widgets/encounter_widgets.dart';
import '../widgets/on_device_speech_card.dart';

/// Connect SOLIS to the clearinghouse and cloud transcription. Keys are kept
/// in Android Keystore-backed secure storage on this phone and are never
/// shown again in full.
class IntegrationsScreen extends StatefulWidget {
  const IntegrationsScreen({super.key});

  @override
  State<IntegrationsScreen> createState() => _IntegrationsScreenState();
}

class _IntegrationsScreenState extends State<IntegrationsScreen> {
  IntegrationSettings get _s => Integrations.settings;
  final _stedi = TextEditingController();
  final _deepgram = TextEditingController();
  late final SubmitterConfig? _cfg = _s.submitterConfig;
  late final _submitterName = TextEditingController(text: _cfg?.submitterName ?? '');
  late final _submitterId = TextEditingController(text: _cfg?.submitterId ?? '');
  late final _isaSender = TextEditingController(text: _cfg?.isaSenderId ?? '');
  late final _isaReceiver = TextEditingController(text: _cfg?.isaReceiverId ?? 'STEDITEST');
  late final _contact = TextEditingController(text: _cfg?.submitterContactName ?? 'BILLING');
  late final _phone = TextEditingController(text: _cfg?.submitterPhone ?? '');
  late bool _test = _cfg?.isTest ?? true;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_stedi, _deepgram, _submitterName, _submitterId, _isaSender, _isaReceiver, _contact, _phone]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      if (_stedi.text.trim().isNotEmpty) await _s.setStediApiKey(_stedi.text.trim());
      if (_deepgram.text.trim().isNotEmpty) await _s.setDeepgramApiKey(_deepgram.text.trim());
      if (_submitterName.text.trim().isNotEmpty || _submitterId.text.trim().isNotEmpty) {
        final base = _cfg;
        await _s.setSubmitterConfig(SubmitterConfig(
          submitterName: _submitterName.text.trim(),
          submitterId: _submitterId.text.trim(),
          isaSenderId: _isaSender.text.trim().isEmpty ? _submitterId.text.trim() : _isaSender.text.trim(),
          isaReceiverId: _isaReceiver.text.trim(),
          submitterContactName: _contact.text.trim().isEmpty ? 'BILLING' : _contact.text.trim(),
          submitterPhone: _phone.text.replaceAll(RegExp(r'[^0-9]'), ''),
          usageIndicator: _test ? 'T' : 'P',
          interchangeControlNumber: base?.interchangeControlNumber ?? 1,
          groupControlNumber: base?.groupControlNumber ?? 1,
          transactionControlNumber: base?.transactionControlNumber ?? 1,
        ));
      }
      _stedi.clear();
      _deepgram.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Integrations saved on this phone.')));
      setState(() {});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _remove(String what) async {
    if (what == 'stedi') await _s.setStediApiKey(null);
    if (what == 'deepgram') await _s.setDeepgramApiKey(null);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    Widget status(bool ok, String okText, String missingText) => StatusTag(
          label: ok ? okText : missingText,
          color: ok ? SolisTheme.success : cs.onSurfaceVariant,
          icon: ok ? Icons.check_rounded : Icons.link_off_rounded,
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Integrations')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            'Keys are stored in encrypted storage on this phone only. For a whole practice, use the key vault on your computer so keys live on the SOLIS server instead.',
            style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Clearinghouse (Stedi)',
            icon: Icons.outbox_outlined,
            actions: [status(_s.hasStediApiKey, 'Connected ${_s.stediKeyHint}', 'Not connected')],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Sends claims, checks eligibility at check-in, and tracks claim status.', style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 12),
                TextField(
                  controller: _stedi,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(labelText: _s.hasStediApiKey ? 'Replace API key' : 'API key', prefixIcon: const Icon(Icons.key_outlined)),
                ),
                if (_s.hasStediApiKey)
                  Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => _remove('stedi'), child: const Text('Remove key'))),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: true, label: Text('Test claims')),
                    ButtonSegment(value: false, label: Text('Production')),
                  ],
                  selected: {_test},
                  onSelectionChanged: (v) => setState(() => _test = v.first),
                ),
                const SizedBox(height: 4),
                Text(
                  _test ? 'Claims are marked as test (T) and are not paid.' : 'Claims go to payers for payment (P). Use after payer enrollment is complete.',
                  style: theme.textTheme.bodySmall?.copyWith(color: _test ? cs.onSurfaceVariant : SolisTheme.onTint(SolisTheme.warning, isDark: theme.brightness == Brightness.dark)),
                ),
                const SizedBox(height: 12),
                TextField(controller: _submitterName, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Submitter name')),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: _submitterId, decoration: const InputDecoration(labelText: 'Submitter ID'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _isaReceiver, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Receiver ID'))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: _contact, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Billing contact'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Contact phone'))),
                ]),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Cloud transcription (Deepgram)',
            icon: Icons.graphic_eq_rounded,
            actions: [status(_s.hasDeepgramApiKey, 'Connected ${_s.deepgramKeyHint}', 'On-device only')],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Separates doctor and patient by voice in the cloud. Use only after a BAA with Deepgram is signed. Without it, SOLIS uses the on-device engine.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _deepgram,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(labelText: _s.hasDeepgramApiKey ? 'Replace API key' : 'API key', prefixIcon: const Icon(Icons.key_outlined)),
                ),
                if (_s.hasDeepgramApiKey)
                  Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => _remove('deepgram'), child: const Text('Remove key'))),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const OnDeviceSpeechCard(),
          const SizedBox(height: 12),
          const CodeSetsCard(),
        ],
      ),
    );
  }
}
