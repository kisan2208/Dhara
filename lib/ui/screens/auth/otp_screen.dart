import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/haptics.dart';
import '../../../state/auth_controller.dart';
import '../../widgets/common.dart';
import '../../widgets/otp_field.dart';

/// Step two of signup: confirm the emailed 6-digit code.
///
/// While the auth state is [AuthAwaitingOtp] the router pins the app to this
/// screen, so leaving requires [AuthController.abandonOtp] rather than a pop.
class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key});

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final _code = TextEditingController();

  Timer? _cooldown;
  int _secondsLeft = 0;
  bool _busy = false;
  bool _resending = false;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    // A code was just sent, so start the resend cooldown immediately.
    _startCooldown();
  }

  @override
  void dispose() {
    _cooldown?.cancel();
    _code.dispose();
    super.dispose();
  }

  void _startCooldown([int seconds = 45]) {
    _cooldown?.cancel();
    setState(() => _secondsLeft = seconds);
    _cooldown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _secondsLeft -= 1);
      if (_secondsLeft <= 0) timer.cancel();
    });
  }

  Future<void> _verify(String code) async {
    if (_busy) return;
    if (code.length != 6) {
      setState(() => _hasError = true);
      Haptics.warn();
      return;
    }

    setState(() {
      _busy = true;
      _hasError = false;
    });

    try {
      await ref.read(authControllerProvider.notifier).verifyOtp(code);
      // Success flips auth state to AuthSignedIn and the router leaves.
      Haptics.celebrate();
    } on AuthFailure catch (e) {
      Haptics.error();
      if (!mounted) return;
      setState(() => _hasError = true);
      _code.clear();
      showSnack(context, e.message, isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    if (_secondsLeft > 0 || _busy || _resending) return;
    // Set before the request, so a double tap cannot send two emails.
    _resending = true;
    Haptics.tap();
    try {
      await ref.read(authControllerProvider.notifier).resendOtp();
      if (!mounted) return;
      _startCooldown();
      showSnack(context, 'A new code is on its way.');
    } on AuthFailure catch (e) {
      Haptics.error();
      if (mounted) showSnack(context, e.message, isError: true);
    } finally {
      _resending = false;
    }
  }

  void _changeEmail() {
    Haptics.tap();
    // Returns to the signed-out branch; the router then shows the welcome flow.
    ref.read(authControllerProvider.notifier).abandonOtp();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final pending = ref.watch(authControllerProvider).value;
    final email = pending is AuthAwaitingOtp ? pending.email : '';

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: _busy ? null : _changeEmail,
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          children: [
            Container(
              width: 66,
              height: 66,
              decoration: BoxDecoration(
                color: AppColors.surfaceMuted,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Center(
                child: Text('\u{1F4E8}', style: TextStyle(fontSize: 30)),
              ),
            )
                .animate()
                .scale(duration: 450.ms, curve: Curves.easeOutBack)
                .fadeIn(),
            const SizedBox(height: 22),

            Text('Check your email', style: text.headlineMedium)
                .animate(delay: 80.ms)
                .fadeIn()
                .slideY(begin: 0.25, end: 0),
            const SizedBox(height: 8),

            Text.rich(
              TextSpan(
                style: text.bodyMedium?.copyWith(color: AppColors.inkSoft),
                children: [
                  const TextSpan(text: 'We sent a 6-digit code to '),
                  TextSpan(
                    text: email,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.forest,
                    ),
                  ),
                ],
              ),
            ).animate(delay: 150.ms).fadeIn(),
            const SizedBox(height: 34),

            OtpField(
              controller: _code,
              hasError: _hasError,
              onCompleted: _verify,
            ).animate(delay: 220.ms).fadeIn().slideY(begin: 0.2, end: 0),
            const SizedBox(height: 30),

            FilledButton(
              onPressed: _busy ? null : () => _verify(_code.text),
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Confirm'),
            ).animate(delay: 300.ms).fadeIn().slideY(begin: 0.3, end: 0),
            const SizedBox(height: 12),

            Center(
              child: _secondsLeft > 0
                  ? Text(
                      'Resend code in ${_secondsLeft}s',
                      style: text.bodySmall?.copyWith(color: AppColors.inkFaint),
                    )
                  : TextButton(
                      onPressed: _busy ? null : _resend,
                      child: const Text('Send a new code'),
                    ),
            ).animate(delay: 360.ms).fadeIn(),

            Center(
              child: TextButton(
                onPressed: _busy ? null : _changeEmail,
                child: Text(
                  'Use a different email',
                  style: TextStyle(color: AppColors.inkSoft),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
