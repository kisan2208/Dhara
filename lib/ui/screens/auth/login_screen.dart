import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/haptics.dart';
import '../../../core/utils/validators.dart';
import '../../../state/auth_controller.dart';
import '../../router.dart';
import '../../widgets/common.dart';

/// Returning users sign in with email and password.
///
/// Note there is no OTP step here by design: Appwrite leaves
/// `emailVerification` false after a token session, so gating this screen on
/// that flag would loop a returning user through OTP forever.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _obscure = true;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_form.currentState?.validate() ?? false)) {
      Haptics.warn();
      return;
    }

    Haptics.press();
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);

    try {
      await ref.read(authControllerProvider.notifier).signIn(
            email: _email.text,
            password: _password.text,
          );
      // The router moves to the dashboard once auth state flips.
      Haptics.success();
    } on AuthFailure catch (e) {
      Haptics.error();
      if (mounted) showSnack(context, e.message, isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgotPassword() async {
    final email = _email.text.trim();
    if (Validate.email(email) != null) {
      Haptics.warn();
      showSnack(
        context,
        'Enter your email first, then tap reset.',
        isError: true,
      );
      return;
    }

    Haptics.tap();
    try {
      await ref.read(authControllerProvider.notifier).sendPasswordReset(email);
      if (mounted) {
        showSnack(context, 'Reset link sent. Check your email.');
      }
    } on AuthFailure catch (e) {
      Haptics.error();
      if (mounted) showSnack(context, e.message, isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () {
            Haptics.tap();
            if (context.canPop()) {
              context.pop();
            } else {
              context.go(Routes.welcome);
            }
          },
        ),
      ),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            children: [
              const BrandLogo(size: 120)
                  .animate()
                  .scale(duration: 450.ms, curve: Curves.easeOutBack)
                  .fadeIn(),
              const SizedBox(height: 24),

              Text('Welcome back', style: text.headlineMedium)
                  .animate(delay: 80.ms)
                  .fadeIn()
                  .slideY(begin: 0.25, end: 0),
              const SizedBox(height: 8),
              Text(
                'Sign in to pick up where you left off.',
                style: text.bodyMedium?.copyWith(color: AppColors.inkSoft),
              ).animate(delay: 150.ms).fadeIn(),
              const SizedBox(height: 30),

              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                inputFormatters: [
                  FilteringTextInputFormatter.deny(RegExp(r'\s')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.alternate_email_rounded),
                ),
                validator: Validate.email,
              ).animate(delay: 220.ms).fadeIn().slideY(begin: 0.2, end: 0),
              const SizedBox(height: 16),

              TextFormField(
                controller: _password,
                obscureText: _obscure,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.password],
                onFieldSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () {
                      Haptics.tap();
                      setState(() => _obscure = !_obscure);
                    },
                  ),
                ),
                validator: Validate.loginPassword,
              ).animate(delay: 300.ms).fadeIn().slideY(begin: 0.2, end: 0),
              const SizedBox(height: 6),

              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _busy ? null : _forgotPassword,
                  child: const Text('Forgot password?'),
                ),
              ).animate(delay: 350.ms).fadeIn(),
              const SizedBox(height: 18),

              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Sign in'),
              ).animate(delay: 400.ms).fadeIn().slideY(begin: 0.3, end: 0),
              const SizedBox(height: 14),

              Center(
                child: TextButton(
                  onPressed: _busy
                      ? null
                      : () {
                          Haptics.tap();
                          context.go(Routes.signup);
                        },
                  child: const Text('New here? Create an account'),
                ),
              ).animate(delay: 470.ms).fadeIn(),
            ],
          ),
        ),
      ),
    );
  }
}
