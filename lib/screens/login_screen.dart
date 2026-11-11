import 'package:flutter/material.dart';

import '../widgets/legal_links.dart';
import '../services/account_repository.dart';
import '../services/app_session.dart';
import '../services/auth_service.dart';
import '../widgets/medical_disclaimer.dart';
import '../widgets/solis_brand.dart';

class LoginScreen extends StatefulWidget {
  final ValueChanged<bool>? onThemeToggle;
  final bool isDark;

  const LoginScreen({
    super.key,
    this.onThemeToggle,
    this.isDark = false,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _error;

  AuthService get _auth => AuthService.instance;

  /// Local demo mode: no server account, works offline. For store review and trials.
  Future<void> _useDemo() async {
    setState(() => _error = null);
    await _auth.startDemo();
    final route = await AppSession.start(_auth, AccountRepository.instance);
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, route);
  }

  Future<void> _handleLogin() async {
    if (_isLoading) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await _auth.login(email: _emailController.text, password: _passController.text);
      // A real account never sees demo data; an incomplete practice profile
      // goes to setup first.
      final route = await AppSession.start(_auth, AccountRepository.instance);
      if (!mounted) return;
      _passController.clear();
      Navigator.pushReplacementNamed(context, route);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        actions: [
          if (widget.onThemeToggle != null)
            IconButton(
              tooltip: widget.isDark ? 'Use light theme' : 'Use dark theme',
              icon: Icon(widget.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
              onPressed: () => widget.onThemeToggle!(!widget.isDark),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SolisBrandMark(size: 56),
                      const SizedBox(height: 20),
                      Text(
                        'SOLIS',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Ambient clinical documentation',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(height: 32),
                      TextFormField(
                        key: const Key('login_email'),
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                        autofillHints: const [AutofillHints.username, AutofillHints.email],
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Practice email',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                        validator: (v) => (v == null || !v.contains('@')) ? 'Enter your practice email' : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const Key('login_password'),
                        controller: _passController,
                        obscureText: _obscurePassword,
                        autofillHints: const [AutofillHints.password],
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _handleLogin(),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                            icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                        validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.error_outline, size: 20, color: cs.error),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                key: const Key('login_error'),
                                style: theme.textTheme.bodyMedium?.copyWith(color: cs.error),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 20),
                      SizedBox(
                        height: 48,
                        child: FilledButton.icon(
                          key: const Key('login_submit'),
                          onPressed: _isLoading ? null : _handleLogin,
                          icon: _isLoading
                              ? SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: cs.onSurfaceVariant),
                                )
                              : const Icon(Icons.login_rounded),
                          label: const Text('Sign in'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(
                            child: TextButton.icon(
                              key: const Key('login_demo'),
                              onPressed: _isLoading ? null : _useDemo,
                              icon: const Icon(Icons.play_circle_outline),
                              label: const Text('Use demo account', overflow: TextOverflow.ellipsis),
                            ),
                          ),
                          Flexible(
                            child: TextButton.icon(
                              key: const Key('login_request_access'),
                              onPressed: _isLoading ? null : () => Navigator.pushNamed(context, '/signup'),
                              icon: const Icon(Icons.person_add_alt_outlined),
                              label: const Text('Request access', overflow: TextOverflow.ellipsis),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      const MedicalDisclaimer(),
                      const SizedBox(height: 4),
                      const LegalLinks(),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Icon(Icons.shield_outlined, size: 16, color: cs.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Encrypted on device. The demo account stays on this phone.',
                              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
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
