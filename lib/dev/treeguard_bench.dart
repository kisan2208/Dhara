import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/services/vision.dart';
import '../core/utils/photo_precheck.dart';
import '../core/utils/scene_hint.dart';

/// Debug-only TreeGuard test bench.
///
/// Everything here runs on images already sitting on the device and never
/// sends anything anywhere: no Appwrite call, no upload, no network request.
/// It exists to let a developer try the on-device plant hint and photo-quality
/// checks against a batch of sample photos without using the camera one shot
/// at a time, and without touching the real submission flow.
///
/// This file is pure logic (no Flutter widgets), so it is unit tested without
/// a device. The screen that drives it is in `treeguard_bench_screen.dart`.

const imageExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.heic'};

/// Result of running both checks on one photo.
class BenchResult {
  const BenchResult({
    required this.fileName,
    required this.filePath,
    required this.fileSizeBytes,
    required this.hint,
    required this.labels,
    required this.categories,
    required this.qualityReadable,
    required this.qualityNotes,
    required this.elapsedMs,
    this.error,
  });

  final String fileName;
  final String filePath;
  final int fileSizeBytes;

  /// PLANT_LIKELY / UNRELATED_IMAGE_SUSPECTED / UNCERTAIN / ANALYSIS_UNAVAILABLE.
  final PlantHint hint;

  /// Raw ML Kit labels with their confidence, where available.
  final List<ScoredLabel> labels;
  final Set<SceneCategory> categories;

  final bool qualityReadable;

  /// Note codes from the existing quality/EXIF precheck (e.g. 'maybe_blurry').
  final List<String> qualityNotes;

  final int elapsedMs;

  /// Set when either check could not complete for this photo. Never silent:
  /// a failure always shows up here rather than being dropped.
  final String? error;

  bool get hasError => error != null;

  Map<String, Object?> toJsonMap() => {
    'fileName': fileName,
    'filePath': filePath,
    'fileSizeBytes': fileSizeBytes,
    'hint': hint.name,
    'labels': [
      for (final l in labels) {'label': l.label, 'confidence': l.confidence},
    ],
    'categories': [for (final c in categories) c.name],
    'qualityReadable': qualityReadable,
    'qualityNotes': qualityNotes,
    'elapsedMs': elapsedMs,
    'error': error,
  };
}

/// Reads a photo's bytes and runs the existing quality/EXIF precheck.
/// Injectable so tests can skip spawning a real isolate; production always
/// uses [compute], same as the live photo review screen.
typedef QualityCheck = Future<PhotoPrecheck> Function(Uint8List bytes);

Future<PhotoPrecheck> _defaultQualityCheck(Uint8List bytes) =>
    compute(analysePhotoBytes, bytes);

/// Runs the plant-hint and quality checks on one file.
///
/// The two checks are independent: a failure in one (e.g. ML Kit unavailable)
/// does not prevent the other from running, and neither can throw out of this
/// function. A photo that fails either check is reported with [error] set,
/// never dropped from the results silently.
Future<BenchResult> runBenchOne(
  File file,
  Vision vision, {
  QualityCheck? qualityCheck,
}) async {
  final stopwatch = Stopwatch()..start();
  final fileName = file.uri.pathSegments.isNotEmpty
      ? file.uri.pathSegments.last
      : file.path;

  var sizeBytes = 0;
  try {
    sizeBytes = await file.length();
  } catch (_) {
    // Reported via the empty/failed checks below; the size is cosmetic.
  }

  var hint = PlantHint.analysisUnavailable;
  var labels = const <ScoredLabel>[];
  var categories = const <SceneCategory>{};
  var readable = false;
  var notes = const <String>[];
  final errors = <String>[];

  try {
    labels = await vision.rawLabels(file.path);
    final scene = classifyScene(labels);
    hint = scene.hint;
    categories = scene.categories;
  } catch (e) {
    errors.add('labelling failed: $e');
  }

  try {
    final bytes = await file.readAsBytes();
    final quality = await (qualityCheck ?? _defaultQualityCheck)(bytes);
    readable = quality.readable;
    notes = [for (final n in quality.notes) n.code];
  } catch (e) {
    errors.add('quality check failed: $e');
  }

  stopwatch.stop();
  return BenchResult(
    fileName: fileName,
    filePath: file.path,
    fileSizeBytes: sizeBytes,
    hint: hint,
    labels: labels,
    categories: categories,
    qualityReadable: readable,
    qualityNotes: notes,
    elapsedMs: stopwatch.elapsedMilliseconds,
    error: errors.isEmpty ? null : errors.join('; '),
  );
}

