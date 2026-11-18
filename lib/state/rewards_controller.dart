import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/env.dart';
import '../core/services/api.dart';
import '../core/services/media.dart';
import '../core/services/vision.dart';
import '../data/models/reward.dart';
import '../data/repository.dart';
import 'auth_controller.dart';

/// The electricity account backing bill redemptions.
///
/// Asked for once, then reused. Verification is re-checked at redemption time
/// because an account can be rejected by a reviewer after it was submitted.
class ElectricityAccount {
  const ElectricityAccount({
    required this.consumerNo,
    required this.provider,
    required this.status,
    this.matchScore = 0,
    this.rejectReason,
  });

  final String consumerNo;
  final String provider;
  final String status;
  final double matchScore;
  final String? rejectReason;

  bool get isVerified => status == 'verified';
  bool get isPending => status == 'pending_review';
  bool get isRejected => status == 'rejected';

  /// Only the last four digits are ever shown back to the user.
  String get masked => consumerNo.length <= 4
      ? consumerNo
      : '${'*' * (consumerNo.length - 4)}${consumerNo.substring(consumerNo.length - 4)}';

  static ElectricityAccount? fromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    final consumerNo = m['consumerNo'];
    if (consumerNo is! String || consumerNo.isEmpty) return null;
    return ElectricityAccount(
      consumerNo: consumerNo,
      provider: (m['provider'] ?? '') as String,
      status: (m['status'] ?? 'pending_review') as String,
      matchScore: (m['ocrMatchScore'] as num?)?.toDouble() ?? 0,
      rejectReason: m['rejectReason'] as String?,
    );
  }
}

/// Outcome of submitting a bill photo for verification.
class BillSubmission {
  const BillSubmission({
    required this.verified,
    required this.message,
    this.matchScore = 0,
    this.alreadyLinked = false,
  });

  final bool verified;
  final String message;
  final double matchScore;
  final bool alreadyLinked;
}

class RedeemResult {
  const RedeemResult({
    required this.creditsSpent,
    required this.balance,
    this.voucherCode,
    this.status = 'pending',
  });

  final int creditsSpent;
  final int balance;
  final String? voucherCode;
  final String status;
}

final rewardsProvider = FutureProvider<List<Reward>>(
  (ref) => ref.watch(repositoryProvider).rewards(),
);

final myRedemptionsProvider = FutureProvider<List<Redemption>>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return const [];
  return ref.watch(repositoryProvider).myRedemptions(userId);
});

/// Auto-disposed so it is read fresh each time the history screen opens.
/// Credits move from many places (planting, check-ins, handovers, badge
/// bonuses, refunds), and a long-lived cache showed the old ledger next to the
/// new balance unless each of them remembered to invalidate it.
final creditHistoryProvider =
    FutureProvider.autoDispose<List<CreditEntry>>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return const [];
  return ref.watch(repositoryProvider).ledger(userId);
});

final electricityAccountProvider =
    FutureProvider<ElectricityAccount?>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return null;
  final raw = await ref.watch(repositoryProvider).primaryElectricityAccount(userId);
  return ElectricityAccount.fromMap(raw);
});

class RewardsController extends Notifier<void> {
  @override
  void build() {}

  /// Spends credits on a reward.
  ///
  /// The server re-derives the balance from the ledger before deducting, so a
  /// stale cached balance on this side cannot be used to overspend.
  Future<RedeemResult> redeem({
    required Reward reward,
    Map<String, dynamic> payload = const {},
  }) async {
    final data = await ref.read(apiProvider).redeem(
          rewardId: reward.id,
          payload: payload,
        );

    ref.invalidate(myRedemptionsProvider);
    ref.invalidate(creditHistoryProvider);
    ref.invalidate(rewardsProvider);
    await ref.read(authControllerProvider.notifier).refreshProfile();

    final record = data['redemption'];
    final map = record is Map<String, dynamic> ? record : const {};

    return RedeemResult(
      creditsSpent: _int(data['creditsSpent']),
      balance: _int(data['balance']),
      voucherCode: map['voucherCode'] as String?,
      status: (map['status'] ?? 'pending') as String,
    );
  }

  /// Reads a bill photo on-device and submits it with the typed consumer
  /// number. The server compares digits itself; the OCR text travels with the
  /// request purely as evidence for that comparison and for manual review.
  Future<BillSubmission> submitBill({
    required String photoPath,
    required String consumerNo,
    required String provider,
    required String providerCode,
    String? holderName,
    String? stateName,
  }) async {
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) {
      throw const ApiFailure('not_signed_in', 'Please sign in again.');
    }

    final ocrText = await ref.read(visionProvider).readText(photoPath);

    // Kept larger than a tree photo so a human reviewer can still read the
    // stored copy if this lands in manual review.
    final uploaded = await ref.read(mediaServiceProvider).processAndUpload(
          path: photoPath,
          userId: userId,
          bucketId: Buckets.billDocs,
          prefix: 'bill',
          maxEdge: 2000,
        );

    final data = await ref.read(apiProvider).submitElectricityAccount(
          consumerNo: consumerNo.trim(),
          provider: provider,
          providerCode: providerCode,
          billFileId: uploaded.fileId,
          ocrExcerpt: ocrText,
          holderName: holderName,
          stateName: stateName,
        );

    ref.invalidate(electricityAccountProvider);
    await ref.read(authControllerProvider.notifier).refreshProfile();

    final alreadyLinked = data['alreadyLinked'] == true;
    final verified = data['verified'] == true ||
        (alreadyLinked && _statusOf(data['account']) == 'verified');
    return BillSubmission(
      verified: verified,
      // A server that predates re-evaluation answers a resubmission with the
      // old record and no message. Saying "sent for review" then would be
      // false: the new photo was not looked at.
      message: (data['message'] ??
              (alreadyLinked
                  ? (verified
                      ? 'This account is already verified.'
                      : 'This consumer number is already on file and still '
                          'being reviewed. Your new photo was not added.')
                  : 'Submitted for review.'))
          as String,
      matchScore: (data['matchScore'] as num?)?.toDouble() ?? 0,
      alreadyLinked: alreadyLinked,
    );
  }

  /// Best-effort prefill so the user does not retype a long number.
  Future<String?> guessConsumerNumber(String photoPath) async {
    final text = await ref.read(visionProvider).readText(photoPath);
    return Vision.guessConsumerNumber(text);
  }
}

final rewardsControllerProvider =
    NotifierProvider<RewardsController, void>(RewardsController.new);

String _statusOf(Object? account) {
  if (account is Map && account['status'] is String) {
    return account['status'] as String;
  }
  return '';
}

int _int(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}
