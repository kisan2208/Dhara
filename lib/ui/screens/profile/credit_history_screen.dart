import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/haptics.dart';
import '../../../data/models/profile.dart';
import '../../../data/models/reward.dart';
import '../../../state/auth_controller.dart';
import '../../../state/rewards_controller.dart';
import '../../widgets/common.dart';

/// Every credit movement, newest first.
///
/// This is the ledger the server treats as truth — the balance on the profile
/// is only a cache of it. Showing it in full is what makes the number on the
/// dashboard something a user can check rather than just trust.
class CreditHistoryScreen extends ConsumerWidget {
  const CreditHistoryScreen({super.key});

  static Future<void> push(BuildContext context) {
    Haptics.tap();
    return Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const CreditHistoryScreen()),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(creditHistoryProvider);

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: const Text('Credit history'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () {
            Haptics.tap();
            Navigator.of(context).maybePop();
          },
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(creditHistoryProvider),
        color: AppColors.green,
        child: switch (history) {
          AsyncError(:final error) => ErrorRetry(
              message: friendlyMessage(error),
              onRetry: () => ref.invalidate(creditHistoryProvider),
            ),
          AsyncLoading() => const Padding(
              padding: EdgeInsets.only(top: 20),
              child: LoadingList(count: 5, height: 64),
            ),
          AsyncValue(:final value?) => _Body(
              entries: value,
              profile: ref.watch(currentProfileProvider),
            ),
        },
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.entries, required this.profile});

  final List<CreditEntry> entries;

  /// The totals come from here when available. The list below is only the
  /// most recent rows, and the server counts a refund as un-spending rather
  /// than as income; summing the visible rows would get both wrong.
  final Profile? profile;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      // Still scrollable, so pull-to-refresh keeps working on an empty ledger.
      return ListView(
        children: const [
          SizedBox(height: 60),
          EmptyState(
            emoji: '\u{1F4B3}',
            title: 'Nothing here yet',
            message:
                'Plant a tree or return some packaging and your first credits '
                'will show up here.',
          ),
        ],
      );
    }

    final earned = profile?.creditsLifetime ??
        entries
            .where((e) => e.delta > 0)
            .fold<int>(0, (sum, e) => sum + e.delta);
    final spent = profile?.creditsSpent ??
        entries
            .where((e) => e.delta < 0)
            .fold<int>(0, (sum, e) => sum - e.delta);

    final rows = _rowsFor(entries);

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
      // One extra leading slot for the summary card.
      itemCount: rows.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return _Summary(earned: earned, spent: spent);
        }

        final row = rows[i - 1];
        final widget = switch (row) {
          _MonthRow(:final label) => Padding(
              padding: EdgeInsets.only(top: i == 1 ? 20 : 22, bottom: 10),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  letterSpacing: 0.4,
                  fontWeight: FontWeight.w800,
                  color: AppColors.inkFaint,
                ),
              ),
            ),
          _EntryRow(:final entry) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _LedgerCard(entry: entry),
            ),
        };

        // Only the first screenful is staggered; a longer delay would still be
        // running by the time the row has been scrolled past.
        return i <= 12
            ? widget.animate(delay: (35 * i).ms).fadeIn().slideY(
                  begin: 0.08,
                  end: 0,
                )
            : widget;
      },
    );
  }

  /// Flattens the ledger into month headings interleaved with entries.
  static List<_Row> _rowsFor(List<CreditEntry> entries) {
    final heading = DateFormat('MMMM yyyy');
    final rows = <_Row>[];
    String? month;

    for (final entry in entries) {
      // Stored in UTC. Grouped by the user's own calendar, or an early-morning
      // entry on the 1st lands under the previous month.
      final label = heading.format(entry.occurredAt.toLocal());
      if (label != month) {
        month = label;
        rows.add(_MonthRow(label.toUpperCase()));
      }
      rows.add(_EntryRow(entry));
    }
    return rows;
  }
}

sealed class _Row {
  const _Row();
}

class _MonthRow extends _Row {
  const _MonthRow(this.label);
  final String label;
}

class _EntryRow extends _Row {
  const _EntryRow(this.entry);
  final CreditEntry entry;
}

class _Summary extends StatelessWidget {
  const _Summary({required this.earned, required this.spent});

  final int earned;
  final int spent;

  @override
  Widget build(BuildContext context) {
    return DharaCard(
      gradient: AppColors.treeGradient,
      child: Row(
        children: [
          Expanded(
            child: _Half(
              label: 'Earned',
              value: earned,
              icon: Icons.arrow_downward_rounded,
            ),
          ),
          Container(width: 1, height: 42, color: Colors.white24),
          Expanded(
            child: _Half(
              label: 'Spent',
              value: spent,
              icon: Icons.arrow_upward_rounded,
            ),
          ),
        ],
      ),
    ).animate().fadeIn().slideY(begin: 0.1, end: 0);
  }
}

class _Half extends StatelessWidget {
  const _Half({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final int value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 13, color: AppColors.limeSoft),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        AnimatedCounter(
          value: value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.w900,
            height: 1,
          ),
        ),
      ],
    );
  }
}

class _LedgerCard extends StatelessWidget {
  const _LedgerCard({required this.entry});

  final CreditEntry entry;

  @override
  Widget build(BuildContext context) {
    final credit = entry.isCredit;
    final tint = credit ? AppColors.green : AppColors.amber;

    return DharaCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      radius: 16,
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.11),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(entry.emoji, style: const TextStyle(fontSize: 18)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.forest,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  entry.note.isNotEmpty
                      ? entry.note
                      : DateFormat('d MMM, h:mm a')
                          .format(entry.occurredAt.toLocal()),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.inkSoft,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                // The sign is already carried by the delta itself.
                credit ? '+${entry.delta}' : '${entry.delta}',
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w900,
                  color: tint,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'bal ${entry.balanceAfter}',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.inkFaint,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
