import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:dhara/core/services/vision.dart';
import 'package:dhara/core/utils/photo_precheck.dart';
import 'package:dhara/core/utils/scene_hint.dart';
import 'package:dhara/dev/treeguard_bench.dart';
import 'package:dhara/dev/treeguard_bench_screen.dart';

ScoredLabel _l(String n, double c) => ScoredLabel(n, c);

/// Real headroom for `runBenchOne`'s genuine OS file I/O (`File.readAsBytes()`)
/// plus decoding/analysing two tiny JPEGs, used inside `tester.runAsync()`
/// below. Neither step is driven by the fake test clock, so this is a timing
/// race rather than a deterministic wait; 200ms was observed to lose that
/// race once (cause not reproduced in 8 further isolated and full-file runs,
/// so likely a transient load spike rather than a change in behaviour). The
/// actual work here is low-single-digit milliseconds even cold, so this
/// margin stays effectively instant for a human while giving far more room.
const _realIoHeadroom = Duration(milliseconds: 1500);

/// A small, decodable, non-blurry JPEG — same recipe as photo_precheck_test.
Uint8List _sharpJpeg({int w = 640, int h = 480}) {
  final rnd = math.Random(7);
  final im = img.Image(width: w, height: h);
  for (final p in im) {
    final v = 60 + rnd.nextInt(130);
    p
      ..r = v
      ..g = v
      ..b = v;
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: 95));
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('treeguard_bench_test');

File _writeFile(Directory dir, String name, List<int> bytes) {
  final f = File('${dir.path}/$name');
  f.writeAsBytesSync(bytes);
  return f;
}

