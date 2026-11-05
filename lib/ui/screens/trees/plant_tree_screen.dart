import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/env.dart';
import '../../../core/services/location.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/haptics.dart';
import '../../../data/models/tree.dart';
import '../../../state/trees_controller.dart';
import '../../widgets/photo_review.dart';
import '../../widgets/celebrate.dart';
import '../../widgets/common.dart';
import '../../widgets/gps_stamp.dart';
import '../../widgets/tree_map.dart';

/// Registers a new tree: pick a species, get a precise fix, photograph it.
///
/// The order is deliberate. A GPS fix accurate enough to satisfy the server
/// takes several seconds to settle, so it is acquired while the user is still
/// reading the screen rather than after they have already taken a photo that
/// might have to be thrown away.
class PlantTreeScreen extends ConsumerStatefulWidget {
  const PlantTreeScreen({super.key});

  static Future<void> push(BuildContext context) {
    Haptics.press();
    return Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const PlantTreeScreen()),
    );
  }

  @override
  ConsumerState<PlantTreeScreen> createState() => _PlantTreeScreenState();
}

class _PlantTreeScreenState extends ConsumerState<PlantTreeScreen> {
  final _nickname = TextEditingController();
  final _height = TextEditingController();

  int _step = 0;
  Species? _species;

  LocationFix? _fix;
  double? _accuracy;
  bool _locating = false;
  String? _locationError;

  bool _submitting = false;

  /// Live position, for the map only.
  ///
  /// Deliberately separate from [_fix]: that one comes from `bestFix`, which
  /// samples repeatedly for accuracy and resolves an address, and it is what
  /// gets submitted. Driving the map from the same call would leave the dot
  /// frozen for the several seconds that takes. This stream is display-only.
  LocationFix? _live;
  StreamSubscription<LocationFix>? _watch;

  /// The device's cached position, used only so the map has somewhere to point
  /// while the first real reading settles. Never submitted: it can be old.
  LocationFix? _lastKnown;

  /// How many trees have been registered without leaving this screen, so a user
  /// planting a row of saplings does not have to restart the flow each time.
  int _planted = 0;
  int _sessionCredits = 0;

  @override
  void dispose() {
    _stopWatching();
    _nickname.dispose();
    _height.dispose();
    super.dispose();
  }

  void _startWatching() {
    _watch?.cancel();
    _watch = ref.read(locationServiceProvider).watch().listen(
          (fix) {
            if (mounted) setState(() => _live = fix);
          },
          // Failures are already surfaced by _acquireFix, which the user has a
          // retry button for. Reporting the same problem twice is noise.
          onError: (Object e) => debugPrint('position stream: $e'),
        );
  }

  /// The stream drains the battery for nothing once the map is off screen, so it
  /// stops whenever the location step ends rather than at screen disposal.
  void _stopWatching() {
    _watch?.cancel();
    _watch = null;
  }

  /// Begins a fresh search for the user: live dots, a precise fix, and a cached
  /// position so the map is not empty while those settle.
  void _beginLocating() {
    _live = null;
    _lastKnown = null;
    _startWatching();
    _acquireFix();
    _loadLastKnown();
  }

  Future<void> _loadLastKnown() async {
    final cached = await ref.read(locationServiceProvider).lastKnown();
    // Only if nothing better has arrived in the meantime.
    if (!mounted || cached == null || _live != null || _fix != null) return;
    setState(() => _lastKnown = cached);
  }

  /// Retry restarts the stream as well as the fix. Re-running only the fix would
  /// leave a stream that had already failed dead for the rest of the visit.
  void _retryLocating() {
    _startWatching();
    _acquireFix();
  }

