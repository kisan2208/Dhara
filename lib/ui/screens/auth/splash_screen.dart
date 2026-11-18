import 'package:flutter/material.dart';
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
    return LightStatusBar(
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: AppColors.heroGradient,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const BrandLogo(size: 96),
                )
                    .animate()
                    .scale(
                      duration: 600.ms,
                      curve: Curves.easeOutBack,
                      begin: const Offset(0.7, 0.7),
                    )
                    .fadeIn(duration: 400.ms),
                const SizedBox(height: 28),
                Text(
                  'Dhara',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                ).animate(delay: 200.ms).fadeIn().slideY(begin: 0.4, end: 0),
                const SizedBox(height: 6),
                Text(
                  'Green Credits',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AppColors.limeSoft,
                        letterSpacing: 3,
                      ),
                ).animate(delay: 340.ms).fadeIn(),
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
                      color: Colors.white70,
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
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'You are still signed in. Check your connection and try again.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Try again'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white54),
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
