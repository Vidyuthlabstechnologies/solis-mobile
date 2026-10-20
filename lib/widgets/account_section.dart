import 'package:flutter/material.dart';

import '../services/account_repository.dart';
import '../services/auth_service.dart';
import 'medical_disclaimer.dart';

/// Who is signed in, sign out, delete account and About. Shown at the end of
/// the provider profile.
class AccountSection extends StatelessWidget {
  final AuthService? auth;
  const AccountSection({super.key, this.auth});

  AuthService get _auth => auth ?? AuthService.instance;

  Future<void> _signOut(BuildContext context) async {
    final nav = Navigator.of(context);
    await _auth.signOut();
    nav.pushNamedAndRemoveUntil('/login', (_) => false);
  }

  Future<void> _delete(BuildContext context) async {
    final nav = Navigator.of(context);
    final deleted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DeleteAccountDialog(auth: _auth),
    );
    if (deleted != true) return;
    // The server account is gone; patient data kept on this phone goes too.
    await AccountRepository.instance.eraseAll();
    nav.pushNamedAndRemoveUntil('/login', (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ListenableBuilder(
      listenable: _auth,
      builder: (context, _) {
        final user = _auth.user;
        final demo = _auth.isDemo;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('Account', style: theme.textTheme.titleSmall?.copyWith(color: cs.primary)),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(demo ? Icons.play_circle_outline : Icons.account_circle_outlined),
              title: Text(demo ? 'Demo account' : (user?.fullName.isNotEmpty ?? false) ? user!.fullName : 'Signed in'),
              subtitle: Text(demo ? 'Stays on this phone. No SOLIS account.' : user?.email ?? ''),
            ),
            ListTile(
              key: const Key('account_sign_out'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.logout_rounded),
              title: const Text('Sign out'),
              onTap: () => _signOut(context),
            ),
            ListTile(
              key: const Key('account_delete'),
              contentPadding: EdgeInsets.zero,
              enabled: _auth.hasAccount,
              leading: Icon(Icons.delete_forever_outlined, color: _auth.hasAccount ? cs.error : null),
              title: Text('Delete account', style: TextStyle(color: _auth.hasAccount ? cs.error : null)),
              subtitle: Text(_auth.hasAccount ? 'Removes your SOLIS account and the data on this phone.' : 'Available when signed in with a SOLIS account.'),
              onTap: _auth.hasAccount ? () => _delete(context) : null,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.info_outline),
              title: const Text('About SOLIS'),
              subtitle: const Text('Version $solisVersion'),
              onTap: () => showSolisAbout(context),
            ),
          ],
        );
      },
    );
  }
}

/// Asks for the password and deletes the account on the server. Pops true
/// once the server confirmed the deletion.
class DeleteAccountDialog extends StatefulWidget {
  final AuthService auth;
  const DeleteAccountDialog({super.key, required this.auth});

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_busy) return;
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter your password');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth.deleteAccount(_password.text);
      if (mounted) Navigator.of(context).pop(true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return AlertDialog(
      icon: Icon(Icons.delete_forever_outlined, color: cs.error, size: 32),
      title: const Text('Delete your SOLIS account?', textAlign: TextAlign.center),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'This cannot be undone. Your account and sign-in are deleted on the SOLIS server, and the patients, '
              'visits, notes and provider profile stored on this phone are erased. Claims already sent to a payer are not recalled.',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('delete_password'),
              controller: _password,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.password],
              onSubmitted: (_) => _confirm(),
              decoration: InputDecoration(
                labelText: 'Password',
                errorText: _error,
                errorMaxLines: 3,
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          key: const Key('delete_confirm'),
          style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
          onPressed: _busy ? null : _confirm,
          child: _busy
              ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: cs.onError))
              : const Text('Delete account'),
        ),
      ],
    );
  }
}