  /// The nearest already-registered tree that would make this spot illegal.
  ///
  /// The server enforces this and is the authority (tree.js rejects anything
  /// inside `tree.min_spacing_m`). This is only a heads-up, and deliberately
  /// does not disable the button: GPS is accurate to metres at best, so a fix
  /// that reads 2 m away may really be 5 m away, and blocking on that would
  /// stop an honest user planting a legitimate tree.
  (Tree, double)? _spacingConflict(LocationFix fix, List<Tree> trees) {
    final service = ref.read(locationServiceProvider);
    for (final tree in trees) {
      final d = service.distanceBetween(fix.lat, fix.lng, tree.lat, tree.lng);
      if (d < Tunables.minTreeSpacingM) return (tree, d);
    }
    return null;
  }

  /// Trees close enough to be worth drawing. A marker for a tree in another
  /// city is just cost.
  List<Tree> _nearby(LocationFix? fix, List<Tree> all) {
    if (fix == null) return const [];
    final service = ref.read(locationServiceProvider);
    return all
        .where(
          (t) =>
              service.distanceBetween(fix.lat, fix.lng, t.lat, t.lng) <= 250,
        )
        .toList();
  }

  bool get _fixIsGoodEnough =>
      _fix != null && _fix!.accuracyM <= Tunables.maxGpsAccuracyM;

