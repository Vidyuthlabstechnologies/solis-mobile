import 'package:flutter/material.dart';

import '../services/account_repository.dart';
import '../services/app_session.dart';
import '../services/auth_service.dart';
import '../models/provider_profile.dart' show isValidNpi;
import '../widgets/medical_disclaimer.dart';

/// Creates a SOLIS account for one clinician: name, practice email, password
/// and, optionally, the individual NPI.
class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _npi = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _npi.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService.instance.register(
        fullName: _name.text,
        email: _email.text,
        password: _password.text,
        npi: _npi.text,
      );
      // New clinicians set up their practice (prefilled from the NPI) before
      // they can see patients or send a claim.
      final route = await AppSession.start(AuthService.instance, AccountRepository.instance);
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil(route, (_) => false);
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

    return Scaffold(
      appBar: AppBar(title: const Text('Create your account')),
      body: SafeArea(
        top: false,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'One account per clinician. Use the email of your practice.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(height: 20),
                      TextFormField(
                        key: const Key('signup_name'),
                        controller: _name,
                        textCapitalization: TextCapitalization.words,
                        autofillHints: const [AutofillHints.name],
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(labelText: 'Full name', prefixIcon: Icon(Icons.person_outline)),
                        validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your full name' : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const Key('signup_email'),
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                        autofillHints: const [AutofillHints.email],
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(labelText: 'Practice email', prefixIcon: Icon(Icons.alternate_email_rounded)),
                        validator: (v) => RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch((v ?? '').trim()) ? null : 'Enter a valid email',
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const Key('signup_password'),
                        controller: _password,
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.newPassword],
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          helperText: 'At least ${AuthService.minPasswordLength} characters. A short phrase works well.',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _obscure ? 'Show password' : 'Hide password',
                            icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (v) => (v ?? '').length < AuthService.minPasswordLength
                            ? 'Use at least ${AuthService.minPasswordLength} characters'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const Key('signup_npi'),
                        controller: _npi,
                        keyboardType: TextInputType.number,
                        maxLength: 10,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _submit(),
                        decoration: const InputDecoration(
                          labelText: 'Individual NPI (optional)',
                          counterText: '',
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                        validator: (v) {
                          final t = (v ?? '').trim();
                          return t.isEmpty || isValidNpi(t) ? null : 'Enter a valid 10-digit NPI or leave it empty';
                        },
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.error_outline, size: 20, color: cs.error),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(_error!, key: const Key('signup_error'), style: theme.textTheme.bodyMedium?.copyWith(color: cs.error)),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 20),
                      SizedBox(
                        height: 48,
                        child: FilledButton.icon(
                          key: const Key('signup_submit'),
                          onPressed: _busy ? null : _submit,
                          icon: _busy
                              ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: cs.onSurfaceVariant))
                              : const Icon(Icons.how_to_reg_outlined),
                          label: const Text('Create account'),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const MedicalDisclaimer(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
