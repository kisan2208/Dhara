import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dhara/core/services/photo_history.dart';
import 'package:dhara/core/utils/photo_precheck.dart';
import 'package:dhara/ui/widgets/photo_review.dart';

/// Deterministic noise: sharp, mid-brightness.
Uint8List _sharp({int w = 640, int h = 480, String? exifTime}) {
  final rnd = math.Random(7);
  final im = img.Image(width: w, height: h);
  for (final p in im) {
    final v = 60 + rnd.nextInt(130);
    p
      ..r = v
      ..g = v
      ..b = v;
  }
  if (exifTime != null) {
    im.exif.exifIfd.data[0x9003] = img.IfdValueAscii(exifTime);
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: 95));
}

Uint8List _flat(int value, {int w = 640, int h = 480}) {
  final im = img.Image(width: w, height: h);
  for (final p in im) {
    p
      ..r = value
      ..g = value
      ..b = value;
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: 95));
}

Set<String> _codes(PhotoPrecheck r) => {for (final n in r.notes) n.code};

void main() {
  group('analysePhoto', () {
    test('a sharp, well-lit photo has no warnings', () {
      final r = analysePhoto(_sharp(), now: DateTime(2026, 11, 4));
      expect(r.readable, isTrue);
      expect(r.hasWarnings, isFalse);
      expect(r.width, 640);
      expect(r.phash, isNotEmpty);
    });

    test('garbage bytes are unreadable, not a crash', () {
      final r = analysePhoto(Uint8List.fromList(List.filled(5000, 7)));
      expect(r.readable, isFalse);
      expect(_codes(r), {'unreadable'});
      expect(analysePhoto(Uint8List(0)).readable, isFalse);
    });

    test('a flat grey image is flagged as possibly blurry', () {
      expect(_codes(analysePhoto(_flat(128))), contains('maybe_blurry'));
    });

    test('dark and overexposed photos are flagged', () {
      expect(_codes(analysePhoto(_flat(5))), contains('too_dark'));
      expect(_codes(analysePhoto(_flat(250))), contains('too_bright'));
    });

    test('a small image is flagged as low resolution', () {
      expect(_codes(analysePhoto(_sharp(w: 200, h: 150))), contains('low_resolution'));
    });

    test('missing EXIF is an info note, never a warning', () {
      final r = analysePhoto(_sharp());
      final n = r.notes.firstWhere((n) => n.code == 'no_exif');
      expect(n.level, NoteLevel.info);
      expect(r.exifCapturedAt, isNull);
    });

    test('EXIF capture time is read and compared to the clock, as info only', () {
      final bytes = _sharp(exifTime: '2026:11:04 10:00:00');
      final near = analysePhoto(bytes, now: DateTime(2026, 11, 4, 10, 5));
      expect(near.exifCapturedAt, DateTime(2026, 11, 4, 10, 0, 0));
      expect(_codes(near), isNot(contains('exif_time_offset')));

      final far = analysePhoto(bytes, now: DateTime(2026, 11, 4, 14, 0));
      final n = far.notes.firstWhere((n) => n.code == 'exif_time_offset');
      expect(n.level, NoteLevel.info);
    });

    test('parseExifDate rejects malformed values', () {
      expect(parseExifDate(null), isNull);
      expect(parseExifDate('not a date'), isNull);
      expect(parseExifDate('2026:13:40 99:99:99'), isNull);
      expect(parseExifDate('1999:01:01 00:00:00'), isNull);
      expect(parseExifDate('2026:11:04 10:30:15'), DateTime(2026, 11, 4, 10, 30, 15));
    });
  });

  group('PhotoHistory', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('flags a repeat of a remembered photo and ignores a different one', () async {
      final h = PhotoHistory();
      final a = analysePhoto(_sharp()).phash;
      final other = analysePhoto(_flat(128)).phash;
      expect(await h.findRepeat(a), isNull);
      await h.remember(a, now: DateTime(2026, 11, 1));
      final hit = await h.findRepeat(a, now: DateTime(2026, 11, 4));
      expect(hit, isNotNull);
      expect(hit!.distance, 0);
      expect(await h.findRepeat(other), isNull);
    });

    test('forgets entries past the age limit and caps the list', () async {
      final h = PhotoHistory(maxEntries: 2, maxAge: const Duration(days: 10));
      await h.remember('aaaaaaaaaaaaaaaa', now: DateTime(2026, 1, 1));
      expect(await h.findRepeat('aaaaaaaaaaaaaaaa', now: DateTime(2026, 6, 1)), isNull);
      await h.remember('bbbbbbbbbbbbbbbb', now: DateTime(2026, 6, 1));
      await h.remember('cccccccccccccccc', now: DateTime(2026, 6, 2));
      await h.remember('dddddddddddddddd', now: DateTime(2026, 6, 3));
      expect(await h.findRepeat('bbbbbbbbbbbbbbbb', now: DateTime(2026, 6, 4)), isNull);
      expect(await h.findRepeat('dddddddddddddddd', now: DateTime(2026, 6, 4)), isNotNull);
    });

    test('an empty hash is never stored or matched; corrupt storage is tolerated', () async {
      SharedPreferences.setMockInitialValues({
        'treeguard.recent_photo_hashes': ['garbage', 'x|notanumber'],
      });
      final h = PhotoHistory();
      expect(await h.findRepeat(''), isNull);
      await h.remember('');
      expect(await h.findRepeat('aaaaaaaaaaaaaaaa'), isNull);
    });
  });

  group('PhotoReviewScreen', () {
    Future<PhotoPrecheck> fake(PhotoPrecheck r) => Future.value(r);

    Widget host(PhotoAnalyzer analyzer, ValueChanged<PhotoReviewChoice?> onResult) {
      return ProviderScope(
        overrides: [photoHistoryProvider.overrideWithValue(PhotoHistory())],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  final c = await Navigator.of(context).push<PhotoReviewChoice>(
                    MaterialPageRoute(
                      builder: (_) => PhotoReviewScreen(path: '/no/such.jpg', analyzer: analyzer),
                    ),
                  );
                  onResult(c);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
    }

    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('shows warnings and lets the user keep the photo', (tester) async {
      PhotoReviewChoice? got;
      const warn = PhotoPrecheck(
        readable: true,
        notes: [PrecheckNote('maybe_blurry', NoteLevel.warning, 'May be blurry.')],
        width: 640,
        height: 480,
        phash: 'abcdef0123456789',
      );
      await tester.pumpWidget(host((_) => fake(warn), (c) => got = c));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('May be blurry.'), findsOneWidget);
      expect(find.textContaining('hints only'), findsOneWidget);
      await tester.tap(find.text('Use photo'));
      await tester.pumpAndSettle();
      expect(got, PhotoReviewChoice.use);
    });

    testWidgets('an unreadable photo cannot be used, only retaken', (tester) async {
      PhotoReviewChoice? got;
      final bad = analysePhoto(Uint8List(0));
      await tester.pumpWidget(host((_) => fake(bad), (c) => got = c));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final use = tester.widget<FilledButton>(find.ancestor(
        of: find.text('Use photo'),
        matching: find.byType(FilledButton),
      ));
      expect(use.onPressed, isNull);
      await tester.tap(find.text('Retake'));
      await tester.pumpAndSettle();
      expect(got, PhotoReviewChoice.retake);
    });

    testWidgets('warns about a locally repeated photo', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await PhotoHistory().remember('abcdef0123456789');
      const same = PhotoPrecheck(readable: true, notes: [], phash: 'abcdef0123456789');
      await tester.pumpWidget(host((_) => fake(same), (_) {}));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('similar to a photo you already used'), findsOneWidget);
    });

    testWidgets('if the advisory check itself fails the user is not blocked', (tester) async {
      await tester.pumpWidget(host((_) => Future.error('boom'), (_) {}));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final use = tester.widget<FilledButton>(find.ancestor(
        of: find.text('Use photo'),
        matching: find.byType(FilledButton),
      ));
      expect(use.onPressed, isNotNull);
    });
  });
}