  Future<void> _acquireFix() async {
    if (_locating) return;

    setState(() {
      _locating = true;
      _locationError = null;
      _accuracy = null;
    });

    try {
      final fix = await ref.read(locationServiceProvider).bestFix(
            targetAccuracyM: 15,
            resolveAddress: true,
            onProgress: (accuracyM, _) {
              if (mounted) setState(() => _accuracy = accuracyM);
            },
          );
      if (!mounted) return;
      setState(() {
        _fix = fix;
        _accuracy = fix.accuracyM;
        _locating = false;
      });
      if (fix.accuracyM <= Tunables.maxGpsAccuracyM) {
        Haptics.success();
      } else {
        Haptics.warn();
      }
    } on LocationFailure catch (e) {
      if (!mounted) return;
      Haptics.error();
      setState(() {
        _locating = false;
        _locationError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      Haptics.error();
      setState(() {
        _locating = false;
        _locationError = friendlyMessage(e);
      });
    }
  }

  Future<void> _captureAndSubmit() async {
    final species = _species;
    final fix = _fix;
    if (species == null || fix == null || _submitting) return;

    final path = await capturePhotoWithReview(
      context,
      title: 'Photograph the sapling',
      hint: 'Get the whole plant in frame, with the ground visible. '
          'Photos are compared against past submissions.',
    );
    if (path == null || !mounted) return;

    setState(() => _submitting = true);

    try {
      final result = await ref.read(treesControllerProvider.notifier).plant(
            photoPath: path,
            fix: fix,
            speciesCode: species.code,
            nickname: _nickname.text.trim(),
            heightCm: int.tryParse(_height.text.trim()) ?? 0,
          );

      if (!mounted) return;

      _planted++;
      _sessionCredits += result.creditsAwarded;

      await showAwardSheet(
        context,
        title: result.needsReview
            ? 'Sent for a quick review'
            : 'Tree registered',
        credits: result.creditsAwarded,
        emoji: species.emoji,
        needsReview: result.needsReview,
        reasons: result.reasons,
        balance: result.balance,
        message: result.needsReview
            ? 'Someone will look at this shortly. You will get your credits '
                'once it is approved.'
            : 'Come back next month and check in on it to keep earning. '
                'Credits vest over ${Tunables.vestingMonths} months as it '
                'survives. Planting more? Just walk to the next spot.',
        actionLabel: 'Plant another',
      );

      if (!mounted) return;

      // Stay on the screen rather than popping: planting several saplings in one
      // trip is the normal case, and the controller has already refreshed the
      // tree list, so the one just registered now shows on the map with its own
      // spacing ring for the next one.
      _nickname.clear();
      _height.clear();
      _stopWatching();
      setState(() {
        _submitting = false;
        _step = 0;
        _fix = null;
        _live = null;
        _lastKnown = null;
        _accuracy = null;
        _locationError = null;
      });
    } catch (e) {
      if (!mounted) return;
      Haptics.error();
      setState(() => _submitting = false);
      showSnack(context, friendlyMessage(e), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: Text(_planted == 0 ? 'Plant a tree' : 'Plant another'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: _submitting
              ? null
              : () {
                  Haptics.tap();
                  Navigator.of(context).pop();
                },
        ),
        actions: [
          // Only offered once something has been registered: before that, the
          // back arrow already means the same thing.
          if (_planted > 0 && !_submitting)
            TextButton(
              onPressed: () {
                Haptics.press();
                Navigator.of(context).pop();
              },
              child: const Text('Done'),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_planted > 0) _SessionStrip(
              planted: _planted,
              credits: _sessionCredits,
            ),
            _StepBar(step: _step),
            Expanded(
              child: _step == 0 ? _detailsStep() : _locationStep(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailsStep() {
    final species = ref.watch(speciesProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        Text(
          'What are you planting?',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppColors.forest,
              ),
        ).animate().fadeIn().slideY(begin: 0.2, end: 0),
        const SizedBox(height: 6),
        const Text(
          'Different species absorb different amounts of CO\u2082, so they '
          'earn different credits.',
          style: TextStyle(
            fontSize: 13,
            height: 1.45,
            fontWeight: FontWeight.w500,
            color: AppColors.inkSoft,
          ),
        ).animate(delay: 80.ms).fadeIn(),
        const SizedBox(height: 20),

        switch (species) {
          AsyncError(:final error) => ErrorRetry(
              message: friendlyMessage(error),
              onRetry: () => ref.invalidate(speciesProvider),
            ),
          AsyncLoading() => const LoadingList(count: 3, height: 68),
          AsyncValue(:final value) => _SpeciesPicker(
              species: value ?? const [],
              selected: _species,
              onSelect: (s) {
                Haptics.select();
                setState(() => _species = s);
              },
            ),
        },

        const SizedBox(height: 22),
        TextField(
          controller: _nickname,
          textCapitalization: TextCapitalization.words,
          maxLength: 40,
          decoration: const InputDecoration(
            labelText: 'Give it a name (optional)',
            hintText: 'e.g. the one by the gate',
            prefixIcon: Icon(Icons.label_outline_rounded),
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _height,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(3),
          ],
          decoration: const InputDecoration(
            labelText: 'Height in cm (optional)',
            helperText: 'Used to track growth at each check-in',
            prefixIcon: Icon(Icons.straighten_rounded),
          ),
        ),
        const SizedBox(height: 26),

        FilledButton(
          onPressed: _species == null
              ? null
              : () {
                  Haptics.press();
                  setState(() => _step = 1);
                  // The map dot and the submitted fix come from two different
                  // sources; both start here.
                  _beginLocating();
                },
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: const Text('Next'),
        ),
      ],
    );
  }

  Widget _locationStep() {
    final trees = ref.watch(treesControllerProvider).value ?? const <Tree>[];
    // Prefer the live dot so the map tracks walking, but fall back to the
    // settled fix so the map still appears if the stream is refused.
    final shown = _live ?? _fix ?? _lastKnown;
    // A cached position is a placeholder, not a reading: flag it on the map.
    final approximate = _live == null && _fix == null && _lastKnown != null;
    final nearby = _nearby(shown, trees);

    final conflict = _fix == null ? null : _spacingConflict(_fix!, trees);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        Text(
          'Stand next to the tree',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppColors.forest,
              ),
        ).animate().fadeIn().slideY(begin: 0.2, end: 0),
        const SizedBox(height: 6),
        const Text(
          'We record the exact spot so you can prove you were there at every '
          'monthly check-in.',
          style: TextStyle(
            fontSize: 13,
            height: 1.45,
            fontWeight: FontWeight.w500,
            color: AppColors.inkSoft,
          ),
        ).animate(delay: 80.ms).fadeIn(),
        const SizedBox(height: 24),

        TreeMap(
          me: shown,
          trees: nearby,
          spacingRingM: Tunables.minTreeSpacingM,
          approximate: approximate,
          // With no position at all, say why instead of spinning indefinitely.
          error: shown == null ? _locationError : null,
          onRetry: _retryLocating,
        ),

        if (nearby.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            nearby.length == 1
                ? 'The red ring is your other tree. Stay outside it.'
                : 'Red rings are your ${nearby.length} nearby trees. Stay '
                    'outside them.',
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: AppColors.inkSoft,
            ),
          ),
        ],

        const SizedBox(height: 14),

        _GpsCard(
          locating: _locating,
          accuracy: _accuracy,
          fix: _fix,
          error: _locationError,
          onRetry: _retryLocating,
        ),

        if (conflict != null) ...[
          const SizedBox(height: 12),
          _TooCloseWarning(tree: conflict.$1, distanceM: conflict.$2),
        ],

        // The settled fix, not the live one. This is the reading that will be
        // written against the tree, so it is the one worth showing in full — a
        // panel that renumbered itself every couple of metres would be showing
        // something that never gets recorded.
        if (_fix case final fix?) ...[
          const SizedBox(height: 12),
          GpsStampCard(fix: fix, title: 'WHAT GETS RECORDED'),
        ],

        const SizedBox(height: 26),

        FilledButton.icon(
          onPressed: _fixIsGoodEnough && !_submitting ? _captureAndSubmit : null,
          icon: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.camera_alt_rounded, size: 19),
          label: Text(_submitting ? 'Registering\u2026' : 'Take the photo'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
        const SizedBox(height: 10),
        Center(
          child: TextButton(
            onPressed: _submitting
                ? null
                : () {
                    Haptics.tap();
                    _stopWatching();
                    setState(() => _step = 0);
                  },
            child: const Text('Back'),
          ),
        ),
      ],
    );
  }
}

/// Running tally for a single trip out with a bag of saplings.
///
/// Worth showing because the flow no longer ends after one tree: without this
/// there is nothing to confirm the previous submissions actually landed.
class _SessionStrip extends StatelessWidget {
  const _SessionStrip({required this.planted, required this.credits});

  final int planted;
  final int credits;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.limeSoft,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          const Text('\u{1F331}', style: TextStyle(fontSize: 17)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              planted == 1
                  ? '1 tree registered on this trip'
                  : '$planted trees registered on this trip',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: AppColors.forest,
              ),
            ),
          ),
          if (credits > 0)
            Row(
              children: [
                AnimatedCounter(
                  value: credits,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: AppColors.green,
                    height: 1,
                  ),
                ),
                const SizedBox(width: 3),
                const Text(
                  'credits',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.inkSoft,
                  ),
                ),
              ],
            ),
        ],
      ),
    ).animate().fadeIn().slideY(begin: -0.3, end: 0);
  }
}

