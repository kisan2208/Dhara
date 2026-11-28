import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/haptics.dart';
import '../../router.dart';
import '../../widgets/common.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  static const _points = [
    ('\u{1F331}', 'Plant a tree', 'Check in monthly from where it grows'),
    ('\u{267B}', 'Return packaging', 'Scan a bottle back into the loop'),
    ('\u{1F4A1}', 'Spend credits', 'Electricity bills, vouchers and more'),
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return LightStatusBar(
      child: Scaffold(
        body: Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: AppColors.heroGradient,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  const BrandLogo(size: 200)
                      .animate()
                      .scale(
                        duration: 550.ms,
                        curve: Curves.easeOutBack,
                        begin: const Offset(0.75, 0.75),
                      )
                      .fadeIn(),
                  const SizedBox(height: 26),
                  Text(
                    'Grow something that\npays you back',
                    textAlign: TextAlign.center,
                    style: text.headlineMedium?.copyWith(
                      color: Colors.white,
                      height: 1.2,
                    ),
                  ).animate(delay: 150.ms).fadeIn().slideY(begin: 0.3, end: 0),
                  const SizedBox(height: 12),
                  Text(
                    'Earn green credits for caring for trees\nand keeping packaging out of landfill.',
                    textAlign: TextAlign.center,
                    style: text.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.82),
                    ),
                  ).animate(delay: 260.ms).fadeIn(),
                  const Spacer(),
                  ..._points.indexed.map((entry) {
                    final (i, (emoji, title, subtitle)) = entry;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _Point(
                        emoji: emoji,
                        title: title,
                        subtitle: subtitle,
                      ),
                    )
                        .animate(delay: (360 + i * 110).ms)
                        .fadeIn()
                        .slideX(begin: 0.15, end: 0);
                  }),
                  const Spacer(flex: 2),
                  FilledButton(
                    onPressed: () {
                      Haptics.press();
                      context.push(Routes.signup);
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.lime,
                      foregroundColor: AppColors.forestInk,
                    ),
                    child: const Text('Create my account'),
                  ).animate(delay: 700.ms).fadeIn().slideY(begin: 0.4, end: 0),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () {
                      Haptics.tap();
                      context.push(Routes.login);
                    },
                    child: Text(
                      'I already have an account',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                  ).animate(delay: 800.ms).fadeIn(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({
    required this.emoji,
    required this.title,
    required this.subtitle,
  });

  final String emoji;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Center(child: Text(emoji, style: const TextStyle(fontSize: 21))),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.75),
                    ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
