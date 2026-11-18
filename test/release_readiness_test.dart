import 'dart:async';

import 'package:appwrite/appwrite.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:dhara/core/services/api.dart';
import 'package:dhara/core/services/appwrite.dart';
import 'package:dhara/core/services/location.dart';
import 'package:dhara/core/utils/validators.dart';
import 'package:dhara/data/models/item.dart';
import 'package:dhara/data/repository.dart';
import 'package:dhara/state/auth_controller.dart';
import 'package:dhara/state/items_controller.dart';
import 'package:dhara/ui/screens/footprint/footprint_screen.dart';

import 'support/fake_location_backend.dart';

// Covers the fixes made while preparing the app for release. Each group names
// the user-facing problem it guards against.

TrackedItem _item(String code) => TrackedItem.fromMap({
      r'$id': 'id-$code',
      'code': code,
      'productType': 'pet_bottle',
      'state': 'with_consumer',
      'holderId': 'u1',
      'holderRole': 'consumer',
    });

class _Repo extends Fake implements Repository {
  _Repo(this.items);
  List<TrackedItem> items;
  bool fail = false;
  int reads = 0;

  @override
  Future<List<TrackedItem>> myItems(String userId, {int limit = 100}) async {
    reads++;
    if (fail) throw AppwriteException('ClientException with SocketException');
    return items;
  }
}

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

class _Location extends Fake implements LocationService {
  @override
  Future<LocationFix?> quickFix() async => null;
}

class _Auth extends AuthController {
  int profileRefreshes = 0;

  @override
  Future<AuthState> build() async => const AuthSignedOut();

  @override
  Future<void> refreshProfile() async => profileRefreshes++;
}

class _Harness {
  _Harness(List<TrackedItem> initial) : repo = _Repo(initial) {
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        currentUserIdProvider.overrideWithValue('u1'),
        repositoryProvider.overrideWithValue(repo),
        apiProvider.overrideWith((ref) => api = _Api(ref)),
        locationServiceProvider.overrideWithValue(_Location()),
      ],
    );
    container.read(apiProvider);
  }

  final _Repo repo;
  final auth = _Auth();
  late final _Api api;
  late final ProviderContainer container;

  ItemsController get items => container.read(itemsControllerProvider.notifier);
  AsyncValue<List<TrackedItem>> get state =>
      container.read(itemsControllerProvider);
  Future<List<TrackedItem>> loaded() =>
      container.read(itemsControllerProvider.future);
}

