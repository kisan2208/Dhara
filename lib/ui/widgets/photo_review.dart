import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/photo_history.dart';
import '../../core/services/vision.dart';
import '../../core/utils/photo_precheck.dart';
import '../../core/utils/scene_hint.dart';
import 'camera_capture.dart';

/// Opens the in-app camera, then a review step, and returns the photo path only
/// once the user confirms it. Returns null if they back out.
///
/// Drop-in replacement for `CameraCaptureScreen.push`: same arguments, same
/// return value, so the submission code and request format are unchanged.
Future<String?> capturePhotoWithReview(
  BuildContext context, {
  required String title,
  required String hint,
  Widget? overlay,
}) async {
  while (true) {
    final path = await CameraCaptureScreen.push(
      context,
      title: title,
      hint: hint,
      overlay: overlay,
    );
    if (path == null || !context.mounted) return null;

    final choice = await PhotoReviewScreen.push(context, path);
    if (!context.mounted) return null;
    switch (choice) {
      case PhotoReviewChoice.use:
        return path;
      case PhotoReviewChoice.retake:
        continue;
      case null:
        return null;
    }
  }
}

enum PhotoReviewChoice { use, retake }

typedef PhotoAnalyzer = Future<PhotoPrecheck> Function(String path);
typedef SceneAnalyzer = Future<SceneAnalysis> Function(String path);

/// Longest the review screen waits for the on-device plant hint. The labeller
/// normally answers in well under a second; this only guards against a hang.
const sceneTimeout = Duration(seconds: 5);

Future<PhotoPrecheck> _defaultAnalyzer(String path) async {
  final bytes = await File(path).readAsBytes();
  // Decoding a 12 MP capture on the UI isolate would drop frames.
  return compute(analysePhotoBytes, bytes);
}

/// Shows the captured photo with advisory notes. Nothing here blocks a
/// submission except a file that cannot be read at all.
class PhotoReviewScreen extends ConsumerStatefulWidget {
  const PhotoReviewScreen({
    super.key,
    required this.path,
    this.analyzer,
    this.sceneAnalyzer,
  });

  final String path;

  /// Injectable for tests.
  final PhotoAnalyzer? analyzer;
  final SceneAnalyzer? sceneAnalyzer;

  static Future<PhotoReviewChoice?> push(BuildContext context, String path) {
    return Navigator.of(context).push<PhotoReviewChoice>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PhotoReviewScreen(path: path),
      ),
    );
  }

  @override
  ConsumerState<PhotoReviewScreen> createState() => _PhotoReviewScreenState();
}