/// Shown when the current fix sits inside another tree's exclusion ring.
///
/// Advisory, not blocking. The server has the final say, and GPS error alone can
/// account for a couple of metres — refusing to submit here would strand a user
/// who really is standing far enough away.
class _TooCloseWarning extends StatelessWidget {
  const _TooCloseWarning({required this.tree, required this.distanceM});

  final Tree tree;
  final double distanceM;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 19,
            color: AppColors.danger,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              'You are about ${distanceM.round()} m from '
              '"${tree.displayName}". Trees need '
              '${Tunables.minTreeSpacingM.round()} m between them, so this may '
              'be turned down. Take a few steps and wait for the fix to catch '
              'up.',
              style: const TextStyle(
                fontSize: 12,
                height: 1.45,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
          ),
        ],
      ),
    ).animate().fadeIn().shake(hz: 3, offset: const Offset(2, 0));
  }
}

class _StepBar extends StatelessWidget {
  const _StepBar({required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
      child: Row(
        children: List.generate(2, (i) {
          final done = i <= step;
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i == 0 ? 8 : 0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                height: 5,
                decoration: BoxDecoration(
                  color: done ? AppColors.green : AppColors.outline,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _SpeciesPicker extends StatelessWidget {
  const _SpeciesPicker({
    required this.species,
    required this.selected,
    required this.onSelect,
  });

  final List<Species> species;
  final Species? selected;
  final ValueChanged<Species> onSelect;

  @override
  Widget build(BuildContext context) {
    if (species.isEmpty) {
      return const DharaCard(
        child: Text(
          'The species list is empty. Pull to refresh in a moment.',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppColors.inkSoft,
          ),
        ),
      );
    }

    return Column(
      children: species.asMap().entries.map((e) {
        final s = e.value;
        final isSelected = selected?.code == s.code;

        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: DharaCard(
            onTap: () => onSelect(s),
            color: isSelected ? AppColors.limeSoft : AppColors.surface,
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Colors.white.withValues(alpha: 0.7)
                        : AppColors.surfaceMuted,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Center(
                    child: Text(s.emoji, style: const TextStyle(fontSize: 21)),
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.name,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          color: AppColors.forest,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${s.creditsPerVerification} credits per check-in',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.inkSoft,
                        ),
                      ),
                      if (s.co2PerYearGrams > 0)
                        Text(
                          '\u2248 ${(s.co2PerYearGrams / 1000).toStringAsFixed(0)} kg '
                          'CO\u2082 a year when mature',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.inkFaint,
                          ),
                        ),
                    ],
                  ),
                ),
                AnimatedScale(
                  scale: isSelected ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutBack,
                  child: const Icon(
                    Icons.check_circle_rounded,
                    color: AppColors.green,
                    size: 22,
                  ),
                ),
              ],
            ),
          ),
        ).animate(delay: (50 * e.key).ms).fadeIn().slideY(begin: 0.12, end: 0);
      }).toList(),
    );
  }
}

