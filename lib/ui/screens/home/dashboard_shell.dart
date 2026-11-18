import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/haptics.dart';
import '../../../state/air_controller.dart';
import '../../../state/auth_controller.dart';
import '../../../state/footprint_controller.dart';
import '../../../state/items_controller.dart';
import '../../../state/leaderboard_controller.dart';
import '../../../state/rewards_controller.dart';
import '../../../state/trees_controller.dart';
import '../profile/profile_screen.dart';
import '../rewards/rewards_screen.dart';
import '../scan/scan_screen.dart';
import '../trees/trees_screen.dart';
import 'home_screen.dart';

/// Measured height of the nav bar's own content, with a little headroom.
///
/// Erring high is the safe direction: a few points of extra gap is invisible,
/// a few points short means the bar clips whatever sits under it.
const _barHeight = 78.0;
const _barMargin = 12.0;

/// What a tab must leave clear at the bottom so the floating nav bar does not
/// cover it.
///
/// The shell sets `extendBody: true`, so the bar is painted *over* each tab
/// rather than beside it. A tab with its own bare [Scaffold] measures from the
/// screen edge and has no idea the bar is there — which is how the trees tab's
/// "Plant a tree" button ended up positioned entirely behind it and invisible.
/// Anything pinned to the bottom of a tab needs this.
double dashboardBottomInset(BuildContext context) =>
    _barHeight + _barMargin + MediaQuery.viewPaddingOf(context).bottom * 0.4;

/// The signed-in container: five tabs behind a custom animated bar.
///
/// An [IndexedStack] keeps each tab's scroll position and in-flight futures
/// alive when switching, which matters because several tabs hold camera or
/// location state that is expensive to rebuild.
class DashboardShell extends ConsumerStatefulWidget {
  const DashboardShell({super.key});

  @override
  ConsumerState<DashboardShell> createState() => _DashboardShellState();
}

class _DashboardShellState extends ConsumerState<DashboardShell> {
  int _index = 0;

  static const _tabs = <_TabSpec>[
    _TabSpec('Home', Icons.home_rounded, Icons.home_outlined),
    _TabSpec('Trees', Icons.park_rounded, Icons.park_outlined),
    _TabSpec('Scan', Icons.qr_code_scanner_rounded, Icons.qr_code_scanner_rounded),
    _TabSpec('Rewards', Icons.redeem_rounded, Icons.redeem_outlined),
    _TabSpec('You', Icons.person_rounded, Icons.person_outline_rounded),
  ];

  void _select(int next) {
    if (next == _index) return;
    Haptics.select();
    setState(() => _index = next);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back from a sub-tab returns to Home rather than closing the app.
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _select(0);
      },
      child: Scaffold(
        extendBody: true,
        body: IndexedStack(
          index: _index,
          children: [
            HomeScreen(onSeeAllTrees: () => _select(1), onScan: () => _select(2)),
            const TreesScreen(),
            // Told whether it is on screen: an IndexedStack builds every tab,
            // and a scanner that was not told would run the camera (and act on
            // any code in view) from the moment the app opened.
            ScanScreen(active: _index == 2),
            const RewardsScreen(),
            const ProfileScreen(),
          ],
        ),
        bottomNavigationBar: _BottomBar(
          index: _index,
          tabs: _tabs,
          onSelect: _select,
        ),
      ),
    );
  }
}

class _TabSpec {
  const _TabSpec(this.label, this.active, this.inactive);
  final String label;
  final IconData active;
  final IconData inactive;
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.index,
    required this.tabs,
    required this.onSelect,
  });

  final int index;
  final List<_TabSpec> tabs;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        12 + MediaQuery.viewPaddingOf(context).bottom * 0.4,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.forestInk,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: AppColors.forestDeep.withValues(alpha: 0.32),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(tabs.length, (i) {
          final tab = tabs[i];
          final selected = i == index;

          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelect(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.lime.withValues(alpha: 0.18)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // A slight lift plus colour shift reads as "selected"
                    // without moving neighbouring tabs around.
                    AnimatedSlide(
                      offset: Offset(0, selected ? -0.12 : 0),
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeOutBack,
                      child: Icon(
                        selected ? tab.active : tab.inactive,
                        size: 23,
                        color: selected ? AppColors.lime : Colors.white54,
                      ),
                    ),
                    const SizedBox(height: 3),
                    AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 240),
                      style: TextStyle(
                        fontSize: selected ? 11 : 10.5,
                        fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                        color: selected ? AppColors.lime : Colors.white54,
                      ),
                      child: Text(tab.label),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// Pull-to-refresh shared by the tabs: refreshes everything the dashboard reads.
Future<void> refreshDashboard(WidgetRef ref) async {
  ref.invalidate(rewardsProvider);
  ref.invalidate(creditHistoryProvider);
  ref.invalidate(badgesProvider);
  ref.invalidate(leaderboardProvider);
  // A pull to refresh is also how someone who just switched location on gets
  // the air card to notice.
  ref.invalidate(passiveLocationProvider);
  ref.invalidate(airQualityProvider);
  ref.invalidate(speciesProvider);
  ref.invalidate(footprintHistoryProvider);
  await Future.wait([
    ref.read(treesControllerProvider.notifier).refresh(),
    ref.read(itemsControllerProvider.notifier).refresh(),
    // Credits vest and refunds land on the server without any action here,
    // so the balance and impact tiles need their own reload. Never throws.
    ref.read(authControllerProvider.notifier).refreshProfile(),
  ]);
}
