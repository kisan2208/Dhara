import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/haptics.dart';
import '../../../state/items_controller.dart';
import '../../widgets/common.dart';
import 'handover_screen.dart';
import 'item_journey_screen.dart';

/// What a scanned string turned out to be.
enum ScannedKind { handoverToken, itemCode, unknown }

/// Characters a handover token is built from. Deliberately excludes I, O, 0 and
/// 1 so a code read aloud or retyped cannot be ambiguous.
const _tokenAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// Tells a sender's handover token from an item's own code.
///
/// One camera serves both flows, so this has to be unambiguous. Length is the
/// discriminator: tokens are always exactly 24 characters from [_tokenAlphabet],
/// while item codes are shorter and carry a `DH` prefix. Checking the prefix
/// alone would be wrong, since `D` and `H` are both legal token characters and a
/// token can begin with them by chance.
ScannedKind classifyScan(String raw) {
  final value = raw.trim().toUpperCase();
  if (value.isEmpty) return ScannedKind.unknown;

  if (value.length == 24 &&
      value.split('').every(_tokenAlphabet.contains)) {
    return ScannedKind.handoverToken;
  }
  if (value.startsWith('DH') && value.length >= 8 && value.length <= 64) {
    return ScannedKind.itemCode;
  }
  return ScannedKind.unknown;
}

