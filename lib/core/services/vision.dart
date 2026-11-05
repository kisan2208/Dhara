import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../utils/scene_hint.dart';

/// Result of asking "is there actually a plant in this photo?"
class PlantCheck {
  const PlantCheck({
    required this.confidence,
    required this.labels,
    required this.isPlant,
    this.topLabel = '',
  });

  final double confidence;
  final List<String> labels;
  final bool isPlant;
  final String topLabel;

  static const empty = PlantCheck(confidence: 0, labels: [], isPlant: false);
}

/// On-device vision checks.
///
/// The pretrained ML Kit image labeller is deliberate: it costs nothing, runs
/// offline, and rules out the obvious cheats (a photo of a wall, a screenshot,
/// a pet). Training a custom classifier only becomes worthwhile once there are
/// a few thousand reviewed submissions to learn from, and even then the real
/// deterrent is credit vesting rather than the model.
class Vision {
  /// [labelSource] replaces the ML Kit labeller; used by tests.
  Vision({Future<List<ScoredLabel>> Function(String path)? labelSource})
    : _source = labelSource;

  final Future<List<ScoredLabel>> Function(String path)? _source;

  // The review screen and the later submission both label the same photo; the
  // last result is kept so ML Kit runs once per photo, not twice.
  String? _cachedPath;
  List<ScoredLabel>? _cachedLabels;

  Future<List<ScoredLabel>> _labelsFor(String path) async {
    if (_cachedPath == path && _cachedLabels != null) return _cachedLabels!;
    final labels = await (_source ?? _mlKitLabels)(path);
    _cachedPath = path;
    _cachedLabels = labels;
    return labels;
  }

  Future<List<ScoredLabel>> _mlKitLabels(String path) async {
    final results = await _labels.processImage(InputImage.fromFilePath(path));
    return [for (final r in results) ScoredLabel(r.label, r.confidence)];
  }

  /// Raw ML Kit labels (or the injected [labelSource]) for a photo, with their
  /// confidence scores.
  ///
  /// Exposed for the debug-only TreeGuard test bench (`lib/dev/`); production
  /// code uses [analyseScene] or [checkPlant] instead. Shares the one-photo
  /// cache with both, so calling this alongside them for the same path never
  /// re-runs ML Kit twice.
  Future<List<ScoredLabel>> rawLabels(String imagePath) =>
      _labelsFor(imagePath);

  /// Advisory scene hint for the photo review screen. Never throws.
  Future<SceneAnalysis> analyseScene(String imagePath) async {
    try {
      final labels = await _labelsFor(imagePath);
      final scene = classifyScene(labels);
      // Debug builds only: lets on-device testing record the raw labels.
      if (kDebugMode) {
        debugPrint(
          'TreeGuard scene: ${scene.hint.name} labels=['
          '${labels.map((l) => '${l.label}:${l.confidence.toStringAsFixed(2)}').join(', ')}]',
        );
      }
      return scene;
    } catch (e) {
      if (kDebugMode) debugPrint('TreeGuard scene: unavailable ($e)');
      return SceneAnalysis.unavailable;
    }
  }

  // A generous threshold: ML Kit's own labels are the coarse filter, and the
  // server applies the real cutoff from app_config.
  ImageLabeler? _labeler;
  TextRecognizer? _recognizer;

  ImageLabeler get _labels => _labeler ??= ImageLabeler(
    options: ImageLabelerOptions(confidenceThreshold: 0.4),
  );

  TextRecognizer get _text =>
      _recognizer ??= TextRecognizer(script: TextRecognitionScript.latin);

  /// Labels that indicate real vegetation in frame.
  static const _plantLabels = {
    'plant',
    'tree',
    'leaf',
    'flower',
    'grass',
    'forest',
    'woody plant',
    'flowerpot',
    'houseplant',
    'garden',
    'vegetation',
    'branch',
    'shrub',
    'soil',
    'bud',
    'sapling',
    'moss',
    'fern',
    'palm tree',
    'bamboo',
    'lawn',
    'plantation',
    'jungle',
    'nature',
    'flora',
  };

  /// Labels that suggest the photo is of a screen rather than a real scene.
  static const _screenLabels = {
    'screenshot',
    'monitor',
    'television',
    'computer',
    'laptop',
    'display',
    'mobile phone',
    'screen',
    'website',
    'text',
    'document',
    'paper',
  };

  Future<PlantCheck> checkPlant(String imagePath) async {
    try {
      final results = await _labelsFor(imagePath);
      if (results.isEmpty) return PlantCheck.empty;

      final names = <String>[];
      var best = 0.0;
      var bestLabel = '';
      var screenScore = 0.0;

      for (final label in results) {
        final name = label.label.toLowerCase();
        names.add('${label.label}:${label.confidence.toStringAsFixed(2)}');

        if (_plantLabels.contains(name) && label.confidence > best) {
          best = label.confidence;
          bestLabel = label.label;
        }
        if (_screenLabels.contains(name) && label.confidence > screenScore) {
          screenScore = label.confidence;
        }
      }

      // A photo of a screen showing a tree is not a planted tree. When the
      // screen signal is stronger than the plant signal, treat it as a fail.
      if (screenScore > 0.6 && screenScore > best) {
        return PlantCheck(
          confidence: 0,
          labels: names,
          isPlant: false,
          topLabel: 'screen',
        );
      }

      return PlantCheck(
        confidence: best,
        labels: names,
        isPlant: best > 0,
        topLabel: bestLabel,
      );
    } catch (_) {
      // A vision failure must not block a genuine submission; the server still
      // applies its own checks and can route to manual review.
      return PlantCheck.empty;
    }
  }

  /// Extracts text from a bill photo so the consumer number can be matched
  /// against what the user typed. Runs entirely on-device.
  Future<String> readText(String imagePath) async {
    try {
      final input = InputImage.fromFilePath(imagePath);
      final result = await _text.processImage(input);
      return result.text;
    } catch (_) {
      return '';
    }
  }

  /// Best-effort guess at the consumer number from OCR text, used to
  /// pre-fill the field. The server still verifies what the user submits.
  static String? guessConsumerNumber(String ocrText) {
    if (ocrText.isEmpty) return null;
    final lines = ocrText.split(RegExp(r'[\n\r]+'));
    final labelled = RegExp(
      r'(consumer|account|service|k\.?no|ca)\s*(no|number|id)?\s*[:.\-]?\s*([A-Z0-9\-]{6,20})',
      caseSensitive: false,
    );

    for (final line in lines) {
      final match = labelled.firstMatch(line);
      final captured = match?.group(3);
      if (captured != null && RegExp(r'\d').hasMatch(captured)) {
        return captured.toUpperCase();
      }
    }
    return null;
  }

  void dispose() {
    _labeler?.close();
    _recognizer?.close();
    _labeler = null;
    _recognizer = null;
  }
}

final visionProvider = Provider<Vision>((ref) {
  final vision = Vision();
  ref.onDispose(vision.dispose);
  return vision;
});
