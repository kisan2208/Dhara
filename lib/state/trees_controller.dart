import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/api.dart';
import '../core/services/location.dart';
import '../core/services/media.dart';
import '../core/services/vision.dart';
import '../data/models/tree.dart';
import '../data/repository.dart';
import 'auth_controller.dart';

/// Outcome of a plant or check-in submission.
///
/// `needsReview` is not a failure: the submission was accepted but routed to
/// manual review, so credits are withheld rather than denied. The UI has to
/// distinguish that from an outright rejection, which arrives as [ApiFailure].
class TreeSubmission {
  const TreeSubmission({
    required this.creditsAwarded,
    required this.needsReview,
    this.reasons = const [],
    this.streakBonus = 0,
    this.streak = 0,
    this.balance,
    this.vestedCount = 0,
    this.vestingMonths = 12,
    this.treeId,
  });

  final int creditsAwarded;
  final bool needsReview;
  final List<String> reasons;
  final int streakBonus;
  final int streak;
  final int? balance;
  final int vestedCount;
  final int vestingMonths;
  final String? treeId;

  int get totalCredits => creditsAwarded + streakBonus;

  bool get isFullyVested => vestedCount >= vestingMonths;
}

final speciesProvider = FutureProvider<List<Species>>(
  (ref) => ref.watch(repositoryProvider).species(),
);

/// Verification history for one tree.
final treeVerificationsProvider =
    FutureProvider.family<List<TreeVerification>, String>(
  (ref, treeId) => ref.watch(repositoryProvider).verifications(treeId),
);

class TreesController extends AsyncNotifier<List<Tree>> {
  @override
  Future<List<Tree>> build() async {
    final userId = ref.watch(currentUserIdProvider);
    if (userId == null) return const [];
    return ref.watch(repositoryProvider).myTrees(userId);
  }

  /// Reloads the list. Never throws; returns whether the reload worked.
  ///
  /// A failed reload keeps the list the user is already looking at, the same
  /// way a failed [AuthController.refreshProfile] keeps the profile: a network
  /// blip must not blank the screen or surface as an error from whatever
  /// called this. Only a list that never loaded at all shows the error, so the
  /// screen's retry state still works.
  Future<bool> refresh() async {
    try {
      state = AsyncValue.data(await build());
      return true;
    } catch (e, st) {
      if (!state.hasValue) state = AsyncValue.error(e, st);
      return false;
    }
  }

  /// Registers a newly planted tree.
  ///
  /// The photo is uploaded before the API call because the server needs a
  /// stored file to hash and audit. If the call is then rejected the orphaned
  /// file is harmless: it is private to the user and never referenced.
  Future<TreeSubmission> plant({
    required String photoPath,
    required LocationFix fix,
    required String speciesCode,
    required String nickname,
    int heightCm = 0,
  }) async {
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) {
      throw const ApiFailure('not_signed_in', 'Please sign in again.');
    }

    final check = await ref.read(visionProvider).checkPlant(photoPath);
    final uploaded = await ref.read(mediaServiceProvider).processAndUpload(
          path: photoPath,
          userId: userId,
          prefix: 'plant',
        );

    final data = await ref.read(apiProvider).plantTree(
          speciesCode: speciesCode,
          nickname: nickname,
          lat: fix.lat,
          lng: fix.lng,
          accuracyM: fix.accuracyM,
          photoFileId: uploaded.fileId,
          phash: uploaded.phash,
          mocked: fix.isMocked,
          addressLabel: fix.address,
          plantConfidence: check.confidence,
          heightCm: heightCm,
          labels: check.labels,
          altitudeM: fix.altitudeM,
          altitudeAccuracyM: fix.altitudeAccuracyM,
          headingDeg: fix.headingDeg,
          speedMps: fix.speedMps,
          fixCapturedAt: fix.capturedAt,
        );

    await _settle();

    final tree = data['tree'];
    return TreeSubmission(
      creditsAwarded: _int(data['creditsAwarded']),
      needsReview: data['needsReview'] == true,
      reasons: _strings(data['reasons']),
      balance: data['balance'] is num ? _int(data['balance']) : null,
      treeId: tree is Map<String, dynamic> ? tree[r'$id'] as String? : null,
    );
  }

  /// Monthly check-in. The 30 m proof-of-presence rule is enforced server-side;
  /// the client checks distance first only to avoid a pointless upload.
  Future<TreeSubmission> verify({
    required String treeId,
    required String photoPath,
    required LocationFix fix,
    required int heightCm,
  }) async {
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) {
      throw const ApiFailure('not_signed_in', 'Please sign in again.');
    }

    final check = await ref.read(visionProvider).checkPlant(photoPath);
    final uploaded = await ref.read(mediaServiceProvider).processAndUpload(
          path: photoPath,
          userId: userId,
          prefix: 'verify',
        );

    final data = await ref.read(apiProvider).verifyTree(
          treeId: treeId,
          lat: fix.lat,
          lng: fix.lng,
          accuracyM: fix.accuracyM,
          photoFileId: uploaded.fileId,
          phash: uploaded.phash,
          mocked: fix.isMocked,
          heightCm: heightCm,
          plantConfidence: check.confidence,
          labels: check.labels,
        );

    await _settle();
    ref.invalidate(treeVerificationsProvider(treeId));

    return TreeSubmission(
      creditsAwarded: _int(data['creditsAwarded']),
      needsReview: data['needsReview'] == true,
      reasons: _strings(data['reasons']),
      streakBonus: _int(data['streakBonus']),
      streak: _int(data['streak']),
      balance: data['balance'] is num ? _int(data['balance']) : null,
      vestedCount: _int(data['vestedCount']),
      vestingMonths: _int(data['vestingMonths'], 12),
      treeId: treeId,
    );
  }

  /// Credits moved, so the cached profile and tree rows are both stale.
  ///
  /// Runs only after the server has accepted the submission, so nothing in
  /// here may throw: the tree is registered and the credits are paid whether
  /// or not this reload works. Turning a reload failure into an error would
  /// tell the user it failed, and their retry would then be refused as "too
  /// close", "already checked in" or a duplicate photo. Both calls below
  /// swallow their own failures and leave the previous data on screen.
  Future<void> _settle() async {
    await refresh();
    await ref.read(authControllerProvider.notifier).refreshProfile();
  }
}

final treesControllerProvider =
    AsyncNotifierProvider<TreesController, List<Tree>>(TreesController.new);

/// One tree, selected from the loaded list.
///
/// Deliberately a selector rather than its own fetch: the detail screen then
/// updates itself when a check-in refreshes the list, with no invalidation to
/// remember and no second read of a row the app already holds.
final treeByIdProvider = Provider.family<Tree?, String>((ref, treeId) {
  final trees = ref.watch(treesControllerProvider).value;
  if (trees == null) return null;
  for (final tree in trees) {
    if (tree.id == treeId) return tree;
  }
  return null;
});

/// Trees whose check-in window is open right now, soonest deadline first.
final treesDueProvider = Provider<List<Tree>>((ref) {
  final trees = ref.watch(treesControllerProvider).value ?? const <Tree>[];
  final due = trees.where((t) => t.isVerifiable).toList()
    ..sort((a, b) {
      final x = a.verifyWindowEnd;
      final y = b.verifyWindowEnd;
      if (x == null && y == null) return 0;
      if (x == null) return 1;
      if (y == null) return -1;
      return x.compareTo(y);
    });
  return due;
});

int _int(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

List<String> _strings(Object? v) {
  if (v is List) {
    return v.whereType<String>().where((s) => s.trim().isNotEmpty).toList();
  }
  return const [];
}