class _GpsCard extends StatelessWidget {
  const _GpsCard({
    required this.locating,
    required this.accuracy,
    required this.fix,
    required this.error,
    required this.onRetry,
  });

  final bool locating;
  final double? accuracy;
  final LocationFix? fix;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return DharaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.location_off_rounded,
                  color: AppColors.danger,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    error!,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                      color: AppColors.ink,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                OutlinedButton(
                  onPressed: onRetry,
                  child: const Text('Try again'),
                ),
                const SizedBox(width: 10),
                TextButton(
                  onPressed: () =>
                      const LocationService().openSettings(),
                  child: const Text('Open settings'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final good = fix != null && fix!.accuracyM <= Tunables.maxGpsAccuracyM;
    final shown = accuracy;

    return DharaCard(
      gradient: good ? AppColors.treeGradient : null,
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 26,
                height: 26,
                child: locating
                    ? CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: good ? Colors.white : AppColors.green,
                      )
                    : Icon(
                        good
                            ? Icons.check_circle_rounded
                            : Icons.location_searching_rounded,
                        color: good ? Colors.white : AppColors.amber,
                        size: 24,
                      ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      locating
                          ? 'Getting a precise fix\u2026'
                          : good
                              ? 'Location locked'
                              : 'Signal not precise enough',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        color: good ? Colors.white : AppColors.forest,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      shown == null
                          ? 'Hold still for a moment'
                          : 'Accurate to about ${shown.round()} m',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: good
                            ? Colors.white.withValues(alpha: 0.85)
                            : AppColors.inkSoft,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (fix?.address case final address?) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  Icons.place_outlined,
                  size: 15,
                  color: good ? Colors.white70 : AppColors.inkFaint,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    address,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: good ? Colors.white70 : AppColors.inkSoft,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (!locating && !good && fix != null) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: Text(
                  'Retry \u00B7 need ${Tunables.maxGpsAccuracyM.round()} m or better',
                ),
              ),
            ),
          ],
        ],
      ),
    ).animate().fadeIn();
  }
}