class _PhotoReviewScreenState extends ConsumerState<PhotoReviewScreen> {
  PhotoPrecheck? _result;
  RepeatMatch? _repeat;
  SceneAnalysis? _scene;
  Timer? _sceneTimer;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _runScene();
    _run();
  }

  @override
  void dispose() {
    _sceneTimer?.cancel();
    super.dispose();
  }

  /// The on-device plant hint loads on its own, so the quality notes never
  /// wait for ML Kit. On-device only. A failure or a labeller that never
  /// answers becomes "unavailable"; it can never block or hang the screen.
  void _runScene() {
    void finish(SceneAnalysis s) {
      _sceneTimer?.cancel();
      _sceneTimer = null;
      if (mounted && _scene == null) setState(() => _scene = s);
    }

    _sceneTimer = Timer(sceneTimeout, () => finish(SceneAnalysis.unavailable));
    Future<SceneAnalysis>.sync(
      () => (widget.sceneAnalyzer ?? ref.read(visionProvider).analyseScene)(
        widget.path,
      ),
    ).then(finish, onError: (_) => finish(SceneAnalysis.unavailable));
  }

  Future<void> _run() async {
    try {
      final result = await (widget.analyzer ?? _defaultAnalyzer)(widget.path);
      final repeat = await ref
          .read(photoHistoryProvider)
          .findRepeat(result.phash);
      if (!mounted) return;
      setState(() {
        _result = result;
        _repeat = repeat;
      });
    } catch (_) {
      // If the advisory check itself fails, let the user continue; the server
      // does the real validation.
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _use() async {
    final hash = _result?.phash ?? '';
    await ref.read(photoHistoryProvider).remember(hash);
    if (mounted) Navigator.of(context).pop(PhotoReviewChoice.use);
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final scheme = Theme.of(context).colorScheme;
    final waiting = result == null && !_failed;
    final canUse = _failed || (result != null && result.readable);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Check your photo'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Capped so the advisory notes below stay visible without
                  // scrolling on short or wide screens.
                  Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * 0.4,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AspectRatio(
                          aspectRatio: 3 / 4,
                          child: Image.file(
                            File(widget.path),
                            fit: BoxFit.cover,
                            semanticLabel: 'Photo you just took',
                            errorBuilder: (_, _, _) => Container(
                              color: scheme.surfaceContainerHighest,
                              alignment: Alignment.center,
                              child: const Icon(
                                Icons.broken_image_outlined,
                                size: 48,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (waiting)
                    const Center(child: CircularProgressIndicator())
                  else ...[
                    if (_repeat != null) _NoteTile(note: _repeatNote(_repeat!)),
                    if (_scene != null) _NoteTile(note: sceneNote(_scene!)),
                    if (result != null)
                      for (final n in result.notes) _NoteTile(note: n),
                    if (result != null &&
                        result.notes.isEmpty &&
                        _repeat == null)
                      const _NoteTile(
                        note: PrecheckNote(
                          'ok',
                          NoteLevel.info,
                          'Nothing stood out on this phone. The final check '
                              'happens on our server.',
                        ),
                      ),
                    if (result != null && result.readable)
                      _Details(result: result),
                    const SizedBox(height: 4),
                    Text(
                      'These notes are hints only. They do not prove or disprove '
                      'that a photo is genuine.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          Navigator.of(context).pop(PhotoReviewChoice.retake),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retake'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: canUse ? _use : null,
                      icon: const Icon(Icons.check),
                      label: const Text('Use photo'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  PrecheckNote _repeatNote(RepeatMatch m) => PrecheckNote(
    'repeat_local',
    NoteLevel.warning,
    'This looks very similar to a photo you already used on '
        '${m.usedAt.day}/${m.usedAt.month}/${m.usedAt.year}. Reused photos '
        'are rejected, so take a fresh one of the tree as it looks today.',
  );
}

class _NoteTile extends StatelessWidget {
  const _NoteTile({required this.note});

  final PrecheckNote note;

  @override
  Widget build(BuildContext context) {
    final warn = note.level == NoteLevel.warning;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            warn ? Icons.warning_amber_rounded : Icons.info_outline,
            size: 20,
            color: warn ? scheme.error : scheme.primary,
            semanticLabel: warn ? 'Warning' : 'Note',
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(note.message)),
        ],
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.result});

  final PhotoPrecheck result;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      '${result.width}\u00d7${result.height} px, ${(result.bytes / 1024).round()} KB',
      if (result.cameraModel != null) 'Camera: ${result.cameraModel}',
      if (result.exifCapturedAt != null)
        'Stored time: ${result.exifCapturedAt}',
      if (result.hasGps) 'Contains location metadata',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        lines.join('\n'),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

/// Wording for the on-device scene hint. Deliberately modest: it is a coarse
/// guess, it cannot tell a sapling from a mature tree or show anything was
/// planted, and it never blocks submitting.
PrecheckNote sceneNote(SceneAnalysis scene) {
  switch (scene.hint) {
    case PlantHint.plantLikely:
      return const PrecheckNote(
        'scene_plant_likely',
        NoteLevel.info,
        'This phone sees a plant or tree in the photo. That is only a rough '
            'guess: it cannot tell a sapling from a mature tree or show that '
            'you planted it.',
      );
    case PlantHint.unrelatedSuspected:
      final seen = scene.topLabels.isEmpty
          ? ''
          : ' It looks more like: ${scene.topLabels.first}.';
      return PrecheckNote(
        'scene_unrelated',
        NoteLevel.warning,
        'This photo may not show a plant.$seen If you are photographing a '
            'tree or sapling, retake it with the plant filling more of the '
            'frame. You can still use it; a person may review it.',
      );
    case PlantHint.uncertain:
      return const PrecheckNote(
        'scene_uncertain',
        NoteLevel.info,
        'This phone could not tell clearly whether a plant is in the photo. '
            'Getting the whole plant and the ground in frame helps.',
      );
    case PlantHint.analysisUnavailable:
      return const PrecheckNote(
        'scene_unavailable',
        NoteLevel.info,
        'The on-device plant check is not available right now. The final '
            'check happens on our server.',
      );
  }
}
