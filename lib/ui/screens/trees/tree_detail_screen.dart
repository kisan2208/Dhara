import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/config/env.dart';
import '../../../core/services/media.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/growth.dart';
import '../../../core/utils/haptics.dart';
import '../../../data/models/tree.dart';
import '../../../state/trees_controller.dart';
import '../../widgets/common.dart';
import '../../widgets/tree_care_widgets.dart';
import 'trees_screen.dart';
import 'verify_tree_screen.dart';

/// One tree: its vesting progress, where it is, and every check-in so far.
class TreeDetailScreen extends ConsumerWidget {
  const TreeDetailScreen({super.key, required this.treeId});

  final String treeId;

  static Future<void> push(BuildContext context, String treeId) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => TreeDetailScreen(treeId: treeId)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tree = ref.watch(treeByIdProvider(treeId));
    final loading = ref.watch(treesControllerProvider).isLoading;

    if (tree == null) {
      return Scaffold(
        backgroundColor: AppColors.canvas,
        appBar: AppBar(title: const Text('Tree')),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : const EmptyState(
                emoji: '\u{1F50D}',
                title: 'Tree not found',
                message: 'This tree is no longer in your list.',
              ),
      );
    }

    final style = treeStatusStyle(tree.status);
    final verifications = ref.watch(treeVerificationsProvider(treeId));

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(treeVerificationsProvider(treeId));
          await ref.read(treesControllerProvider.notifier).refresh();
        },
        color: AppColors.green,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              expandedHeight: 250,
              backgroundColor: AppColors.forest,
              foregroundColor: Colors.white,
              flexibleSpace: FlexibleSpaceBar(
                title: Text(
                  tree.displayName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                background: _PlantPhoto(fileId: tree.plantPhotoFileId),
              ),
            ),

            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        StatusPill(
                          label: tree.status.label,
                          color: style.color,
                          icon: style.icon,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          tree.speciesName,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.inkSoft,
                          ),
                        ),
                      ],
                    ).animate().fadeIn(),

                    if (tree.rejectReason case final reason?
                        when reason.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      _NoteBox(text: reason, tint: AppColors.danger),
                    ],

                    const SizedBox(height: 18),
                    _VestingCard(tree: tree),

                    const SizedBox(height: 14),
                    _FactsCard(tree: tree),

                    TreeCareCard(tree: tree),

                    if (verifications.value case final rows?)
                      GrowthCard(points: growthPoints(rows)),

                    if (tree.isVerifiable) ...[
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () {
                            Haptics.press();
                            VerifyTreeScreen.push(context, tree);
                          },
                          icon: const Icon(Icons.camera_alt_rounded, size: 18),
                          label: Text(
                            tree.isLate ? 'Check in now \u00B7 late' : 'Check in now',
                          ),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            const SliverToBoxAdapter(
              child: SectionHeader(title: 'Check-in history'),
            ),

            ...switch (verifications) {
              AsyncError(:final error) => [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: ErrorRetry(
                        message: friendlyMessage(error),
                        onRetry: () =>
                            ref.invalidate(treeVerificationsProvider(treeId)),
                      ),
                    ),
                  ),
                ],
              AsyncLoading() => const [
                  SliverToBoxAdapter(child: LoadingList(count: 2, height: 72)),
                ],
              AsyncValue(:final value) => _history(value ?? const []),
            },

            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }

  List<Widget> _history(List<TreeVerification> rows) {
    if (rows.isEmpty) {
      return [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: DharaCard(
              child: Text(
                'No check-ins yet. The first one is due a month after planting.',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  fontWeight: FontWeight.w500,
                  color: AppColors.inkSoft,
                ),
              ),
            ),
          ),
        ),
      ];
    }

    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverList.separated(
          itemCount: rows.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, i) => _VerificationRow(row: rows[i])
              .animate(delay: (45 * i).ms)
              .fadeIn()
              .slideY(begin: 0.1, end: 0),
        ),
      ),
    ];
  }
}

class _PlantPhoto extends ConsumerWidget {
  const _PlantPhoto({required this.fileId});

  final String? fileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = fileId;

    final fallback = Container(
      color: AppColors.forest,
      child: const Center(
        child: Text('\u{1F333}', style: TextStyle(fontSize: 62)),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        if (id == null || id.isEmpty)
          fallback
        else
          ref.watch(photoBytesProvider('${Buckets.treePhotos}/$id')).when(
                loading: () => Container(color: AppColors.forestDeep),
                error: (_, _) => fallback,
                data: (bytes) => Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
        // Keeps the app bar title readable over a bright photo.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black54, Colors.transparent, Colors.black87],
              stops: [0, 0.45, 1],
            ),
          ),
          child: SizedBox.expand(),
        ),
      ],
    );
  }
}

class _VestingCard extends StatelessWidget {
  const _VestingCard({required this.tree});

  final Tree tree;

