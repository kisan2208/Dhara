import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/haptics.dart';
import '../../../data/models/tree.dart';
import '../../../state/auth_controller.dart';
import '../../../state/trees_controller.dart';
import '../../widgets/common.dart';
import '../home/dashboard_shell.dart';
import 'plant_tree_screen.dart';
import 'tree_detail_screen.dart';
import 'verify_tree_screen.dart';

/// Colour and icon per tree status, shared by the list and detail screens.
({Color color, IconData icon}) treeStatusStyle(TreeStatus status) =>
    switch (status) {
      TreeStatus.alive => (color: AppColors.green, icon: Icons.eco_rounded),
      TreeStatus.atRisk => (
          color: AppColors.amber,
          icon: Icons.notifications_active_rounded,
        ),
      TreeStatus.missed => (
          color: AppColors.danger,
          icon: Icons.error_outline_rounded,
        ),
      TreeStatus.pendingReview => (
          color: AppColors.info,
          icon: Icons.hourglass_bottom_rounded,
        ),
      TreeStatus.dead => (
          color: AppColors.inkFaint,
          icon: Icons.close_rounded,
        ),
      TreeStatus.rejected => (
          color: AppColors.danger,
          icon: Icons.block_rounded,
        ),
    };

class TreesScreen extends ConsumerWidget {
  const TreesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trees = ref.watch(treesControllerProvider);
    final profile = ref.watch(currentProfileProvider);

    // Gates the "plant another" button below. Reads null while the first load is
    // in flight or if it failed, which is right — there is nothing to add *to*
    // yet. On a refresh it still holds the previous list, so the button does not
    // blink out mid pull-to-refresh.
    final hasTrees = trees.value?.isNotEmpty ?? false;

    return LightStatusBar(
      child: Scaffold(
        backgroundColor: AppColors.canvas,
        // Only once there is a tree to add to. The empty state below already
        // offers "Plant a tree" as its own centred button, and two identical
        // buttons on one screen leaves the user picking between them for no
        // reason.
        //
        // The padding lifts it clear of the shell's floating nav bar. This
        // Scaffold has no bottomNavigationBar of its own, so it measures from
        // the screen edge and would otherwise park the button underneath the
        // bar, completely covered and untappable.
        floatingActionButton: !hasTrees
            ? null
            : Padding(
                padding: EdgeInsets.only(bottom: dashboardBottomInset(context)),
                child: FloatingActionButton.extended(
                  onPressed: () {
                    Haptics.press();
                    PlantTreeScreen.push(context);
                  },
                  backgroundColor: AppColors.green,
                  foregroundColor: Colors.white,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text(
                    'Plant another tree',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ).animate(delay: 250.ms).scale(curve: Curves.easeOutBack).fadeIn(),
        body: RefreshIndicator(
          onRefresh: () =>
              ref.read(treesControllerProvider.notifier).refresh(),
          color: AppColors.green,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: GradientHeader(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'My trees',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Check in every month to keep earning.',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (profile != null) ...[
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            _HeaderStat(
                              label: 'Planted',
                              value: profile.treesPlanted,
                            ),
                            _HeaderStat(
                              label: 'Alive',
                              value: profile.treesAlive,
                            ),
                            _HeaderStat(
                              label: 'Vesting',
                              value: profile.creditsPending,
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ).animate().fadeIn(duration: 320.ms),
              ),

              ...switch (trees) {
                AsyncError(:final error) => [
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: ErrorRetry(
                        message: friendlyMessage(error),
                        onRetry: () => ref.invalidate(treesControllerProvider),
                      ),
                    ),
                  ],
                AsyncLoading() => const [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.only(top: 20),
                        child: LoadingList(count: 3, height: 104),
                      ),
                    ),
                  ],
                AsyncValue(:final value) => _list(context, value ?? const []),
              },

              // Clears the nav bar, plus the button floating above it when there
              // is one. Without the extra the last card scrolls to a stop under
              // the FAB, and on a tree that is due for a check-in that is
              // exactly where its "Check in now" button sits.
              SliverToBoxAdapter(
                child: SizedBox(
                  height: dashboardBottomInset(context) + (hasTrees ? 76 : 24),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _list(BuildContext context, List<Tree> trees) {
    if (trees.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            emoji: '\u{1F331}',
            title: 'No trees yet',
            message:
                'Plant your first tree, stand next to it, and take a photo. '
                'Credits build up each month it survives.',
            actionLabel: 'Plant a tree',
            onAction: () => PlantTreeScreen.push(context),
          ),
        ),
      ];
    }

    // Anything needing action first; the rest keep newest-first order.
    final sorted = [...trees]..sort((a, b) {
      if (a.isVerifiable != b.isVerifiable) return a.isVerifiable ? -1 : 1;
      return b.plantedAt.compareTo(a.plantedAt);
    });

    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        sliver: SliverList.separated(
          itemCount: sorted.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, i) => _TreeCard(tree: sorted[i])
              .animate(delay: (55 * i).ms)
              .fadeIn()
              .slideY(begin: 0.12, end: 0),
        ),
      ),
    ];
  }
}

class _HeaderStat extends StatelessWidget {
  const _HeaderStat({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedCounter(
            value: value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w900,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _TreeCard extends StatelessWidget {
  const _TreeCard({required this.tree});

  final Tree tree;

  @override
  Widget build(BuildContext context) {
    final style = treeStatusStyle(tree.status);
    final due = tree.isVerifiable;

    return DharaCard(
      onTap: () => TreeDetailScreen.push(context, tree.id),
      padding: const EdgeInsets.all(15),
      child: Column(
        children: [
          Row(
            children: [
              ProgressRing(
                progress: tree.vestingProgress,
                size: 52,
                thickness: 5,
                color: style.color,
                child: const Text('\u{1F333}', style: TextStyle(fontSize: 20)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tree.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.forest,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${tree.verificationCount} of ${tree.vestingMonths} '
                      'check-ins done',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.inkSoft,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusPill(
                label: tree.status.label,
                color: style.color,
                icon: style.icon,
                compact: true,
              ),
            ],
          ),
          if (due) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  Haptics.press();
                  VerifyTreeScreen.push(context, tree);
                },
                icon: const Icon(Icons.camera_alt_rounded, size: 17),
                label: Text(
                  tree.isLate
                      ? 'Check in now \u00B7 late'
                      : tree.untilWindowCloses == null
                          ? 'Check in now'
                          : 'Check in \u00B7 ${_closesIn(tree.untilWindowCloses!)} left',
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: style.color,
                  minimumSize: const Size.fromHeight(44),
                ),
              ),
            ),
          ] else if (tree.untilVerifyOpens case final wait?) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(
                  Icons.schedule_rounded,
                  size: 14,
                  color: AppColors.inkFaint,
                ),
                const SizedBox(width: 6),
                Text(
                  'Next check-in ${_opensIn(wait)}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.inkFaint,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

String _closesIn(Duration d) {
  if (d.inDays >= 1) return '${d.inDays}d';
  if (d.inHours >= 1) return '${d.inHours}h';
  return '${d.inMinutes}m';
}

String _opensIn(Duration d) {
  if (d.inDays >= 2) return 'in ${d.inDays} days';
  if (d.inDays == 1) return 'tomorrow';
  if (d.inHours >= 1) return 'in ${d.inHours} hours';
  return 'shortly';
}
