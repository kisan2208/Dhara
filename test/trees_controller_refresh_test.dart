import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dhara/core/services/api.dart';
import 'package:dhara/core/services/location.dart';
import 'package:dhara/core/services/media.dart';
import 'package:dhara/core/services/vision.dart';
import 'package:dhara/data/models/tree.dart';
import 'package:dhara/data/repository.dart';
import 'package:dhara/state/auth_controller.dart';
import 'package:dhara/state/trees_controller.dart';

// A successful plant or check-in has already registered the tree and paid the
// credits on the server. Reloading the tree list afterwards is housekeeping;
// if that reload fails, the user must still be told it worked. Otherwise they
// retry and the server refuses them ("too close", "already checked in",
// duplicate photo).

Tree _tree(String id) => Tree(
  id: id,
  ownerId: 'u1',
  speciesCode: 'neem',
  speciesName: 'Neem',
  lat: 12.97,
  lng: 77.59,
  plantedAt: DateTime(2026, 1, 1),
  status: TreeStatus.alive,
);

const _fix = LocationFix(lat: 12.97, lng: 77.59, accuracyM: 5, isMocked: false);

/// The tree list. `fail` makes the next reads throw, like a dropped network.
class _Repo extends Fake implements Repository {
  _Repo(this.trees);
  List<Tree> trees;
  bool fail = false;
  int reads = 0;

  @override
  Future<List<Tree>> myTrees(String userId, {int limit = 100}) async {
    reads++;
    if (fail) throw Exception('network down');
    return trees;
  }
}

/// The server function. Answers [reply], or throws [error] when set.
class _Api extends Api {
  _Api(super.ref);
  Map<String, dynamic> reply = const {};
  Object? error;
  final calls = <String>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic> body = const {},
  ]) async {
    calls.add(path);
    final e = error;
    if (e != null) throw e;
    return reply;
  }
}

class _Vision extends Fake implements Vision {
  @override
  Future<PlantCheck> checkPlant(String imagePath) async =>
      const PlantCheck(confidence: 0.9, labels: ['Tree'], isPlant: true);
}

class _Media extends MediaService {
  _Media(super.ref);

  @override
  Future<UploadedPhoto> processAndUpload({
    required String path,
    required String userId,
    String bucketId = 'tree_photos',
    String prefix = 'tree',
    int maxEdge = 1440,
  }) async => const UploadedPhoto(fileId: 'file1', phash: 'abcdef0123456789');
}

/// Signed out as far as the network is concerned; only counts profile reloads.
class _Auth extends AuthController {
  int profileRefreshes = 0;

  @override
  Future<AuthState> build() async => const AuthSignedOut();

  @override
  Future<void> refreshProfile() async => profileRefreshes++;
}

class _Harness {
  _Harness(List<Tree> initial, {bool autoRetry = true})
    : repo = _Repo(initial) {
    container = ProviderContainer(
      // Riverpod 3 re-runs a failed first load on its own. The app keeps that;
      // a test about the error state switches it off to see that state now
      // rather than after the retries run out.
      retry: autoRetry ? null : (_, _) => null,
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        currentUserIdProvider.overrideWithValue('u1'),
        repositoryProvider.overrideWithValue(repo),
        apiProvider.overrideWith((ref) => api = _Api(ref)),
        visionProvider.overrideWithValue(_Vision()),
        mediaServiceProvider.overrideWith(_Media.new),
      ],
    );
    // Create the API now, so tests can set its reply before calling plant().
    container.read(apiProvider);
  }

  final _Repo repo;
  final auth = _Auth();
  late final _Api api;
  late final ProviderContainer container;

  TreesController get trees => container.read(treesControllerProvider.notifier);
  AsyncValue<List<Tree>> get state => container.read(treesControllerProvider);

  Future<List<Tree>> loaded() => container.read(treesControllerProvider.future);
}