  @override
  Widget build(BuildContext context) {
    final remaining = tree.vestingMonths - tree.verificationCount;

    return DharaCard(
      gradient: AppColors.treeGradient,
      child: Row(
        children: [
          ProgressRing(
            progress: tree.vestingProgress,
            size: 74,
            thickness: 7,
            color: AppColors.lime,
            track: Colors.white.withValues(alpha: 0.22),
            child: Text(
              '${tree.verificationCount}/${tree.vestingMonths}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tree.isFullyVested ? 'Fully vested' : 'Vesting',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  tree.isFullyVested
                      ? 'Every credit this tree earned is yours to spend.'
                      : '$remaining more monthly check-in'
                          '${remaining == 1 ? '' : 's'} to unlock the rest.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 12,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _Chip(label: 'Vested', value: tree.creditsVested),
                    const SizedBox(width: 8),
                    _Chip(label: 'Pending', value: tree.creditsPending),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ).animate(delay: 80.ms).fadeIn().slideY(begin: 0.12, end: 0);
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label $value',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _FactsCard extends StatelessWidget {
  const _FactsCard({required this.tree});

  final Tree tree;

  @override
  Widget build(BuildContext context) {
    final format = DateFormat('d MMM yyyy');

    final rows = <(IconData, String, String)>[
      (
        Icons.event_available_rounded,
        'Planted',
        '${format.format(tree.plantedAt)} \u00B7 ${tree.ageInDays} days ago',
      ),
      if (tree.heightCm > 0)
        (Icons.straighten_rounded, 'Height', '${tree.heightCm} cm'),
      if (tree.lastVerifiedAt case final last?)
        (
          Icons.check_circle_outline_rounded,
          'Last check-in',
          format.format(last),
        ),
      if (!tree.isVerifiable && tree.nextVerifyAfter != null)
        (
          Icons.schedule_rounded,
          'Next check-in',
          format.format(tree.nextVerifyAfter!),
        ),
      if (tree.addressLabel case final address? when address.isNotEmpty)
        (Icons.place_outlined, 'Location', address),
      // The GPS reading this tree was registered with. Shown because it is the
      // evidence behind the registration, and every monthly check-in is measured
      // against it — a user who cannot see it cannot question it.
      (
        Icons.my_location_rounded,
        'Coordinates',
        '${Fmt.latDms(tree.lat)}\n${Fmt.lngDms(tree.lng)}',
      ),
      if (tree.accuracyM > 0)
        (
          Icons.gps_fixed_rounded,
          'Accuracy',
          '\u00B1${tree.accuracyM.toStringAsFixed(1)} m',
        ),
      if (tree.hasAltitude)
        (
          Icons.terrain_rounded,
          'Altitude',
          '${tree.altitudeM.toStringAsFixed(1)} m',
        ),
      // The device's clock at the moment of the fix, which is not the same thing
      // as `plantedAt` above — that one is the server's time and is the
      // authority. Only shown when it adds something: the two agreeing to the
      // minute is the normal case and needs no row of its own.
      if (tree.fixCapturedAt case final captured?
          when captured.difference(tree.plantedAt).abs().inMinutes > 2)
        (Icons.schedule_rounded, 'GPS clock', Fmt.stamp(captured)),
      if (tree.consecutiveMisses > 0)
        (
          Icons.warning_amber_rounded,
          'Missed',
          '${tree.consecutiveMisses} in a row',
        ),
    ];

    return DharaCard(
      child: Column(
        children: rows.asMap().entries.map((e) {
          final (icon, label, value) = e.value;
          return Padding(
            padding: EdgeInsets.only(bottom: e.key == rows.length - 1 ? 0 : 13),
            child: Row(
              children: [
                Icon(icon, size: 17, color: AppColors.inkFaint),
                const SizedBox(width: 11),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.inkSoft,
                  ),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    value,
                    textAlign: TextAlign.right,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.forest,
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    ).animate(delay: 140.ms).fadeIn().slideY(begin: 0.12, end: 0);
  }
}

class _VerificationRow extends StatelessWidget {
  const _VerificationRow({required this.row});

  final TreeVerification row;

  @override
  Widget build(BuildContext context) {
    final (color, icon, label) = switch (row.status) {
      VerificationStatus.approved => (
          AppColors.green,
          Icons.check_rounded,
          'Approved',
        ),
      VerificationStatus.manualReview => (
          AppColors.amber,
          Icons.hourglass_bottom_rounded,
          'In review',
        ),
      VerificationStatus.rejected => (
          AppColors.danger,
          Icons.close_rounded,
          'Rejected',
        ),
    };

    return DharaCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(child: Icon(icon, size: 19, color: color)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  DateFormat('MMMM yyyy').format(row.verifiedAt),
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.forest,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    label,
                    if (row.distanceM > 0) '${row.distanceM.round()} m away',
                    if (row.heightCm > 0) '${row.heightCm} cm',
                  ].join(' \u00B7 '),
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.inkSoft,
                  ),
                ),
              ],
            ),
          ),
          if (row.creditsAwarded > 0)
            Text(
              '+${row.creditsAwarded}',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w900,
                color: AppColors.green,
              ),
            ),
        ],
      ),
    );
  }
}

class _NoteBox extends StatelessWidget {
  const _NoteBox({required this.text, required this.tint});

  final String text;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 16, color: tint),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12,
                height: 1.4,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
