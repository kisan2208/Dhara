import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dhara/core/services/photo_history.dart';
import 'package:dhara/core/services/vision.dart';
import 'package:dhara/core/utils/photo_precheck.dart';
import 'package:dhara/core/utils/scene_hint.dart';
import 'package:dhara/ui/widgets/photo_review.dart';

ScoredLabel _l(String n, double c) => ScoredLabel(n, c);

void main() {
  group('classifyScene', () {
    test('plant and tree labels give PLANT_LIKELY with categories', () {
      final r = classifyScene([
        _l('Tree', 0.9),
        _l('Plant', 0.8),
        _l('Sky', 0.6),
      ]);
      expect(r.hint, PlantHint.plantLikely);
      expect(
        r.categories,
        containsAll({
          SceneCategory.tree,
          SceneCategory.plant,
          SceneCategory.naturalOutdoor,
        }),
      );
      expect(r.topLabels.first, 'Tree');
    });

    test('vegetation labels count (grass, soil)', () {
      final r = classifyScene([_l('Soil', 0.7)]);
      expect(r.hint, PlantHint.plantLikely);
      expect(r.categories, {SceneCategory.vegetation});
    });

    test('a confident non-plant scene is UNRELATED_IMAGE_SUSPECTED', () {
      final r = classifyScene([_l('Wall', 0.92), _l('Room', 0.5)]);
      expect(r.hint, PlantHint.unrelatedSuspected);
      expect(r.topLabels.first, 'Wall');
    });

    test('a screen stronger than the plant signal is suspected unrelated', () {
      expect(
        classifyScene([_l('Screenshot', 0.9), _l('Plant', 0.5)]).hint,
        PlantHint.unrelatedSuspected,
      );
      // ...but a strong plant beats a weak screen label.
      expect(
        classifyScene([_l('Tree', 0.9), _l('Screen', 0.65)]).hint,
        PlantHint.plantLikely,
      );
    });

    test('weak or mixed evidence is UNCERTAIN, never unrelated', () {
      expect(classifyScene([_l('Plant', 0.45)]).hint, PlantHint.uncertain);
      expect(classifyScene([_l('Sky', 0.8)]).hint, PlantHint.uncertain);
      expect(classifyScene([_l('Table', 0.5)]).hint, PlantHint.uncertain);
      expect(classifyScene(const []).hint, PlantHint.uncertain);
    });

    test('label matching is case-insensitive and trims', () {
      expect(classifyScene([_l('  TREE ', 0.8)]).hint, PlantHint.plantLikely);
    });
  });

  group('Vision.analyseScene', () {
    test('uses the label source and reports plant-like', () async {
      final v = Vision(labelSource: (_) async => [_l('Tree', 0.9)]);
      expect((await v.analyseScene('/p.jpg')).hint, PlantHint.plantLikely);
    });

    test(
      'a failing labeller is ANALYSIS_UNAVAILABLE, not an exception',
      () async {
        final v = Vision(
          labelSource: (_) async => throw StateError('model missing'),
        );
        final r = await v.analyseScene('/p.jpg');
        expect(r.hint, PlantHint.analysisUnavailable);
      },
    );

    test(
      'labels the same photo once; checkPlant reuses it unchanged',
      () async {
        var calls = 0;
        final v = Vision(
          labelSource: (_) async {
            calls++;
            return [_l('Tree', 0.9)];
          },
        );
        await v.analyseScene('/a.jpg');
        final check = await v.checkPlant('/a.jpg');
        expect(calls, 1);
        expect(check.isPlant, isTrue);
        expect(check.confidence, 0.9);
        expect(check.labels, ['Tree:0.90']);
        await v.analyseScene('/b.jpg');
        expect(calls, 2);
      },
    );

    test(
      'checkPlant keeps its old failure behaviour (empty, no throw)',
      () async {
        final v = Vision(labelSource: (_) async => throw StateError('x'));
        final check = await v.checkPlant('/p.jpg');
        expect(check.isPlant, isFalse);
        expect(check.confidence, 0);
      },
    );
  });

  group('review screen scene note', () {
    const okPhoto = PhotoPrecheck(
      readable: true,
      notes: [],
      phash: 'abcdef0123456789',
    );

    Widget host(
      SceneAnalyzer scene,
      ValueChanged<PhotoReviewChoice?> onResult,
    ) {
      return ProviderScope(
        overrides: [photoHistoryProvider.overrideWithValue(PhotoHistory())],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  onResult(
                    await Navigator.of(context).push<PhotoReviewChoice>(
                      MaterialPageRoute(
                        builder: (_) => PhotoReviewScreen(
                          path: '/no/such.jpg',
                          analyzer: (_) async => okPhoto,
                          sceneAnalyzer: scene,
                        ),
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
    }

    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<void> open(WidgetTester t) async {
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
    }

    testWidgets('plant-like shows a modest info note', (t) async {
      await t.pumpWidget(
        host(
          (_) async => const SceneAnalysis(hint: PlantHint.plantLikely),
          (_) {},
        ),
      );
      await open(t);
      expect(find.textContaining('rough guess'), findsOneWidget);
    });

    testWidgets('unrelated shows a warning but Use photo stays enabled', (
      t,
    ) async {
      PhotoReviewChoice? got;
      await t.pumpWidget(
        host(
          (_) async => const SceneAnalysis(
            hint: PlantHint.unrelatedSuspected,
            topLabels: ['Wall'],
          ),
          (c) => got = c,
        ),
      );
      await open(t);
      expect(find.textContaining('may not show a plant'), findsOneWidget);
      expect(find.textContaining('looks more like: Wall'), findsOneWidget);
      await t.tap(find.text('Use photo'));
      await t.pumpAndSettle();
      expect(got, PhotoReviewChoice.use);
    });

    testWidgets('uncertain shows an info note', (t) async {
      await t.pumpWidget(
        host(
          (_) async => const SceneAnalysis(hint: PlantHint.uncertain),
          (_) {},
        ),
      );
      await open(t);
      expect(find.textContaining('could not tell clearly'), findsOneWidget);
    });

    testWidgets('unavailable model shows a note and does not block', (t) async {
      await t.pumpWidget(host((_) async => SceneAnalysis.unavailable, (_) {}));
      await open(t);
      expect(find.textContaining('not available right now'), findsOneWidget);
      final use = t.widget<FilledButton>(
        find.ancestor(
          of: find.text('Use photo'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(use.onPressed, isNotNull);
    });

    testWidgets('an analyzer that throws is treated as unavailable', (t) async {
      await t.pumpWidget(host((_) => Future.error('boom'), (_) {}));
      await open(t);
      expect(find.textContaining('not available right now'), findsOneWidget);
    });

    testWidgets('a labeller that never answers times out to unavailable', (
      t,
    ) async {
      await t.pumpWidget(
        host((_) => Completer<SceneAnalysis>().future, (_) {}),
      );
      await open(t);
      // Quality notes are shown without waiting for the plant hint.
      expect(find.text('Use photo'), findsOneWidget);
      expect(find.textContaining('not available right now'), findsNothing);
      await t.pump(sceneTimeout + const Duration(milliseconds: 100));
      await t.pumpAndSettle();
      expect(find.textContaining('not available right now'), findsOneWidget);
    });

    testWidgets('Retake still works alongside the scene note', (t) async {
      PhotoReviewChoice? got;
      await t.pumpWidget(
        host(
          (_) async => const SceneAnalysis(hint: PlantHint.unrelatedSuspected),
          (c) => got = c,
        ),
      );
      await open(t);
      await t.tap(find.text('Retake'));
      await t.pumpAndSettle();
      expect(got, PhotoReviewChoice.retake);
    });
  });
}
