import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/front_desk.dart';

/// Asks the clinician for a new PIN and turns front desk mode on.
/// Returns true when it is on.
Future<bool> showTurnOnFrontDesk(BuildContext context) async {
  final ok = await showDialog<bool>(context: context, builder: (_) => const _TurnOnDialog());
  return ok == true;
}

/// Asks for the PIN and turns front desk mode off. Returns true when off.
/// [onForgot] signs out, which also clears front desk mode.
Future<bool> showTurnOffFrontDesk(BuildContext context, {required Future<void> Function() onForgot}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _TurnOffDialog(onForgot: onForgot),
  );
  return ok == true;
}

TextField _pinField(TextEditingController c, String label, {Key? key, bool autofocus = false, String? error, ValueChanged<String>? onSubmitted}) => TextField(
  key: key,
  controller: c,
  autofocus: autofocus,
  obscureText: true,
  keyboardType: TextInputType.number,
  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
  decoration: InputDecoration(labelText: label, errorText: error),
  onSubmitted: onSubmitted,
);

class _TurnOnDialog extends StatefulWidget {
  const _TurnOnDialog();
  @override
  State<_TurnOnDialog> createState() => _TurnOnDialogState();
}

class _TurnOnDialogState extends State<_TurnOnDialog> {
  final _pin = TextEditingController();
  final _again = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _again.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!FrontDesk.validPin(_pin.text)) {
      setState(() => _error = 'Use ${FrontDesk.minPinLength} to 8 digits.');
      return;
    }
    if (_pin.text != _again.text) {
      setState(() => _error = 'The two PINs do not match.');
      return;
    }
    await FrontDesk.instance.turnOn(_pin.text);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('front_desk_on_dialog'),
    title: const Text('Hand the phone to the front desk'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Staff can scan insurance cards and add or correct patient details. '
            'Notes, billing and claims stay hidden. Front desk mode is free.',
          ),
          const SizedBox(height: 12),
          _pinField(_pin, 'Choose a PIN', key: const Key('front_desk_pin'), autofocus: true, error: _error),
          const SizedBox(height: 8),
          _pinField(_again, 'Enter it again', key: const Key('front_desk_pin_again'), onSubmitted: (_) => _save()),
          const SizedBox(height: 8),
          Text('You need this PIN to leave front desk mode.', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
      FilledButton(key: const Key('front_desk_start'), onPressed: _save, child: const Text('Start front desk mode')),
    ],
  );
}

class _TurnOffDialog extends StatefulWidget {
  final Future<void> Function() onForgot;
  const _TurnOffDialog({required this.onForgot});
  @override
  State<_TurnOffDialog> createState() => _TurnOffDialogState();
}

class _TurnOffDialogState extends State<_TurnOffDialog> {
  final _pin = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final fd = FrontDesk.instance;
    if (await fd.turnOff(_pin.text)) {
      if (mounted) Navigator.pop(context, true);
      return;
    }
    final wait = fd.lockedFor;
    setState(() {
      _pin.clear();
      _error = wait == null ? 'Wrong PIN.' : 'Too many tries. Wait ${wait.inSeconds + 1} seconds.';
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('front_desk_off_dialog'),
    title: const Text('Leave front desk mode'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pinField(_pin, 'PIN', key: const Key('front_desk_exit_pin'), autofocus: true, error: _error, onSubmitted: (_) => _check()),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('front_desk_forgot'),
          style: TextButton.styleFrom(padding: EdgeInsets.zero),
          onPressed: () async {
            final nav = Navigator.of(context);
            final sure = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Forgot the PIN?'),
                content: const Text(
                  'SOLIS signs out on this phone. Signing back in with the clinician\'s password ends front desk mode. Patients stay on the phone.',
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign out')),
                ],
              ),
            );
            if (sure != true) return;
            nav.pop(false);
            await widget.onForgot();
          },
          child: const Text('Forgot the PIN?'),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
      FilledButton(key: const Key('front_desk_exit'), onPressed: _check, child: const Text('Leave')),
    ],
  );
}

/// Shown at the top of the app while front desk mode is on.
class FrontDeskStrip extends StatelessWidget {
  final VoidCallback onExit;
  const FrontDeskStrip({super.key, required this.onExit});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      key: const Key('front_desk_strip'),
      color: cs.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            Icon(Icons.badge_outlined, size: 20, color: cs.onTertiaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Front desk mode: cards and patient details only', style: TextStyle(color: cs.onTertiaryContainer)),
            ),
            TextButton(key: const Key('front_desk_leave'), onPressed: onExit, child: const Text('Leave')),
          ],
        ),
      ),
    );
  }
}
