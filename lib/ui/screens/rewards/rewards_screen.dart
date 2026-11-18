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
import 'electricity_verify_screen.dart';

/// The rewards catalog: what the credits are actually for.
class RewardsScreen extends ConsumerWidget {
  const RewardsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rewards = ref.watch(rewardsProvider);
    final profile = ref.watch(currentProfileProvider);
    final account = ref.watch(electricityAccountProvider).value;

    return LightStatusBar(
      child: Scaffold(
        backgroundColor: AppColors.canvas,
        body: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(rewardsProvider);
            ref.invalidate(myRedemptionsProvider);
            ref.invalidate(electricityAccountProvider);
            // The balance in the header is the profile's. A refund or newly
            // vested credits only appear once it is re-read. Never throws.
            await ref.read(authControllerProvider.notifier).refreshProfile();
          },
          color: AppColors.green,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _Header(profile: profile)),

              SliverToBoxAdapter(
                child: _ElectricityRow(account: account),
              ),

              const SliverToBoxAdapter(
                child: SectionHeader(title: 'Redeem your credits'),
              ),

              ...switch (rewards) {
                AsyncError(:final error) => [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: ErrorRetry(
                          message: friendlyMessage(error),
                          onRetry: () => ref.invalidate(rewardsProvider),
                        ),
                      ),
                    ),
                  ],
                AsyncLoading() => const [
                    SliverToBoxAdapter(child: LoadingList(count: 3, height: 96)),
                  ],
                AsyncValue(:final value) => _catalog(
                    value ?? const [],
                    profile,
                    account,
                  ),
              },

              const SliverToBoxAdapter(
                child: SectionHeader(title: 'Recent redemptions'),
              ),
              const SliverToBoxAdapter(child: _RedemptionList()),

              const SliverToBoxAdapter(child: SizedBox(height: 120)),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _catalog(
    List<Reward> rewards,
    Profile? profile,
    ElectricityAccount? account,
  ) {
    if (rewards.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: DharaCard(
              child: Text(
                'No rewards are listed yet. Check back soon.',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.inkSoft,
                ),
              ),
            ),
          ),
        ),
      ];
    }

    // Affordable first, then by cost, so the list opens on what is reachable.
    final available = profile?.creditsAvailable ?? 0;
    final sorted = [...rewards]..sort((a, b) {
      final affordableA = a.creditsCost <= available;
      final affordableB = b.creditsCost <= available;
      if (affordableA != affordableB) return affordableA ? -1 : 1;
      return a.creditsCost.compareTo(b.creditsCost);
    });

    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverList.separated(
          itemCount: sorted.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, i) => _RewardCard(
            reward: sorted[i],
            profile: profile,
            account: account,
          ).animate(delay: (50 * i).ms).fadeIn().slideY(begin: 0.12, end: 0),
        ),
      ),
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.profile});

  final Profile? profile;

  @override
  Widget build(BuildContext context) {
    return GradientHeader(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Rewards',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              AnimatedCounter(
                value: profile?.creditsAvailable ?? 0,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 38,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'to spend',
                  style: TextStyle(
                    color: AppColors.limeSoft.withValues(alpha: 0.9),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (profile != null && profile!.creditsPending > 0) ...[
            const SizedBox(height: 8),
            Text(
              '${profile!.creditsPending} more still vesting with your trees',
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    ).animate().fadeIn(duration: 320.ms);
  }
}

/// Prompt or status for the electricity account, which bill credit depends on.
class _ElectricityRow extends StatelessWidget {
  const _ElectricityRow({required this.account});

  final ElectricityAccount? account;

  @override
  Widget build(BuildContext context) {
    final a = account;

    final (tint, icon, title, subtitle) = switch (a) {
      null => (
          AppColors.info,
          Icons.add_card_rounded,
          'Link your electricity bill',
          'Verify your consumer number once to redeem bill credit.',
        ),
      ElectricityAccount(isVerified: true) => (
          AppColors.green,
          Icons.verified_rounded,
          'Electricity account verified',
          a.masked,
        ),
      ElectricityAccount(isPending: true) => (
          AppColors.amber,
          Icons.hourglass_bottom_rounded,
          'Bill under review',
          'We could not read the number clearly. A reviewer will confirm it '
              'within 48 hours.',
        ),
      _ => (
          AppColors.danger,
          Icons.error_outline_rounded,
          'Account not verified',
          a.rejectReason?.isNotEmpty == true
              ? a.rejectReason!
              : 'Submit a clearer photo of your bill.',
        ),
    };

    final actionable = a == null || a.isRejected;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: DharaCard(
        onTap: actionable
            ? () => ElectricityVerifyScreen.push(context)
            : null,
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Center(child: Icon(icon, size: 20, color: tint)),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: AppColors.forest,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                      color: AppColors.inkSoft,
                    ),
                  ),
                ],
              ),
            ),
            if (actionable)
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.inkFaint,
              ),
          ],
        ),
      ),
    ).animate(delay: 100.ms).fadeIn().slideY(begin: 0.12, end: 0);
  }
}

