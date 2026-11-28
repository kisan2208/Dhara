import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../state/auth_controller.dart';
import '../../widgets/common.dart';

/// Shown while the persisted Appwrite session is being restored.
///
/// The router parks every route here until auth resolves, so this is the first
/// frame the user sees on a cold start. If the restore fails because the server
/// could not be reached, this is also where the user retries.
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        body: Container(
          color: Colors.white,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const BrandLogo(size: 280)
                    .animate()
                    .scale(
                      duration: 600.ms,
                      curve: Curves.easeOutBack,
                      begin: const Offset(0.8, 0.8),
                    )
                    .fadeIn(duration: 400.ms),
                const SizedBox(height: 46),
                if (auth.hasError && !auth.isLoading)
                  _RestoreFailed(
                    message: friendlyMessage(auth.error),
                    onRetry: () => ref.invalidate(authControllerProvider),
                  )
                else
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: AppColors.green,
                    ),
                  ).animate(delay: 700.ms).fadeIn(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when the saved session could not be checked, almost always because
/// the phone is offline. The session is kept, so Retry is all it takes.
class _RestoreFailed extends StatelessWidget {
  const _RestoreFailed({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.forestInk,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'You are still signed in. Check your connection and try again.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black54, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Try again'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.green,
              side: const BorderSide(color: AppColors.green),
              // The app theme gives outlined buttons an infinite minimum width;
              // inside this centred column that would fail layout.
              minimumSize: const Size(160, 46),
            ),
          ),
        ],
      ),
    );
  }
}
