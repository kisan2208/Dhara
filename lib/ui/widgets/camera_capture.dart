import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;

import '../../core/theme/app_colors.dart';
import '../../core/utils/haptics.dart';
import 'common.dart';

/// Full-screen in-app camera that returns the captured file path.
///
/// Capture is deliberately in-app rather than through a gallery picker. A picked
/// image could be any photo off the internet; a live capture combined with the
/// perceptual hash the server stores makes reuse detectable.
class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({
    super.key,
    required this.title,
    this.hint = '',
    this.overlay,
  });

  final String title;
  final String hint;

  /// Live status shown above the shutter, e.g. the distance to the tree.
  final Widget? overlay;

  /// Pushes the camera and resolves to the captured path, or null if cancelled.
  static Future<String?> push(
    BuildContext context, {
    required String title,
    String hint = '',
    Widget? overlay,
  }) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CameraCaptureScreen(
          title: title,
          hint: hint,
          overlay: overlay,
        ),
      ),
    );
  }

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  String? _error;
  bool _busy = false;
  FlashMode _flash = FlashMode.off;

  /// True while [_start] is waiting on the camera. The first-run permission
  /// dialog sends the app inactive and back to resumed in the middle of that
  /// wait, and without this the resume started a second camera whose
  /// controller was never disposed.
  bool _starting = false;

  /// The last start failed because camera access was refused. Android stops
  /// showing the permission prompt after a second refusal, so "Try again"
  /// alone can never recover; the error view then also offers Settings.
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  /// Android reclaims the camera when the app leaves the foreground, so the
  /// controller has to be torn down and rebuilt rather than merely paused.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (state == AppLifecycleState.inactive) {
      _controller = null;
      controller?.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && controller == null) {
      _start();
    }
  }

  Future<void> _start() async {
    if (_starting) return;
    _starting = true;
    try {
      await _startCamera();
    } finally {
      _starting = false;
    }
  }

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _showError('No camera found on this device.');
        return;
      }

      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        back,
        // veryHigh is plenty: the photo is downscaled to 1440px before upload,
        // and max resolution makes capture noticeably slower on mid-range
        // phones without improving what a reviewer can see.
        ResolutionPreset.veryHigh,
        enableAudio: false,
      );

      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _error = null;
      });
    } on CameraException catch (e) {
      final denied = e.code.startsWith('CameraAccessDenied') ||
          e.code == 'CameraAccessRestricted';
      _permissionDenied = denied;
      _showError(
        denied
            ? 'Camera permission is needed to take the photo. If you chose '
                '"Don\u2019t allow", turn it on for Dhara in Settings.'
            : 'Could not start the camera. Please try again.',
      );
    } catch (_) {
      _showError('Could not start the camera. Please try again.');
    }
  }

  void _showError(String message) {
    if (mounted) setState(() => _error = message);
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final next = _flash == FlashMode.off ? FlashMode.torch : FlashMode.off;
    try {
      await controller.setFlashMode(next);
      if (mounted) setState(() => _flash = next);
      Haptics.tap();
    } catch (_) {
      // Some devices reject torch mode; leaving the flash off is fine.
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        controller.value.isTakingPicture ||
        _busy) {
      return;
    }

    setState(() => _busy = true);
    Haptics.press();

    try {
      final shot = await controller.takePicture();
      if (!mounted) return;
      Navigator.of(context).pop(shot.path);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      Haptics.error();
      showSnack(context, 'That photo did not save. Try again.', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (ready) _Preview(controller: controller)
          else if (_error != null)
            _CameraError(
              message: _error!,
              onRetry: _start,
              // Coming back from Settings resumes the app, and the lifecycle
              // handler above starts the camera again on its own.
              onOpenSettings: _permissionDenied ? openAppSettings : null,
            )
          else
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),

          // Darkened bands keep the white controls legible over a bright sky.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black54, Colors.transparent, Colors.black87],
                stops: [0, 0.32, 0.82],
              ),
            ),
            child: SizedBox.expand(),
          ),

          SafeArea(
            child: Column(
              children: [
                _TopBar(
                  title: widget.title,
                  flashOn: _flash != FlashMode.off,
                  onFlash: ready ? _toggleFlash : null,
                  onClose: () => Navigator.of(context).pop(),
                ),
                const Spacer(),
                if (widget.overlay != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                    child: widget.overlay,
                  ),
                if (widget.hint.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 0, 28, 18),
                    child: Text(
                      widget.hint,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12.5,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                _ShutterButton(
                  enabled: ready && !_busy,
                  busy: _busy,
                  onTap: _capture,
                ),
                const SizedBox(height: 26),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;

    // CameraPreview sizes itself to the sensor ratio, which rarely matches the
    // screen. Scaling it to cover avoids both letterboxing and distortion.
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: width,
        height: width * controller.value.aspectRatio,
        child: CameraPreview(controller),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.flashOn,
    required this.onFlash,
    required this.onClose,
  });

  final String title;
  final bool flashOn;
  final VoidCallback? onFlash;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close_rounded, color: Colors.white),
            onPressed: () {
              Haptics.tap();
              onClose();
            },
          ),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              flashOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
              color: flashOn ? AppColors.lime : Colors.white,
            ),
            onPressed: onFlash,
          ),
        ],
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({
    required this.enabled,
    required this.busy,
    required this.onTap,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: enabled ? 0.18 : 0.08),
          border: Border.all(
            color: Colors.white.withValues(alpha: enabled ? 0.9 : 0.3),
            width: 3.5,
          ),
        ),
        child: Center(
          child: busy
              ? const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.6,
                    color: Colors.white,
                  ),
                )
              : AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: enabled ? Colors.white : Colors.white38,
                  ),
                ),
        ),
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  const _CameraError({
    required this.message,
    required this.onRetry,
    this.onOpenSettings,
  });

  final String message;
  final VoidCallback onRetry;
  final Future<bool> Function()? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Center(
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
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13.5,
                height: 1.45,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white54),
              ),
              child: const Text('Try again'),
            ),
            if (onOpenSettings case final open?) ...[
              const SizedBox(height: 10),
              TextButton(
                onPressed: () {
                  Haptics.tap();
                  open();
                },
                style: TextButton.styleFrom(foregroundColor: AppColors.lime),
                child: const Text('Open settings'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