class _RewardCard extends ConsumerWidget {
  const _RewardCard({
    required this.reward,
    required this.profile,
    required this.account,
  });

  final Reward reward;
  final Profile? profile;
  final ElectricityAccount? account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = profile?.creditsAvailable ?? 0;
    final blocked = reward.blockedReason(
      availableCredits: available,
      level: profile?.level ?? 1,
      electricityVerified: account?.isVerified ?? false,
    );
    final affordable = available >= reward.creditsCost;

    return DharaCard(
      onTap: () => _open(context, ref, blocked),
      padding: const EdgeInsets.all(15),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: AppColors.surfaceMuted,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Center(
                  child: Text(
                    reward.icon,
                    style: const TextStyle(fontSize: 23),
                  ),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      reward.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.forest,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      reward.subtitle.isNotEmpty
                          ? reward.subtitle
                          : reward.faceValueInr > 0
                              ? 'Worth \u20B9${reward.faceValueInr}'
                              : reward.type.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${reward.creditsCost}',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                      color: affordable ? AppColors.green : AppColors.inkFaint,
                    ),
                  ),
                  const Text(
                    'credits',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppColors.inkFaint,
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (blocked != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(
                  Icons.lock_outline_rounded,
                  size: 13,
                  color: AppColors.inkFaint,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    blocked,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.inkFaint,
                    ),
                  ),
                ),
              ],
            ),
            if (!affordable && reward.creditsCost > 0) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: (available / reward.creditsCost).clamp(0.0, 1.0),
                  minHeight: 5,
                  backgroundColor: AppColors.surfaceMuted,
                  valueColor:
                      const AlwaysStoppedAnimation(AppColors.sage),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    String? blocked,
  ) async {
    // Being short on a verified bill account is the one block the user can
    // clear right now, so send them there instead of a dead end.
    if (reward.requiresElectricityAccount &&
        !(account?.isVerified ?? false)) {
      Haptics.warn();
      await ElectricityVerifyScreen.push(context);
      return;
    }

    if (blocked != null) {
      Haptics.warn();
      showSnack(context, blocked, isError: true);
      return;
    }

    await showRedeemSheet(context, ref, reward, account);
  }
}

/// Confirmation before spending credits, then the outcome.
Future<void> showRedeemSheet(
  BuildContext context,
  WidgetRef ref,
  Reward reward,
  ElectricityAccount? account,
) {
  Haptics.press();

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _RedeemSheet(reward: reward, account: account),
  );
}

class _RedeemSheet extends ConsumerStatefulWidget {
  const _RedeemSheet({required this.reward, required this.account});

  final Reward reward;
  final ElectricityAccount? account;

  @override
  ConsumerState<_RedeemSheet> createState() => _RedeemSheetState();
}

class _RedeemSheetState extends ConsumerState<_RedeemSheet> {
  bool _busy = false;
  RedeemResult? _result;

  Reward get _reward => widget.reward;

  Future<void> _confirm() async {
    if (_busy) return;
    setState(() => _busy = true);
    Haptics.press();

    try {
      final result = await ref
          .read(rewardsControllerProvider.notifier)
          .redeem(reward: _reward);
      if (!mounted) return;
      Haptics.celebrate();
      setState(() {
        _result = result;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      Haptics.error();
      setState(() => _busy = false);
      showSnack(context, friendlyMessage(e), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(28),
          ),
          child: result == null ? _confirmView() : _resultView(result),
        ),
      ),
    );
  }