void main() {
  late _Harness h;

  setUp(() {
    h = _Harness([_tree('t1')]);
  });
  tearDown(() => h.container.dispose());

  group('plant', () {
    test('succeeds even if the tree-list refresh afterwards fails', () async {
      await h.loaded();
      h.api.reply = {
        'tree': {r'$id': 't2'},
        'creditsAwarded': 5,
        'needsReview': false,
        'reasons': <String>[],
        'balance': 15,
      };
      h.repo.fail = true;

      final result = await h.trees.plant(
        photoPath: '/p.jpg',
        fix: _fix,
        speciesCode: 'neem',
        nickname: '',
      );

      // The server's answer is passed through untouched.
      expect(result.creditsAwarded, 5);
      expect(result.needsReview, isFalse);
      expect(result.balance, 15);
      expect(result.treeId, 't2');
      expect(h.api.calls, ['/tree/plant']);
      // The reload was attempted and failed; the list on screen is kept.
      expect(h.repo.reads, 2);
      expect(h.state.value!.map((t) => t.id), ['t1']);
      expect(h.state.hasError, isFalse);
      // The profile is still refreshed for the new balance.
      expect(h.auth.profileRefreshes, 1);
    });

    test(
      'a held-for-review answer is still returned when the refresh fails',
      () async {
        await h.loaded();
        h.api.reply = {
          'creditsAwarded': 0,
          'needsReview': true,
          'reasons': ['ai_low_confidence'],
        };
        h.repo.fail = true;

        final result = await h.trees.plant(
          photoPath: '/p.jpg',
          fix: _fix,
          speciesCode: 'other',
          nickname: '',
        );
        expect(result.needsReview, isTrue);
        expect(result.reasons, ['ai_low_confidence']);
      },
    );

    test('a genuine server rejection is still an error', () async {
      await h.loaded();
      h.api.error = const ApiFailure(
        'too_close',
        'Another member already registered a tree 2 m from here.',
      );

      await expectLater(
        h.trees.plant(
          photoPath: '/p.jpg',
          fix: _fix,
          speciesCode: 'neem',
          nickname: '',
        ),
        throwsA(isA<ApiFailure>().having((e) => e.code, 'code', 'too_close')),
      );
      // Nothing was accepted, so nothing was reloaded.
      expect(h.repo.reads, 1);
      expect(h.auth.profileRefreshes, 0);
    });
  });

  group('verify', () {
    test('succeeds even if the tree-list refresh afterwards fails', () async {
      await h.loaded();
      h.api.reply = {
        'creditsAwarded': 10,
        'needsReview': false,
        'streakBonus': 30,
        'streak': 3,
        'balance': 55,
        'vestedCount': 3,
        'vestingMonths': 12,
      };
      h.repo.fail = true;

      final result = await h.trees.verify(
        treeId: 't1',
        photoPath: '/p.jpg',
        fix: _fix,
        heightCm: 40,
      );

      expect(result.creditsAwarded, 10);
      expect(result.streakBonus, 30);
      expect(result.totalCredits, 40);
      expect(result.streak, 3);
      expect(result.balance, 55);
      expect(result.vestedCount, 3);
      expect(result.treeId, 't1');
      expect(h.api.calls, ['/tree/verify']);
      expect(h.state.value!.map((t) => t.id), ['t1']);
      expect(h.auth.profileRefreshes, 1);
    });

    test('a genuine server rejection is still an error', () async {
      await h.loaded();
      h.api.error = const ApiFailure(
        'already_verified',
        'You have already checked in on this tree this month.',
      );

      await expectLater(
        h.trees.verify(
          treeId: 't1',
          photoPath: '/p.jpg',
          fix: _fix,
          heightCm: 40,
        ),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'already_verified'),
        ),
      );
      expect(h.repo.reads, 1);
      expect(h.auth.profileRefreshes, 0);
    });
  });

  group('pull to refresh', () {
    test(
      'a failed reload keeps the existing list and does not throw',
      () async {
        await h.loaded();
        h.repo.fail = true;

        final ok = await h.trees.refresh();

        expect(ok, isFalse);
        expect(h.state.hasError, isFalse);
        expect(h.state.value!.map((t) => t.id), ['t1']);
      },
    );

    test('a successful reload replaces the list', () async {
      await h.loaded();
      h.repo.trees = [_tree('t1'), _tree('t2')];

      final ok = await h.trees.refresh();

      expect(ok, isTrue);
      expect(h.state.value!.map((t) => t.id), ['t1', 't2']);
    });

    test(
      'a list that never loaded still shows the error, so Retry works',
      () async {
        h.container.dispose();
        h = _Harness([_tree('t1')], autoRetry: false);
        h.repo.fail = true;
        await expectLater(h.loaded(), throwsA(isA<Exception>()));

        final ok = await h.trees.refresh();

        expect(ok, isFalse);
        expect(h.state.hasError, isTrue);
        expect(h.state.hasValue, isFalse);

        // And once the network is back, a retry recovers.
        h.repo.fail = false;
        expect(await h.trees.refresh(), isTrue);
        expect(h.state.value!.map((t) => t.id), ['t1']);
      },
    );
  });
}