/// The scan tab: reads item codes into a basket, or claims a sender's token.
///
/// Both directions of the chain use the same camera. Scanning a sender's code
/// completes a handover immediately; scanning items collects them so a batch can
/// be passed on in one go.
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key, this.active = true});

  /// Whether this tab is the one on screen. The camera only runs while it is.
  final bool active;

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen>
    with WidgetsBindingObserver {
  // Not auto-started: the dashboard builds every tab up front, so starting on
  // build would switch the camera on (and prompt for permission) the moment
  // the app opened, and keep it scanning behind the Home tab. [_syncCamera]
  // starts it only while this tab is visible and the app is in the foreground.
  final _controller = MobileScannerController(
    autoStart: false,
    detectionSpeed: DetectionSpeed.normal,
    formats: const [BarcodeFormat.qrCode, BarcodeFormat.code128],
  );

  /// Insertion order matters: the basket reads back in the order scanned.
  final _basket = <String>[];

  bool _torch = false;
  bool _busy = false;
  bool _foreground = true;
  bool _disposed = false;

  /// Start/stop calls are chained so a stop never races a start in progress
  /// (the controller throws if asked to start while it is still starting).
  Future<void> _cameraOps = Future<void>.value();

  /// A code that was just refused, or a token that was just claimed. The camera
  /// re-reads whatever it is pointed at several times a second, and without
  /// this a single bad code would repeat its error message in a loop.
  String? _cooldownValue;
  DateTime _cooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // After the first frame, so the MobileScanner widget has attached itself
    // to the controller before it is asked to start.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncCamera());
  }

  @override
  void didUpdateWidget(covariant ScanScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _syncCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The widget only manages the lifecycle itself when it owns the
    // controller; with our own controller it is our job.
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    _syncCamera();
  }

  void _syncCamera() {
    _cameraOps = _cameraOps.then((_) async {
      if (_disposed) return;
      final want = widget.active && _foreground;
      try {
        if (want) {
          await _controller.start();
        } else {
          await _controller.stop();
          if (_torch && mounted) setState(() => _torch = false);
        }
      } catch (_) {
        // Camera errors are shown by the scanner's own error view. Catching
        // everything also keeps this chain alive: one failed step must not
        // stop every later start/stop from running.
      }
    });
  }

  void _coolDown(String value, Duration duration) {
    _cooldownValue = value;
    _cooldownUntil = DateTime.now().add(duration);
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    // Ignore everything while a claim is in flight: the camera keeps emitting
    // the same code several times a second and would fire duplicate requests.
    if (_busy || !widget.active) return;

    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .whereType<String>()
        .firstWhere((v) => v.trim().isNotEmpty, orElse: () => '');
    if (raw.isEmpty) return;

    final value = raw.trim().toUpperCase();
    if (value == _cooldownValue && DateTime.now().isBefore(_cooldownUntil)) {
      return;
    }

    switch (classifyScan(value)) {
      case ScannedKind.handoverToken:
        await _claim(value);
      case ScannedKind.itemCode:
        if (_basket.contains(value)) return;
        Haptics.select();
        setState(() => _basket.add(value));
      case ScannedKind.unknown:
        _coolDown(value, const Duration(seconds: 3));
        Haptics.warn();
        if (mounted) {
          showSnack(context, 'That is not a Dhara code.', isError: true);
        }
    }
  }

  Future<void> _claim(String token) async {
    setState(() => _busy = true);
    Haptics.press();

    try {
      final result =
          await ref.read(itemsControllerProvider.notifier).claim(token);
      if (!mounted) return;

      Haptics.celebrate();
      await showClaimResult(context, result);
    } catch (e) {
      if (!mounted) return;
      Haptics.error();
      showSnack(context, friendlyMessage(e), isError: true);
    } finally {
      // Whether it worked or not, the same token is still in front of the
      // camera, and a second claim of it can only be refused.
      _coolDown(token, const Duration(seconds: 5));
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handOver() async {
    if (_basket.isEmpty || _busy) return;

    setState(() => _busy = true);
    Haptics.press();

    try {
      final token = await ref
          .read(itemsControllerProvider.notifier)
          .issue(List.of(_basket));
      if (!mounted) return;

      // The handed-over items are locked server-side; take them out of the
      // basket so they cannot be queued into a second handover. Items the
      // server refused stay in the basket, and the user is told why, instead
      // of disappearing as if they had been handed over too.
      final sent = token.items.toSet();
      setState(() {
        if (sent.isEmpty) {
          _basket.clear();
        } else {
          _basket.removeWhere(sent.contains);
        }
      });
      if (token.rejected.isNotEmpty) {
        Haptics.warn();
        showSnack(
          context,
          token.rejected.length == 1
              ? 'Not included: ${token.rejected.first}'
              : '${token.rejected.length} items were not included and are '
                  'still in your basket. ${token.rejected.first}',
          isError: true,
        );
      }
      await HandoverScreen.push(context, token);
    } catch (e) {
      if (!mounted) return;
      Haptics.error();
      showSnack(context, friendlyMessage(e), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _ScannerError(error: error),
            fit: BoxFit.cover,
          ),

          const _ScanFrame(),

          SafeArea(
            child: Column(
              children: [
                _TopBar(
                  torch: _torch,
                  onTorch: () async {
                    Haptics.tap();
                    await _controller.toggleTorch();
                    if (mounted) setState(() => _torch = !_torch);
                  },
                ),
                const Spacer(),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 18),
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                _BasketPanel(
                  codes: _basket,
                  busy: _busy,
                  onClear: () {
                    Haptics.tap();
                    setState(_basket.clear);
                  },
                  onRemove: (code) {
                    Haptics.select();
                    setState(() => _basket.remove(code));
                  },
                  onHandOver: _handOver,
                  onLookup: (code) => ItemJourneyScreen.push(context, code),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.torch, required this.onTorch});

  final bool torch;
  final VoidCallback onTorch;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 10, 14),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Scan',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Items to pass on, or a sender\u2019s code',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              torch ? Icons.flash_on_rounded : Icons.flash_off_rounded,
              color: torch ? AppColors.lime : Colors.white,
            ),
            onPressed: onTorch,
          ),
        ],
      ),
    );
  }
}

/// The cut-out the user aims through.
class _ScanFrame extends StatelessWidget {
  const _ScanFrame();