  Widget _confirmView() {
    final account = widget.account;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 70,
          height: 70,
          decoration: const BoxDecoration(
            color: AppColors.surfaceMuted,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(_reward.icon, style: const TextStyle(fontSize: 31)),
          ),
        ).animate().scale(duration: 420.ms, curve: Curves.easeOutBack).fadeIn(),
        const SizedBox(height: 18),
        Text(
          _reward.title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w800,
            color: AppColors.forest,
          ),
        ),
        if (_reward.description.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            _reward.description,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.5,
              fontWeight: FontWeight.w500,
              color: AppColors.inkSoft,
            ),
          ),
        ],
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            color: AppColors.surfaceMuted,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Column(
            children: [
              _Line(label: 'Cost', value: '${_reward.creditsCost} credits'),
              if (_reward.faceValueInr > 0) ...[
                const SizedBox(height: 8),
                _Line(label: 'Value', value: '\u20B9${_reward.faceValueInr}'),
              ],
              if (_reward.requiresElectricityAccount && account != null) ...[
                const SizedBox(height: 8),
                _Line(label: 'Bill account', value: account.masked),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _busy ? null : _confirm,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  )
                : Text('Redeem for ${_reward.creditsCost}'),
          ),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Not now'),
        ),
      ],
    );
  }

  Widget _resultView(RedeemResult result) {
    final code = result.voucherCode;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 74,
          height: 74,
          decoration: BoxDecoration(
            color: AppColors.green.withValues(alpha: 0.13),
            shape: BoxShape.circle,
          ),
          child: const Center(
            child: Icon(Icons.check_rounded, size: 36, color: AppColors.green),
          ),
        ).animate().scale(duration: 450.ms, curve: Curves.easeOutBack).fadeIn(),
        const SizedBox(height: 18),
        Text(
          code != null && code.isNotEmpty ? 'Here is your code' : 'Request placed',
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w800,
            color: AppColors.forest,
          ),
        ).animate(delay: 90.ms).fadeIn(),
        const SizedBox(height: 8),
        Text(
          code != null && code.isNotEmpty
              ? 'Use it before it expires. You can find it again under recent '
                  'redemptions.'
              : 'We are processing it now. You will see it under recent '
                  'redemptions once it is done.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 12.5,
            height: 1.5,
            fontWeight: FontWeight.w500,
            color: AppColors.inkSoft,
          ),
        ),
        if (code != null && code.isNotEmpty) ...[
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            decoration: BoxDecoration(
              color: AppColors.limeSoft,
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: AppColors.sage),
            ),
            child: Center(
              child: SelectableText(
                code,
                style: const TextStyle(
                  fontSize: 17,
                  letterSpacing: 1.6,
                  fontWeight: FontWeight.w900,
                  color: AppColors.forest,
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surfaceMuted,
            borderRadius: BorderRadius.circular(14),
          ),
          child: _Line(
            label: 'Balance left',
            value: '${result.balance} credits',
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () {
              Haptics.tap();
              Navigator.of(context).pop();
            },
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            child: const Text('Done'),
          ),
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppColors.inkSoft,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: AppColors.forest,
          ),
        ),
      ],
    );
  }
}

class _RedemptionList extends ConsumerWidget {
  const _RedemptionList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final redemptions = ref.watch(myRedemptionsProvider);

    return switch (redemptions) {
      AsyncError(:final error) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: ErrorRetry(
            message: friendlyMessage(error),
            onRetry: () => ref.invalidate(myRedemptionsProvider),
          ),
        ),
      AsyncLoading() => const LoadingList(count: 2, height: 70),
      AsyncValue(:final value) => _list(value ?? const []),
    };
  }

  Widget _list(List<Redemption> rows) {
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20),
        child: DharaCard(
          child: Text(
            'Nothing redeemed yet.',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppColors.inkSoft,
            ),
          ),
        ),
      );
    }

    final format = DateFormat('d MMM yyyy');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: rows.take(6).toList().asMap().entries.map((e) {
          final r = e.value;
          final tint = switch (r.status) {
            RedemptionStatus.fulfilled => AppColors.green,
            RedemptionStatus.failed => AppColors.danger,
            RedemptionStatus.cancelled => AppColors.inkFaint,
            _ => AppColors.amber,
          };

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: DharaCard(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceMuted,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Text(
                        r.type.emoji,
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.rewardTitle.isNotEmpty
                              ? r.rewardTitle
                              : r.type.label,
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
                          format.format(r.requestedAt.toLocal()),
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.inkSoft,
                          ),
                        ),
                        // The result sheet that first shows a voucher code can
                        // be swiped away, and it promises the code can be found
                        // here again. This is that place.
                        if (r.voucherCode case final code?
                            when code.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          SelectableText(
                            'Code: $code',
                            style: const TextStyle(
                              fontSize: 12.5,
                              letterSpacing: 0.8,
                              fontWeight: FontWeight.w800,
                              color: AppColors.forest,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      StatusPill(
                        label: r.status.label,
                        color: tint,
                        compact: true,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '-${r.creditsSpent}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppColors.inkSoft,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ).animate(delay: (45 * e.key).ms).fadeIn();
        }).toList(),
      ),
    );
  }
}
