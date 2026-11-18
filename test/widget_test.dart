import 'package:flutter_test/flutter_test.dart';

import 'package:dhara/core/services/api.dart';
import 'package:dhara/core/services/location.dart';
import 'package:dhara/core/utils/errors.dart';
import 'package:dhara/core/utils/formatters.dart';
import 'package:dhara/core/utils/validators.dart';
import 'package:dhara/data/models/feedback.dart';
import 'package:dhara/data/models/profile.dart';
import 'package:dhara/data/models/reward.dart';
import 'package:dhara/data/models/tree.dart';
import 'package:dhara/ui/screens/leaderboard/leaderboard_screen.dart';
import 'package:dhara/ui/screens/scan/scan_screen.dart';
import 'package:dhara/ui/widgets/celebrate.dart';

void main() {
  group('classifyScan', () {
    test('reads a 24-character token from the safe alphabet', () {
      expect(
        classifyScan('ABCDEFGHJKLMNPQRSTUVWXYZ'),
        ScannedKind.handoverToken,
      );
    });

    test('reads a DH-prefixed item code', () {
      expect(classifyScan('DHM3X9K2ABCDEFGH'), ScannedKind.itemCode);
    });

    // The regression that matters: D and H are both legal token characters, so
    // a token can begin with "DH" by chance. Length has to win over the prefix
    // or a sender's token would be dropped into the item basket instead of
    // completing the handover.
    test('treats a token beginning with DH as a token, not an item', () {
      const token = 'DHCDEFGHJKLMNPQRSTUVWXYZ';
      expect(token.length, 24);
      expect(classifyScan(token), ScannedKind.handoverToken);
    });

    test('rejects a 24-character string containing an excluded character', () {
      // Contains "I", which the token alphabet omits to avoid ambiguity.
      expect(classifyScan('ABCDEFGHIJKLMNPQRSTUVWXY'), ScannedKind.unknown);
    });

    test('normalises case and surrounding space', () {
      expect(classifyScan('  dhm3x9k2abcdefgh  '), ScannedKind.itemCode);
    });

    test('treats empty input as unknown', () {
      expect(classifyScan('   '), ScannedKind.unknown);
    });
  });

  group('Validate.consumerNo', () {
    test('normalises the way the server does', () {
      expect(Validate.normalizeConsumerNo('  bes 123 456 '), 'BES123456');
    });

    test('accepts letters, digits and dashes', () {
      expect(Validate.consumerNo('KA-1234567'), isNull);
    });

    test('accepts a value only valid after whitespace is stripped', () {
      expect(Validate.consumerNo('BES 12 34'), isNull);
    });

    // The server strips nothing but whitespace and then applies
    // ^[A-Z0-9-]{6,20}$, so a slash has to fail here rather than after a round
    // trip that would look like a server fault to the user.
    test('rejects punctuation the server would reject', () {
      expect(Validate.consumerNo('BES/123456'), isNotNull);
    });

    test('rejects values outside the 6 to 20 character range', () {
      expect(Validate.consumerNo('AB12'), isNotNull);
      expect(Validate.consumerNo('A' * 21), isNotNull);
      expect(Validate.consumerNo('A' * 20), isNull);
    });

    test('asks for input when the field is blank', () {
      expect(Validate.consumerNo('   '), 'Enter your consumer number');
    });
  });

  group('friendlyMessage', () {
    // The server explains exactly why a check-in was rejected. Passing these
    // through the Appwrite-only handler would discard that and show a generic
    // apology instead.
    test('passes a server failure message through untouched', () {
      expect(
        friendlyMessage(const ApiFailure('too_far', 'You are 84 m away.')),
        'You are 84 m away.',
      );
    });

    test('passes a location failure message through untouched', () {
      expect(
        friendlyMessage(
          const LocationFailure(LocationProblem.mocked, 'Turn off mock GPS.'),
        ),
        'Turn off mock GPS.',
      );
    });

    test('describes an undecodable photo', () {
      expect(
        friendlyMessage(const FormatException('That photo could not be read.')),
        'That photo could not be read.',
      );
      expect(friendlyMessage(const FormatException()), isNotEmpty);
    });

    test('still says something useful for a null error', () {
      expect(friendlyMessage(null), isNotEmpty);
    });
  });

  group('Tree', () {
    Tree tree({
      TreeStatus status = TreeStatus.alive,
      DateTime? opens,
      DateTime? closes,
      int verifications = 0,
    }) =>
        Tree(
          id: 't1',
          ownerId: 'u1',
          speciesCode: 'neem',
          speciesName: 'Neem',
          lat: 12.9,
          lng: 77.6,
          plantedAt: DateTime.now().subtract(const Duration(days: 40)),
          status: status,
          nextVerifyAfter: opens,
          verifyWindowEnd: closes,
          verificationCount: verifications,
        );

    final past = DateTime.now().subtract(const Duration(days: 2));
    final future = DateTime.now().add(const Duration(days: 2));

    test('is verifiable inside an open window, and not late', () {
      final t = tree(opens: past, closes: future);
      expect(t.isVerifiable, isTrue);
      expect(t.isLate, isFalse);
    });

    test('is not verifiable before the window opens', () {
      expect(tree(opens: future).isVerifiable, isFalse);
      expect(tree(opens: future).isLate, isFalse);
    });

    // The server only refuses a check-in before the window opens. After the
    // suggested window it still accepts one, so the app must still offer it;
    // hiding it locked the tree out of check-ins for good.
    test('after the window has closed it is still verifiable, marked late', () {
      final t = tree(
        opens: DateTime.now().subtract(const Duration(days: 9)),
        closes: past,
      );
      expect(t.isVerifiable, isTrue);
      expect(t.isLate, isTrue);
      expect(t.untilWindowCloses, isNull);
    });

    test('a lost tree is never verifiable or late', () {
      final t = tree(
        status: TreeStatus.dead,
        opens: DateTime.now().subtract(const Duration(days: 9)),
        closes: past,
      );
      expect(t.isVerifiable, isFalse);
      expect(t.isLate, isFalse);
    });

    test('a lost tree is never verifiable', () {
      expect(
        tree(status: TreeStatus.dead, opens: past, closes: future).isVerifiable,
        isFalse,
      );
    });

    // Credits vest across a full year of check-ins, so a fake tree would have
    // to be maintained for twelve months before it paid out.
    test('vesting tracks check-ins and never exceeds one', () {
      expect(tree(verifications: 3).vestingProgress, closeTo(0.25, 1e-9));
      expect(tree(verifications: 12).isFullyVested, isTrue);
      expect(tree(verifications: 20).vestingProgress, 1.0);
    });
  });

  group('Profile levels', () {
    Profile at({required int xp, required int level}) => Profile(
          id: 'p1',
          userId: 'u1',
          name: 'Govind Raj',
          email: 'g@example.com',
          xp: xp,
          level: level,
        );

    test('reports progress through the current level', () {
      expect(at(xp: 50, level: 1).levelProgress, closeTo(0.5, 1e-9));
    });

    test('treats a level past the end of the curve as maxed', () {
      final maxed = at(xp: 20000, level: kLevelCurve.length);
      expect(maxed.isMaxLevel, isTrue);
      expect(maxed.levelProgress, 1.0);
    });

    test('names every level, including beyond the curve', () {
      expect(at(xp: 0, level: 1).levelTitle, 'Seedling');
      expect(at(xp: 99999, level: 40).levelTitle, isNotEmpty);
    });
  });

  group('BadgeItem progress', () {
    const badge = BadgeItem(
      code: 'trees_10',
      title: 'Ten trees',
      tier: 'silver',
      metric: 'trees_planted',
      threshold: 10,
    );

    double progress(BadgeItem b, {int planted = 0}) => b.progressFrom(
          treesPlanted: planted,
          treesAlive: 0,
          verifications: 0,
          bottlesReturned: 0,
          streak: 0,
          creditsLifetime: 0,
          referrals: 0,
        );

    test('measures the metric it tracks', () {
      expect(progress(badge, planted: 3), closeTo(0.3, 1e-9));
    });

    test('never exceeds one', () {
      expect(progress(badge, planted: 50), 1.0);
    });

    test('an unknown metric reads as no progress rather than throwing', () {
      const odd = BadgeItem(
        code: 'x',
        title: 'X',
        tier: 'bronze',
        metric: 'something_new',
        threshold: 5,
      );
      expect(progress(odd, planted: 99), 0.0);
    });

    test('is earned only once a date is attached', () {
      expect(badge.isEarned, isFalse);
      expect(badge.markEarned(DateTime.now()).isEarned, isTrue);
    });
  });

  group('CreditEntry', () {
    CreditEntry entry(int delta, String source) => CreditEntry(
          id: 'c1',
          delta: delta,
          source: source,
          occurredAt: DateTime.now(),
        );

    test('separates credits from debits', () {
      expect(entry(12, 'tree_verify').isCredit, isTrue);
      expect(entry(-60, 'redemption').isCredit, isFalse);
    });

    test('labels known sources and falls back for unknown ones', () {
      expect(entry(10, 'tree_plant').label, 'Tree planted');
      expect(entry(10, 'something_new').label, isNotEmpty);
    });
  });

  group('initialsOf', () {
    test('uses the first and last word', () {
      expect(initialsOf('Govind Raj'), 'GR');
      expect(initialsOf('  Govind   Kumar Raj  '), 'GR');
    });

    test('uses two letters of a single name', () {
      expect(initialsOf('Govind'), 'GO');
    });

    test('copes with a single character and with nothing at all', () {
      expect(initialsOf('A'), 'A');
      expect(initialsOf('   '), '?');
    });
  });

  group('LocationFix', () {
    LocationFix at({
      double lat = 0,
      double lng = 0,
      double altitudeM = 0,
      double altitudeAccuracyM = 0,
    }) =>
        LocationFix(
          lat: lat,
          lng: lng,
          accuracyM: 5,
          isMocked: false,
          altitudeM: altitudeM,
          altitudeAccuracyM: altitudeAccuracyM,
        );

    // The regression that matters. 12.583325 is 12 deg 34' 59.97", and rounding
    // each part on its own printed that as 34' 60.0" — not notation any GPS
    // receiver would emit. The tenths of an arcsecond have to carry up into
    // minutes, and on into degrees.
    test('rounding seconds carries into minutes instead of printing 60', () {
      expect(at(lat: 12.583325).latDms, 'N 12\u00B0 35\u2032 00.0\u2033');
    });

    test('carries all the way through a degree boundary', () {
      // 0.99999999 deg is 59' 59.99996", which rounds up to a whole degree.
      expect(at(lat: 0.99999999).latDms, 'N 01\u00B0 00\u2032 00.0\u2033');
    });

    test('pads degrees to the width its axis can reach', () {
      // Latitude stops at 90, longitude runs to 180, so they are not the same
      // width. Both are padded so the two lines stack in alignment.
      expect(at(lat: 7.5).latDms, 'N 07\u00B0 30\u2032 00.0\u2033');
      expect(at(lng: 7.5).lngDms, 'E 007\u00B0 30\u2032 00.0\u2033');
    });

    test('pads seconds below ten', () {
      expect(at(lat: 5.5 / 3600).latDms, 'N 00\u00B0 00\u2032 05.5\u2033');
    });

    test('names the hemisphere instead of carrying a sign', () {
      expect(at(lat: -1.5).latDms, 'S 01\u00B0 30\u2032 00.0\u2033');
      expect(at(lng: -1.5).lngDms, 'W 001\u00B0 30\u2032 00.0\u2033');
    });

    // A device with no altitude sensor reports 0 with 0 accuracy, which is
    // indistinguishable from genuinely standing at sea level. Showing that as a
    // measurement would be inventing data, so it reads as unknown.
    test('altitude of zero with no accuracy reads as unknown', () {
      expect(at().hasAltitude, isFalse);
    });

    test('altitude counts when either the value or its accuracy is present', () {
      expect(at(altitudeM: 920.4).hasAltitude, isTrue);
      expect(at(altitudeAccuracyM: 3).hasAltitude, isTrue);
    });
  });

  group('Fmt.stamp', () {
    // Seconds and a zone offset are both load-bearing: this labels evidence, and
    // a time with neither is ambiguous the moment it is read anywhere else.
    test('carries the date, the time to the second, and a UTC offset', () {
      expect(
        Fmt.stamp(DateTime(2026, 9, 12, 7, 5, 3)),
        matches(r'^12 Sep 2026, 07:05:03 UTC[+-]\d{2}:\d{2}$'),
      );
    });

    test('offset is always signed and zero-padded', () {
      expect(Fmt.utcOffset(DateTime(2026, 9, 12)), matches(r'^UTC[+-]\d{2}:\d{2}$'));
    });
  });

  group('FeedbackCategory', () {
    test('round-trips every wire value the server accepts', () {
      for (final c in FeedbackCategory.values) {
        expect(FeedbackCategory.parse(c.wire), c);
      }
    });

    // The server validates `category` against its own copy of this list, so an
    // unknown value has to land somewhere valid rather than being sent on.
    test('an unknown category falls back to other', () {
      expect(FeedbackCategory.parse('nonsense'), FeedbackCategory.other);
      expect(FeedbackCategory.parse(null), FeedbackCategory.other);
    });

    test('every category has a label and an emoji', () {
      for (final c in FeedbackCategory.values) {
        expect(c.label, isNotEmpty);
        expect(c.emoji, isNotEmpty);
      }
    });
  });

  group('FeedbackEntry', () {
    test('reads a full server row', () {
      final entry = FeedbackEntry.fromMap({
        r'$id': 'f1',
        'category': 'bug',
        'message': 'The map does not load.',
        'status': 'answered',
        'adminReply': 'Fixed in the next build.',
        'createdAt': '2026-10-16T04:00:00.000Z',
      });

      expect(entry.category, FeedbackCategory.bug);
      expect(entry.status, FeedbackStatus.answered);
      expect(entry.hasReply, isTrue);
    });

    test('tolerates a row with nothing but an id', () {
      final entry = FeedbackEntry.fromMap({r'$id': 'f2'});
      expect(entry.category, FeedbackCategory.other);
      expect(entry.status, FeedbackStatus.open);
      expect(entry.hasReply, isFalse);
    });

    test('whitespace is not a reply', () {
      final entry = FeedbackEntry.fromMap({r'$id': 'f3', 'adminReply': '   '});
      expect(entry.hasReply, isFalse);
    });
  });

  // The server can hold a submission for review with a machine reason code.
  // _ReasonBox falls back to a de-underscored code, which is not something a
  // user should ever be shown, so every code the server emits needs a sentence.
  group('AI review reasons', () {
    test('every server reason code has a user-facing string', () {
      const emitted = [
        'ai_low_confidence',
        'ai_not_a_plant',
        'ai_species_mismatch',
        'ai_screen_photo',
        'ai_unavailable',
      ];
      for (final code in emitted) {
        expect(
          reasonText(code),
          isNot(code.replaceAll('_', ' ')),
          reason: '$code has no mapping in _ReasonBox',
        );
      }
    });
  });
}
