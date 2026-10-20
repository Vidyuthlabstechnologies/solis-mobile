import 'dart:async';

import 'package:flutter/material.dart';

import '../services/transcription/native_speech_provider.dart';
import '../theme/solis_theme.dart';
import 'encounter_widgets.dart';

/// Status and one-time model download for the on-device speech engine, which
/// separates doctor and patient by voice without audio leaving the phone.
class OnDeviceSpeechCard extends StatefulWidget {
  const OnDeviceSpeechCard({super.key});

  @override
  State<OnDeviceSpeechCard> createState() => _OnDeviceSpeechCardState();
}

class _OnDeviceSpeechCardState extends State<OnDeviceSpeechCard> {
  final _models = ModelManager();
  NativeSpeechAvailability? _availability;
  StreamSubscription<ModelPrepareProgress>? _download;
  ModelPrepareProgress? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _download?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    final a = await NativeSpeechProvider.register(models: _models, options: onDeviceSpeechOptions);
    if (mounted) setState(() => _availability = a);
  }

  void _start() {
    setState(() {
      _error = null;
      _progress = null;
    });
    _download = _models.prepare().listen(
      (p) {
        if (!mounted) return;
        setState(() => _progress = p);
        if (p.stage == ModelPrepareStage.failed) {
          setState(() => _error = p.error ?? 'Download failed.');
          _download?.cancel();
          _download = null;
        } else if (p.stage == ModelPrepareStage.ready) {
          _download = null;
          _check();
        }
      },
      onDone: () {
        if (mounted) setState(() => _download = null);
      },
    );
  }

  static String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final a = _availability;
    final downloading = _download != null;
    final p = _progress;

    final Widget tag;
    if (a == null) {
      tag = StatusTag(label: 'Checking', color: cs.onSurfaceVariant, icon: Icons.hourglass_empty_rounded);
    } else if (a.canStart) {
      tag = const StatusTag(label: 'Ready', color: SolisTheme.success, icon: Icons.check_rounded);
    } else if (!a.supported) {
      tag = StatusTag(label: 'Not available', color: cs.onSurfaceVariant, icon: Icons.block_rounded);
    } else {
      tag = StatusTag(label: 'Not downloaded', color: cs.onSurfaceVariant, icon: Icons.download_outlined);
    }

    return SectionCard(
      title: 'On-device voice separation',
      icon: Icons.phone_android_outlined,
      actions: [tag],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Tells doctor and patient apart by voice on this phone. No audio leaves the device, so no vendor BAA is needed.',
            style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          if (a != null && !a.supported && a.reason != null) ...[
            const SizedBox(height: 8),
            Text(a.reason!, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ],
          if (a != null && a.supported && !a.modelsReady) ...[
            const SizedBox(height: 12),
            if (downloading && p != null) ...[
              LinearProgressIndicator(value: p.totalBytes > 0 ? p.receivedBytes / p.totalBytes : null),
              const SizedBox(height: 8),
              Text(
                p.totalBytes > 0 ? 'Downloading ${_mb(p.receivedBytes)} of ${_mb(p.totalBytes)}' : 'Preparing',
                style: theme.textTheme.bodySmall,
              ),
            ] else
              OutlinedButton.icon(
                onPressed: downloading ? null : _start,
                icon: const Icon(Icons.download_outlined),
                label: Text(a.downloadBytes > 0 ? 'Download speech models (${_mb(a.downloadBytes)})' : 'Download speech models'),
              ),
            if (!downloading)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Use Wi-Fi. Downloads resume if interrupted.', style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: cs.error)),
          ],
        ],
      ),
    );
  }
}

/// Clinician and patient: two voices gives the most reliable split.
const onDeviceSpeechOptions = NativeSpeechOptions(numSpeakers: 2);