void main() {
  group('handover: a completed server action is never shown as a failure', () {
    late _Harness h;
    setUp(() => h = _Harness([_item('DH000001')]));
    tearDown(() => h.container.dispose());

    test('claim succeeds even if the item reload afterwards fails', () async {
      await h.loaded();
      h.api.reply = {
        'movedCount': 2,
        'creditsAwardedToSender': 4,
        'receiverRole': 'retailer',
      };
      h.repo.fail = true;

      final result = await h.items.claim('ABCDEFGHJKLMNPQRSTUVWXYZ');

      expect(result.movedCount, 2);
      expect(result.creditsAwardedToSender, 4);
      expect(h.api.calls, ['/transfer/claim']);
      expect(h.state.value!.map((i) => i.code), ['DH000001']);
      expect(h.state.hasError, isFalse);
      expect(h.auth.profileRefreshes, 1);
    });

    test('issue returns the token even if the item reload afterwards fails',
        () async {
      await h.loaded();
      h.api.reply = {
        'token': 'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'expiresAt': DateTime.now()
            .add(const Duration(seconds: 90))
            .toUtc()
            .toIso8601String(),
        'itemCount': 1,
        'fromState': 'with_consumer',
        'toState': 'with_retailer',
        'receiverRole': 'retailer',
        'items': [
          {'code': 'DH000001'},
        ],
      };
      h.repo.fail = true;

      final token = await h.items.issue(['DH000001']);

      expect(token.token, 'ABCDEFGHJKLMNPQRSTUVWXYZ');
      expect(token.items, ['DH000001']);
      expect(h.api.calls, ['/transfer/issue']);
      expect(h.state.hasError, isFalse);
    });

    test('a genuine claim rejection is still an error', () async {
      await h.loaded();
      h.api.error = const ApiFailure('token_used', 'That code has already been used.');

      await expectLater(
        h.items.claim('ABCDEFGHJKLMNPQRSTUVWXYZ'),
        throwsA(isA<ApiFailure>().having((e) => e.code, 'code', 'token_used')),
      );
      expect(h.repo.reads, 1);
      expect(h.auth.profileRefreshes, 0);
    });

    test('a failed pull to refresh keeps the items and does not throw',
        () async {
      await h.loaded();
      h.repo.fail = true;

      expect(await h.items.refresh(), isFalse);
      expect(h.state.value!.map((i) => i.code), ['DH000001']);
      expect(h.state.hasError, isFalse);
    });

    test('items the server refused are reported, not silently dropped',
        () async {
      await h.loaded();
      h.api.reply = {
        'token': 'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'itemCount': 1,
        'fromState': 'with_consumer',
        'items': [
          {'code': 'DH000001'},
        ],
        'rejected': [
          {'code': 'DH000002', 'reason': 'You are not holding this item.'},
        ],
      };

      final token = await h.items.issue(['DH000001', 'DH000002']);

      expect(token.items, ['DH000001']);
      expect(token.rejected, ['DH000002 — You are not holding this item.']);
    });

    test('a partial claim still counts as a completed handover', () async {
      h.repo.items = [_item('DH000001'), _item('DH000002')];
      await h.loaded();
      final token = HandoverToken(
        token: 'ABCDEFGHJKLMNPQRSTUVWXYZ',
        expiresAt: DateTime.now().add(const Duration(seconds: 30)),
        itemCount: 2,
        fromState: ItemState.withConsumer,
        toState: ItemState.returnedToRetailer,
        receiverRole: PartyRole.retailer,
        items: const ['DH000001', 'DH000002'],
      );
      // The receiver took one item; the other was skipped and stays here.
      h.repo.items = [_item('DH000002')];

      final moved =
          await h.items.awaitHandover(token, interval: Duration.zero);

      expect(moved, isTrue);
      expect(h.auth.profileRefreshes, 1);
    });

    test('nothing moved before expiry is still reported as not completed',
        () async {
      await h.loaded();
      final token = HandoverToken(
        token: 'ABCDEFGHJKLMNPQRSTUVWXYZ',
        expiresAt: DateTime.now().add(const Duration(milliseconds: 60)),
        itemCount: 1,
        fromState: ItemState.withConsumer,
        toState: ItemState.returnedToRetailer,
        receiverRole: PartyRole.retailer,
        items: const ['DH000001'],
      );

      final moved = await h.items.awaitHandover(
        token,
        interval: const Duration(milliseconds: 10),
      );

      expect(moved, isFalse);
    });
  });

  group('approximate location', () {
    test('is reported plainly instead of an endless "not precise enough"',
        () async {
      final phone = FakeLocationBackend()
        ..permission = LocationPermission.whileInUse
        ..accuracy = LocationAccuracyStatus.reduced;
      final service = LocationService(backend: phone);

      await expectLater(
        service.bestFix(),
        throwsA(
          isA<LocationFailure>()
              .having((e) => e.problem, 'problem', LocationProblem.inaccurate)
              .having((e) => e.message, 'message', contains('precise')),
        ),
      );
      // It does not even try to sample a fix that could never be good enough.
      expect(phone.currentCalls, 0);
    });

    test('precise access still gets a fix as before', () async {
      final phone = FakeLocationBackend()
        ..permission = LocationPermission.whileInUse;
      final fix = await LocationService(backend: phone).bestFix();
      expect(fix.accuracyM, 8);
    });
  });

  group('offline is not "signed out"', () {
    test('a dropped connection is transient', () {
      // What the Appwrite SDK throws when there is no network: no status code.
      expect(
        isTransientError(AppwriteException(
          'ClientException with SocketException: Failed host lookup',
        )),
        isTrue,
      );
      expect(isTransientError(AppwriteException('Server error', 503)), isTrue);
      expect(isTransientError(TimeoutException('slow')), isTrue);
      expect(
        isTransientError(const ApiFailure('function_error', 'No response')),
        isTrue,
      );
    });

    test('a real answer from the server is not transient', () {
      expect(
        isTransientError(
          AppwriteException('Invalid credentials', 401, 'user_invalid_credentials'),
        ),
        isFalse,
      );
      expect(isTransientError(AppwriteException('Not found', 404)), isFalse);
      expect(
        isTransientError(const ApiFailure('account_suspended', 'Suspended')),
        isFalse,
      );
      expect(isTransientError(const AuthFailure('Could not finish')), isFalse);
    });

    test('the raw socket text is never shown to the user', () {
      expect(
        friendlyError(AppwriteException(
          'ClientException with SocketException: Failed host lookup: '
          'sgp.cloud.appwrite.io, uri=https://sgp.cloud.appwrite.io/v1/account',
        )),
        'No internet connection.',
      );
      // A real message without a code is still passed through.
      expect(friendlyError(AppwriteException('Invalid email')), 'Invalid email');
    });
  });

  group('form rules match the server', () {
    test('passwords are limited to Appwrite\'s 256 characters', () {
      expect(Validate.password('a' * 256), isNull);
      expect(Validate.password('a' * 257), isNotNull);
      expect(Validate.password('a' * 7), isNotNull);
    });

    test('footprint months are counted in UTC, like the server', () {
      // 00:30 on 1 Nov in India is still October in UTC. The server would
      // refuse "2026-11" at that moment, so it must not be offered first.
      final indiaJustPastMidnight = DateTime.utc(2026, 10, 31, 19, 0);
      expect(
        recentMonthKeys(now: indiaJustPastMidnight, count: 2),
        ['2026-10', '2026-09'],
      );
    });
  });
}