  @override
  Widget build(BuildContext context) {
    final side = MediaQuery.sizeOf(context).width * 0.68;

    return Center(
      child: SizedBox(
        width: side,
        height: side,
        child: Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.55),
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            // A travelling line reads as "actively scanning" without implying
            // progress toward anything.
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    height: 2.5,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          AppColors.lime,
                          Colors.transparent,
                        ],
                      ),
                    ),
                  )
                      .animate(onPlay: (c) => c.repeat(reverse: true))
                      .slideY(
                        begin: 0,
                        end: (side - 3) / 2.5,
                        duration: 1800.ms,
                        curve: Curves.easeInOut,
                      ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BasketPanel extends StatelessWidget {
  const _BasketPanel({
    required this.codes,
    required this.busy,
    required this.onClear,
    required this.onRemove,
    required this.onHandOver,
    required this.onLookup,
  });

  final List<String> codes;
  final bool busy;
  final VoidCallback onClear;
  final ValueChanged<String> onRemove;
  final VoidCallback onHandOver;
  final ValueChanged<String> onLookup;

  @override
  Widget build(BuildContext context) {
    if (codes.isEmpty) {
      return Container(
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Row(
          children: [
            Icon(Icons.qr_code_2_rounded, color: AppColors.lime, size: 22),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Point the camera at a code. Items you scan collect here so you '
                'can hand them over together.',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  height: 1.45,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ).animate().fadeIn();
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 20),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  codes.length == 1
                      ? '1 item scanned'
                      : '${codes.length} items scanned',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: AppColors.forest,
                  ),
                ),
              ),
              TextButton(
                onPressed: busy ? null : onClear,
                child: const Text('Clear'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 140),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: codes.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final code = codes[i];
                return Row(
                  children: [
                    const Icon(
                      Icons.check_circle_rounded,
                      size: 17,
                      color: AppColors.green,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        code,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.ink,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(
                        Icons.info_outline_rounded,
                        size: 17,
                        color: AppColors.inkFaint,
                      ),
                      onPressed: busy ? null : () => onLookup(code),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 17,
                        color: AppColors.inkFaint,
                      ),
                      onPressed: busy ? null : () => onRemove(code),
                    ),
                  ],
                ).animate().fadeIn().slideX(begin: 0.06, end: 0);
              },
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: busy ? null : onHandOver,
              icon: const Icon(Icons.swap_horiz_rounded, size: 19),
              label: Text(
                codes.length == 1
                    ? 'Hand over this item'
                    : 'Hand over ${codes.length} items',
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
            ),
          ),
        ],
      ),
    ).animate().fadeIn().slideY(begin: 0.2, end: 0);
  }
}

class _ScannerError extends StatelessWidget {
  const _ScannerError({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final denied =
        error.errorCode == MobileScannerErrorCode.permissionDenied;

    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(34),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.no_photography_outlined,
                color: Colors.white54,
                size: 44,
              ),
              const SizedBox(height: 16),
              Text(
                denied
                    ? 'Camera permission is needed to scan codes. Enable it for '
                        'Dhara in system settings.'
                    : 'The camera could not start. Close and reopen this tab.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13.5,
                  height: 1.45,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reports the outcome of a claim, including anything the server refused.
Future<void> showClaimResult(BuildContext context, ClaimResult result) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 70,
                height: 70,
                decoration: const BoxDecoration(
                  color: AppColors.surfaceMuted,
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: Text('\u{267B}', style: TextStyle(fontSize: 31)),
                ),
              )
                  .animate()
                  .scale(duration: 420.ms, curve: Curves.easeOutBack)
                  .fadeIn(),
              const SizedBox(height: 18),
              Text(
                result.movedCount == 1
                    ? 'Item received'
                    : '${result.movedCount} items received',
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: AppColors.forest,
                ),
              ).animate(delay: 80.ms).fadeIn(),
              if (result.creditsAwardedToSender > 0) ...[
                const SizedBox(height: 10),
                StatusPill(
                  label:
                      '${result.creditsAwardedToSender} credits paid to the sender',
                  color: AppColors.green,
                  icon: Icons.card_giftcard_rounded,
                ),
              ],
              const SizedBox(height: 12),
              Text(
                'Custody now sits with you as '
                '${result.receiverRole.label.toLowerCase()}.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  fontWeight: FontWeight.w500,
                  color: AppColors.inkSoft,
                ),
              ),
              if (result.hasSkipped) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    color: AppColors.amber.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Not transferred',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: AppColors.forest,
                        ),
                      ),
                      const SizedBox(height: 6),
                      ...result.skipped.map(
                        (s) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            s,
                            style: const TextStyle(
                              fontSize: 11.5,
                              height: 1.4,
                              fontWeight: FontWeight.w600,
                              color: AppColors.inkSoft,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    Haptics.tap();
                    Navigator.of(context).pop();
                  },
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
