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

/// The monthly check-in: prove you are standing at the tree, then photograph it.
///
/// The client checks the radius before allowing a capture purely to save the
/// user a wasted photo and upload. The server re-checks everything and is the
/// only authority — a patched client gains nothing.
class VerifyTreeScreen extends ConsumerStatefulWidget {
  const VerifyTreeScreen({super.key, required this.tree});

  final Tree tree;

  static Future<void> push(BuildContext context, Tree tree) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => VerifyTreeScreen(tree: tree)),
    );
  }

  @override
  ConsumerState<VerifyTreeScreen> createState() => _VerifyTreeScreenState();
}

class _VerifyTreeScreenState extends ConsumerState<VerifyTreeScreen> {
  final _height = TextEditingController();

  LocationFix? _fix;
  double? _distance;
  double? _accuracy;
  bool _locating = false;
  String? _locationError;
  bool _submitting = false;

  Tree get _tree => widget.tree;

  @override
  void initState() {
    super.initState();
    if (_tree.heightCm > 0) _height.text = '${_tree.heightCm}';
    // The user opened this screen to check in, so start locating immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) => _acquireFix());
  }

  @override
  void dispose() {
    _height.dispose();
    super.dispose();
  }

  bool get _inRadius =>
      _distance != null && _distance! <= Tunables.verifyRadiusM;

  bool get _accurateEnough =>
      _accuracy != null && _accuracy! <= Tunables.maxGpsAccuracyM;

  bool get _canCapture => _inRadius && _accurateEnough && !_submitting;