/// Runs [runBenchOne] over every file, in order. Sequential on purpose: ML Kit
/// is reused across calls, and running several labellings at once would not
/// be representative of the one-photo-at-a-time production flow anyway.
Future<List<BenchResult>> runBenchAll(
  Iterable<File> files,
  Vision vision, {
  QualityCheck? qualityCheck,
}) async {
  final out = <BenchResult>[];
  for (final file in files) {
    out.add(await runBenchOne(file, vision, qualityCheck: qualityCheck));
  }
  return out;
}

class BenchSummary {
  const BenchSummary({
    required this.total,
    required this.counts,
    required this.averageMs,
    required this.errorCount,
    required this.unreadableCount,
  });

  final int total;
  final Map<PlantHint, int> counts;
  final double averageMs;
  final int errorCount;
  final int unreadableCount;
}

BenchSummary summarizeBench(List<BenchResult> results) {
  final counts = {for (final h in PlantHint.values) h: 0};
  var errorCount = 0;
  var unreadable = 0;
  var totalMs = 0;
  for (final r in results) {
    counts[r.hint] = (counts[r.hint] ?? 0) + 1;
    if (r.hasError) errorCount++;
    if (!r.qualityReadable) unreadable++;
    totalMs += r.elapsedMs;
  }
  return BenchSummary(
    total: results.length,
    counts: counts,
    averageMs: results.isEmpty ? 0 : totalMs / results.length,
    errorCount: errorCount,
    unreadableCount: unreadable,
  );
}

String _csvField(Object? v) {
  final s = v?.toString() ?? '';
  if (s.contains(',') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

String resultsToCsv(List<BenchResult> results) {
  final rows = <String>[
    [
      'fileName',
      'fileSizeBytes',
      'hint',
      'labels',
      'categories',
      'qualityReadable',
      'qualityNotes',
      'elapsedMs',
      'error',
    ].join(','),
  ];
  for (final r in results) {
    final labelsStr = r.labels
        .map((l) => '${l.label}:${l.confidence.toStringAsFixed(2)}')
        .join('|');
    final categoriesStr = r.categories.map((c) => c.name).join('|');
    final notesStr = r.qualityNotes.join('|');
    rows.add(
      [
        _csvField(r.fileName),
        r.fileSizeBytes.toString(),
        r.hint.name,
        _csvField(labelsStr),
        _csvField(categoriesStr),
        r.qualityReadable.toString(),
        _csvField(notesStr),
        r.elapsedMs.toString(),
        _csvField(r.error ?? ''),
      ].join(','),
    );
  }
  return rows.join('\n');
}

String resultsToJson(List<BenchResult> results) => const JsonEncoder.withIndent(
  '  ',
).convert([for (final r in results) r.toJsonMap()]);

/// Files with a recognised image extension in [dir], sorted by name. Pure
/// (no plugin calls), so it is unit testable with any [Directory].
List<File> listImagesInDir(Directory dir) {
  if (!dir.existsSync()) return const [];
  final files = dir.listSync().whereType<File>().where((f) {
    final lower = f.path.toLowerCase();
    return imageExtensions.any(lower.endsWith);
  }).toList()..sort((a, b) => a.path.compareTo(b.path));
  return files;
}

String _pad2(int n) => n.toString().padLeft(2, '0');

String _timestampTag(DateTime t) =>
    '${t.year}${_pad2(t.month)}${_pad2(t.day)}_'
    '${_pad2(t.hour)}${_pad2(t.minute)}${_pad2(t.second)}';

/// Writes [results] into [dir] as CSV or JSON and returns the file. Pure
/// aside from the file write, so it is unit testable with a temp directory.
Future<File> exportResultsToDir(
  Directory dir,
  List<BenchResult> results, {
  required bool asJson,
  DateTime? now,
}) async {
  final tag = _timestampTag(now ?? DateTime.now());
  final file = File(
    '${dir.path}/treeguard_bench_$tag.${asJson ? 'json' : 'csv'}',
  );
  await file.writeAsString(
    asJson ? resultsToJson(results) : resultsToCsv(results),
  );
  return file;
}

// --- The only bits that touch a plugin (path_provider) --------------------
// Not unit tested directly, same as other path_provider wrappers in this
// codebase (e.g. MediaService.cached); everything above this line is.

/// App-private folder a developer copies sample photos into, e.g. with
/// `adb push photo.jpg /storage/emulated/0/Android/data/<app id>/files/treeguard_samples/`
/// or `adb push photo.jpg` into the app's documents dir shown on the bench
/// screen. No storage permission is required because it is the app's own
/// folder, not the shared gallery.
Future<Directory> sampleImagesDir() async {
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}/treeguard_samples');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

Future<List<File>> listSampleImages() async =>
    listImagesInDir(await sampleImagesDir());

Future<File> exportResults(
  List<BenchResult> results, {
  required bool asJson,
}) async =>
    exportResultsToDir(await sampleImagesDir(), results, asJson: asJson);