void main() {
  group('runBenchOne / runBenchAll', () {
    test(
      'a decodable photo with plant labels yields PLANT_LIKELY, no error',
      () async {
        final dir = _tempDir();
        final f = _writeFile(dir, 'tree.jpg', _sharpJpeg());
        final vision = Vision(labelSource: (_) async => [_l('Tree', 0.9)]);

        final r = await runBenchOne(f, vision);

        expect(r.fileName, 'tree.jpg');
        expect(r.hint, PlantHint.plantLikely);
        expect(r.labels.single.label, 'Tree');
        expect(r.labels.single.confidence, 0.9);
        expect(r.categories, contains(SceneCategory.tree));
        expect(r.qualityReadable, isTrue);
        expect(r.elapsedMs, greaterThanOrEqualTo(0));
        expect(r.hasError, isFalse);
        expect(r.fileSizeBytes, greaterThan(0));
      },
    );

    test(
      'confident non-plant labels yield UNRELATED_IMAGE_SUSPECTED',
      () async {
        final dir = _tempDir();
        final f = _writeFile(dir, 'wall.jpg', _sharpJpeg());
        final vision = Vision(labelSource: (_) async => [_l('Wall', 0.92)]);

        final r = await runBenchOne(f, vision);
        expect(r.hint, PlantHint.unrelatedSuspected);
      },
    );

    test('no labels yields UNCERTAIN, never unrelated', () async {
      final dir = _tempDir();
      final f = _writeFile(dir, 'blank.jpg', _sharpJpeg());
      final vision = Vision(labelSource: (_) async => const []);

      final r = await runBenchOne(f, vision);
      expect(r.hint, PlantHint.uncertain);
    });

    test('a labelling failure is reported as an error and ANALYSIS_UNAVAILABLE, '
        'but the quality check still runs independently', () async {
      final dir = _tempDir();
      final f = _writeFile(dir, 'ok.jpg', _sharpJpeg());
      final vision = Vision(
        labelSource: (_) async => throw StateError('no model'),
      );

      final r = await runBenchOne(f, vision);
      expect(r.hint, PlantHint.analysisUnavailable);
      expect(r.hasError, isTrue);
      expect(r.error, contains('labelling failed'));
      // The quality check used real, valid bytes and did not depend on ML Kit.
      expect(r.qualityReadable, isTrue);
    });

    test(
      'a corrupt image file is unreadable but labelling still runs',
      () async {
        final dir = _tempDir();
        final f = _writeFile(dir, 'bad.jpg', [1, 2, 3, 4, 5]);
        final vision = Vision(labelSource: (_) async => [_l('Tree', 0.9)]);

        final r = await runBenchOne(f, vision);
        expect(r.qualityReadable, isFalse);
        expect(r.qualityNotes, contains('unreadable'));
        expect(r.hint, PlantHint.plantLikely);
        expect(r.hasError, isFalse);
      },
    );

    test('runBenchAll preserves order and count', () async {
      final dir = _tempDir();
      final a = _writeFile(dir, 'a.jpg', _sharpJpeg());
      final b = _writeFile(dir, 'b.jpg', _sharpJpeg());
      final vision = Vision(labelSource: (_) async => const []);

      final results = await runBenchAll([a, b], vision);
      expect(results.map((r) => r.fileName), ['a.jpg', 'b.jpg']);
    });
  });

  group('summarizeBench', () {
    test('counts and average are correct', () {
      const results = [
        BenchResult(
          fileName: 'a',
          filePath: 'a',
          fileSizeBytes: 1,
          hint: PlantHint.plantLikely,
          labels: [],
          categories: {},
          qualityReadable: true,
          qualityNotes: [],
          elapsedMs: 10,
        ),
        BenchResult(
          fileName: 'b',
          filePath: 'b',
          fileSizeBytes: 1,
          hint: PlantHint.unrelatedSuspected,
          labels: [],
          categories: {},
          qualityReadable: false,
          qualityNotes: ['unreadable'],
          elapsedMs: 20,
          error: 'quality check failed: x',
        ),
      ];
      final s = summarizeBench(results);
      expect(s.total, 2);
      expect(s.counts[PlantHint.plantLikely], 1);
      expect(s.counts[PlantHint.unrelatedSuspected], 1);
      expect(s.counts[PlantHint.uncertain], 0);
      expect(s.averageMs, 15.0);
      expect(s.errorCount, 1);
      expect(s.unreadableCount, 1);
    });

    test('an empty result list does not divide by zero', () {
      final s = summarizeBench(const []);
      expect(s.total, 0);
      expect(s.averageMs, 0);
      expect(s.errorCount, 0);
    });
  });

  group('export formats', () {
    const results = [
      BenchResult(
        fileName: 'has, comma.jpg',
        filePath: '/x/has, comma.jpg',
        fileSizeBytes: 100,
        hint: PlantHint.plantLikely,
        labels: [ScoredLabel('Tree', 0.91)],
        categories: {SceneCategory.tree},
        qualityReadable: true,
        qualityNotes: ['maybe_blurry'],
        elapsedMs: 42,
      ),
    ];

    test('resultsToCsv escapes commas and is one row per result', () {
      final csv = resultsToCsv(results);
      final lines = csv.split('\n');
      expect(lines.first, startsWith('fileName,fileSizeBytes,hint'));
      expect(lines.length, 2);
      expect(lines[1], contains('"has, comma.jpg"'));
      expect(lines[1], contains('Tree:0.91'));
      expect(lines[1], contains('plantLikely'));
    });

    test('resultsToJson round-trips through jsonDecode', () {
      final jsonStr = resultsToJson(results);
      final decoded = jsonDecode(jsonStr) as List;
      expect(decoded, hasLength(1));
      final row = decoded.single as Map;
      expect(row['fileName'], 'has, comma.jpg');
      expect(row['hint'], 'plantLikely');
      expect((row['labels'] as List).single, {
        'label': 'Tree',
        'confidence': 0.91,
      });
      expect(row['qualityNotes'], ['maybe_blurry']);
    });

    test('exportResultsToDir writes the right extension and content', () async {
      final dir = _tempDir();
      final fixedNow = DateTime(2026, 1, 2, 3, 4, 5);

      final csvFile = await exportResultsToDir(
        dir,
        results,
        asJson: false,
        now: fixedNow,
      );
      expect(csvFile.path, endsWith('.csv'));
      expect(await csvFile.readAsString(), resultsToCsv(results));

      final jsonFile = await exportResultsToDir(
        dir,
        results,
        asJson: true,
        now: fixedNow,
      );
      expect(jsonFile.path, endsWith('.json'));
      expect(await jsonFile.readAsString(), resultsToJson(results));
    });
  });

  group('listImagesInDir', () {
    test('keeps only recognised image extensions, sorted by name', () {
      final dir = _tempDir();
      _writeFile(dir, 'b.png', [1]);
      _writeFile(dir, 'a.jpg', [1]);
      _writeFile(dir, 'notes.txt', [1]);
      _writeFile(dir, 'c.JPEG', [1]); // case-insensitive

      final names = listImagesInDir(
        dir,
      ).map((f) => f.uri.pathSegments.last).toList();
      expect(names, ['a.jpg', 'b.png', 'c.JPEG']);
    });

    test('a directory that does not exist yields an empty list', () {
      expect(listImagesInDir(Directory('/no/such/dir')), isEmpty);
    });
  });

  group('TreeGuardBenchScreen', () {
    // Widget tests avoid the real `compute()` isolate (which races the fake
    // test clock inside pumpAndSettle) by running the quality check inline;
    // it is still the real, unmodified `analysePhotoBytes`.
    Future<PhotoPrecheck> inlineQualityCheck(Uint8List bytes) async =>
        analysePhotoBytes(bytes);
    Widget host(Vision vision, TreeGuardBenchScreen screen) => ProviderScope(
      overrides: [visionProvider.overrideWithValue(vision)],
      child: MaterialApp(home: screen),
    );

    testWidgets('lists available images, all selected by default', (t) async {
      final dir = _tempDir();
      final f = _writeFile(dir, 'tree.jpg', _sharpJpeg());
      await t.pumpWidget(
        host(
          Vision(labelSource: (_) async => const []),
          TreeGuardBenchScreen(imageLister: () async => [f]),
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('tree.jpg'), findsOneWidget);
      final checkbox = t.widget<CheckboxListTile>(
        find.byType(CheckboxListTile),
      );
      expect(checkbox.value, isTrue);
    });

    testWidgets('running selected files shows results and a matching summary', (
      t,
    ) async {
      final dir = _tempDir();
      final f1 = _writeFile(dir, 'tree.jpg', _sharpJpeg());
      final f2 = _writeFile(dir, 'wall.jpg', _sharpJpeg());
      final vision = Vision(
        labelSource: (path) async =>
            path.endsWith('tree.jpg') ? [_l('Tree', 0.9)] : [_l('Wall', 0.9)],
      );
      await t.pumpWidget(
        host(
          vision,
          TreeGuardBenchScreen(
            imageLister: () async => [f1, f2],
            qualityCheck: inlineQualityCheck,
          ),
        ),
      );
      await t.pumpAndSettle();

      await t.runAsync(() async {
        await t.tap(find.text('Run selected'));
        // File.readAsBytes() is genuine OS I/O, not driven by the fake test
        // clock, so pumpAndSettle alone cannot be relied on to wait for it.
        await Future<void>.delayed(_realIoHeadroom);
      });
      await t.pumpAndSettle();

      expect(find.textContaining('Total: 2'), findsOneWidget);
      expect(find.textContaining('Errors: 0'), findsOneWidget);
      expect(find.textContaining('Unreadable: 0'), findsOneWidget);
      expect(find.text('plantLikely: 1'), findsOneWidget);
      expect(find.text('unrelatedSuspected: 1'), findsOneWidget);
    });

    testWidgets(
      'a per-file failure is shown as an error without crashing the screen',
      (t) async {
        final dir = _tempDir();
        final bad = _writeFile(dir, 'bad.jpg', [1, 2, 3]);
        final vision = Vision(labelSource: (_) async => throw StateError('x'));
        await t.pumpWidget(
          host(
            vision,
            TreeGuardBenchScreen(
              imageLister: () async => [bad],
              qualityCheck: inlineQualityCheck,
            ),
          ),
        );
        await t.pumpAndSettle();

        await t.runAsync(() async {
          await t.tap(find.text('Run selected'));
          await Future<void>.delayed(_realIoHeadroom);
        });
        await t.pumpAndSettle();

        expect(find.textContaining('Error:'), findsOneWidget);
      },
    );

    testWidgets('export calls the injected exporter and shows the saved path', (
      t,
    ) async {
      final dir = _tempDir();
      final f = _writeFile(dir, 'tree.jpg', _sharpJpeg());
      File? exported;
      var exportedAsJson = false;
      await t.pumpWidget(
        host(
          Vision(labelSource: (_) async => [_l('Tree', 0.9)]),
          TreeGuardBenchScreen(
            imageLister: () async => [f],
            qualityCheck: inlineQualityCheck,
            exporter: (results, {required asJson}) async {
              exportedAsJson = asJson;
              exported = File('${dir.path}/out.json');
              return exported!;
            },
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.runAsync(() async {
        await t.tap(find.text('Run selected'));
        await Future<void>.delayed(_realIoHeadroom);
      });
      await t.pumpAndSettle();

      await t.tap(find.text('Export JSON'));
      await t.pump();
      expect(exportedAsJson, isTrue);
      expect(find.textContaining('Saved to'), findsOneWidget);
      expect(exported, isNotNull);
    });

    testWidgets('a listing failure is shown, not a crash', (t) async {
      await t.pumpWidget(
        host(
          Vision(labelSource: (_) async => const []),
          TreeGuardBenchScreen(
            imageLister: () async => throw StateError('no folder'),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.textContaining('Could not list images'), findsOneWidget);
    });
  });
}