  Future<void> _acquireFix() async {
    if (_locating) return;

    setState(() {
      _locating = true;
      _locationError = null;
    });

    try {
      final service = ref.read(locationServiceProvider);
      final fix = await service.bestFix(
        targetAccuracyM: 15,
        onProgress: (accuracyM, _) {
          if (mounted) setState(() => _accuracy = accuracyM);
        },
      );

      final distance = service.distanceBetween(
        fix.lat,
        fix.lng,
        _tree.lat,
        _tree.lng,
      );

      if (!mounted) return;
      setState(() {
        _fix = fix;
        _accuracy = fix.accuracyM;
        _distance = distance;
        _locating = false;
      });

      if (distance <= Tunables.verifyRadiusM && _accurateEnough) {
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
    final fix = _fix;
    if (fix == null || !_canCapture) return;

    final path = await capturePhotoWithReview(
      context,
      title: 'Photograph ${_tree.displayName}',
      hint: 'A fresh photo from where you are standing. Reusing an old photo '
          'will be detected.',
      overlay: _distance == null ? null : _DistanceBadge(metres: _distance!),
    );
    if (path == null || !mounted) return;

    setState(() => _submitting = true);

    try {
      final result = await ref.read(treesControllerProvider.notifier).verify(
            treeId: _tree.id,
            photoPath: path,
            fix: fix,
            heightCm: int.tryParse(_height.text.trim()) ?? _tree.heightCm,
          );

      if (!mounted) return;

      final vested = result.isFullyVested;
      await showAwardSheet(
        context,
        title: result.needsReview
            ? 'Sent for a quick review'
            : vested
                ? 'Fully vested!'
                : 'Check-in recorded',
        credits: result.creditsAwarded,
        streakBonus: result.streakBonus,
        balance: result.balance,
        needsReview: result.needsReview,
        reasons: result.reasons,
        emoji: vested ? '\u{1F389}' : '\u{1F4F8}',
        message: result.needsReview
            ? 'Your check-in counted. Credits are released once it is approved.'
            : vested
                ? 'This tree has completed all ${result.vestingMonths} months. '
                    'Every credit it earned is now fully yours.'
                : 'Month ${result.vestedCount} of ${result.vestingMonths} done. '
                    'See you next month.',
        actionLabel: 'Done',
      );

      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      Haptics.error();
      setState(() => _submitting = false);
      showSnack(context, friendlyMessage(e), isError: true);
      // The server may have measured a different distance than the client did.
      // Re-reading the fix lets the user see that and walk closer.
      _acquireFix();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: const Text('Monthly check-in'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: _submitting
              ? null
              : () {
                  Haptics.tap();
                  Navigator.of(context).pop();
                },
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Text(
              _tree.displayName,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppColors.forest,
                  ),
            ).animate().fadeIn().slideY(begin: 0.2, end: 0),
            const SizedBox(height: 6),
            Text(
              'Walk within ${Tunables.verifyRadiusM.round()} m of the tree, '
              'then take a photo.',
              style: const TextStyle(
                fontSize: 13,
                height: 1.45,
                fontWeight: FontWeight.w500,
                color: AppColors.inkSoft,
              ),
            ).animate(delay: 80.ms).fadeIn(),
            const SizedBox(height: 22),

            _ProximityCard(
              locating: _locating,
              distance: _distance,
              accuracy: _accuracy,
              error: _locationError,
              inRadius: _inRadius,
              accurateEnough: _accurateEnough,
              onRetry: _acquireFix,
            ),

            const SizedBox(height: 20),

            TextField(
              controller: _height,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(3),
              ],
              decoration: InputDecoration(
                labelText: 'Height in cm',
                prefixIcon: const Icon(Icons.straighten_rounded),
                helperText: _tree.heightCm > 0
                    ? 'Last recorded: ${_tree.heightCm} cm'
                    : 'Roughly how tall is it now?',
              ),
            ),

            const SizedBox(height: 26),

            FilledButton.icon(
              onPressed: _canCapture ? _captureAndSubmit : null,
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
              label: Text(_submitting ? 'Submitting\u2026' : 'Take the photo'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProximityCard extends StatelessWidget {
  const _ProximityCard({
    required this.locating,
    required this.distance,
    required this.accuracy,
    required this.error,
    required this.inRadius,
    required this.accurateEnough,
    required this.onRetry,
  });

  final bool locating;
  final double? distance;
  final double? accuracy;
  final String? error;
  final bool inRadius;
  final bool accurateEnough;
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
            OutlinedButton(
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    }

    final ready = inRadius && accurateEnough;
    final d = distance;

    // Fills as the user closes in, so walking toward the tree gives feedback.
    final progress = d == null
        ? 0.0
        : (1 - (d / (Tunables.verifyRadiusM * 4))).clamp(0.0, 1.0);

    return DharaCard(
      gradient: ready ? AppColors.treeGradient : null,
      child: Column(
        children: [
          Row(
            children: [
              ProgressRing(
                progress: progress,
                size: 62,
                thickness: 6,
                color: ready ? Colors.white : AppColors.amber,
                track: ready
                    ? Colors.white.withValues(alpha: 0.25)
                    : AppColors.surfaceMuted,
                child: locating
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: ready ? Colors.white : AppColors.green,
                        ),
                      )
                    : Icon(
                        ready
                            ? Icons.check_rounded
                            : Icons.directions_walk_rounded,
                        color: ready ? Colors.white : AppColors.amber,
                        size: 24,
                      ),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      locating
                          ? 'Finding you\u2026'
                          : d == null
                              ? 'Location unknown'
                              : ready
                                  ? 'You are at the tree'
                                  : inRadius
                                      ? 'Waiting for a better signal'
                                      : 'Walk closer',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: ready ? Colors.white : AppColors.forest,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      d == null
                          ? 'Hold still for a moment'
                          : '${d.round()} m away'
                              '${accuracy == null ? '' : ' \u00B7 \u00B1${accuracy!.round()} m'}',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: ready
                            ? Colors.white.withValues(alpha: 0.85)
                            : AppColors.inkSoft,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (!locating && !ready) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: Text(
                  inRadius
                      ? 'Retry \u00B7 need ${Tunables.maxGpsAccuracyM.round()} m accuracy'
                      : 'Recheck my distance',
                ),
              ),
            ),
          ],
        ],
      ),
    ).animate().fadeIn();
  }
}

/// Shown over the camera so the user can see they are still in range.
class _DistanceBadge extends StatelessWidget {
  const _DistanceBadge({required this.metres});

  final double metres;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.check_circle_rounded,
            color: AppColors.lime,
            size: 15,
          ),
          const SizedBox(width: 7),
          Text(
            '${metres.round()} m from your tree',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
