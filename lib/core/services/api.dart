import 'dart:convert';

import 'package:appwrite/enums.dart' as enums;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/env.dart';
import 'appwrite.dart';

/// Thrown when the server rejects a call for a business reason (out of radius,
/// duplicate photo, illegal custody move). [code] is a stable machine string
/// the UI can branch on.
class ApiFailure implements Exception {
  const ApiFailure(this.code, this.message, {this.details});

  final String code;
  final String message;
  final Map<String, dynamic>? details;

  @override
  String toString() => 'ApiFailure($code): $message';
}

/// Gateway to the single `api` Appwrite Function.
///
/// Security model: the client never sends its own user ID for anything that
/// mints credits. It sends a short-lived JWT; the function resolves the caller
/// from that token. A tampered request just fails to authenticate.
class Api {
  Api(this._ref);

  final Ref _ref;

  String? _jwt;
  DateTime? _jwtExpiry;

  /// Appwrite JWTs last 15 minutes. Refresh a minute early to avoid racing
  /// the boundary mid-request.
  Future<String> _freshJwt() async {
    final now = DateTime.now();
    final cached = _jwt;
    final expiry = _jwtExpiry;
    if (cached != null && expiry != null && now.isBefore(expiry)) {
      return cached;
    }
    final token = await _ref.read(accountProvider).createJWT();
    _jwt = token.jwt;
    _jwtExpiry = now.add(const Duration(minutes: 14));
    return token.jwt;
  }

  void invalidateJwt() {
    _jwt = null;
    _jwtExpiry = null;
  }

  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic> body = const {},
  ]) async {
    final jwt = await _freshJwt();

    final execution = await _ref.read(functionsProvider).createExecution(
          functionId: Env.apiFunctionId,
          path: path,
          method: enums.ExecutionMethod.pOST,
          body: jsonEncode(body),
          // Deliberately not 'x-appwrite-jwt': Appwrite rejects any
          // caller-supplied header starting with "x-appwrite" and fails the
          // execution with a 500 before the function runs. Every call through
          // here was dead until this was renamed.
          headers: {
            'x-dhara-jwt': jwt,
            'content-type': 'application/json',
          },
        );

    final raw = execution.responseBody;
    if (raw.isEmpty) {
      // An empty body with a non-2xx status means the function itself crashed.
      throw ApiFailure(
        'function_error',
        execution.errors.isNotEmpty
            ? 'Server error. Please try again.'
            : 'No response from server. Please try again.',
      );
    }

    Map<String, dynamic> decoded;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map<String, dynamic>) {
        throw const FormatException('Expected a JSON object');
      }
      decoded = parsed;
    } on FormatException {
      throw const ApiFailure('bad_response', 'Unexpected server response.');
    }

    if (decoded['ok'] == true) {
      final data = decoded['data'];
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    }

    final error = decoded['error'];
    if (error is Map<String, dynamic>) {
      throw ApiFailure(
        (error['code'] ?? 'unknown') as String,
        (error['message'] ?? 'Request failed') as String,
        details: error['details'] is Map<String, dynamic>
            ? error['details'] as Map<String, dynamic>
            : null,
      );
    }
    throw const ApiFailure('unknown', 'Request failed. Please try again.');
  }

  /// Like [post], but tries once more when the server gave no answer at all.
  ///
  /// The first call into a freshly started function runtime can fail at the
  /// platform level with an empty reply (seen right after a deploy: HTTP 500
  /// "general_unknown" and no function logs), and the very next call works.
  /// For a read or an idempotent write a second try is harmless.
  ///
  /// Never use this for anything that moves credits. If the first call had
  /// actually landed, a blind retry could repeat the payout.
  Future<Map<String, dynamic>> postIdempotent(
    String path, [
    Map<String, dynamic> body = const {},
    Duration retryDelay = const Duration(milliseconds: 800),
  ]) async {
    try {
      return await post(path, body);
    } on ApiFailure catch (e) {
      if (e.code != 'function_error') rethrow;
      await Future<void>.delayed(retryDelay);
      return post(path, body);
    }
  }

  // --- Profile -------------------------------------------------------------

  /// Creates the profile row on first login. Idempotent server-side, so it is
  /// safe to retry once when a cold function runtime gives no answer: without
  /// that, a brand-new user's first sign-in failed after the code was accepted.
  Future<Map<String, dynamic>> bootstrapProfile({
    required String name,
    String? referredBy,
  }) =>
      postIdempotent('/profile/bootstrap', {
        'name': name,
        if (referredBy != null && referredBy.isNotEmpty) 'referredBy': referredBy,
      });

  // --- Trees ---------------------------------------------------------------

  Future<Map<String, dynamic>> plantTree({
    required String speciesCode,
    required String nickname,
    required double lat,
    required double lng,
    required double accuracyM,
    required String photoFileId,
    required String phash,
    required bool mocked,
    String? addressLabel,
    double plantConfidence = 0,
    int heightCm = 0,
    List<String> labels = const [],
    double altitudeM = 0,
    double altitudeAccuracyM = 0,
    double headingDeg = 0,
    double speedMps = 0,
    DateTime? fixCapturedAt,
  }) =>
      post('/tree/plant', {
        'speciesCode': speciesCode,
        'nickname': nickname,
        'lat': lat,
        'lng': lng,
        'accuracyM': accuracyM,
        'photoFileId': photoFileId,
        'phash': phash,
        'mocked': mocked,
        'addressLabel': addressLabel,
        'plantConfidence': plantConfidence,
        'heightCm': heightCm,
        'labels': labels,
        'altitudeM': altitudeM,
        'altitudeAccuracyM': altitudeAccuracyM,
        'headingDeg': headingDeg,
        'speedMps': speedMps,
        // UTC: this is stored as an instant, and a local-time string would be
        // ambiguous without also shipping the offset.
        'fixCapturedAt': fixCapturedAt?.toUtc().toIso8601String(),
      });

  Future<Map<String, dynamic>> verifyTree({
    required String treeId,
    required double lat,
    required double lng,
    required double accuracyM,
    required String photoFileId,
    required String phash,
    required bool mocked,
    required int heightCm,
    double plantConfidence = 0,
    List<String> labels = const [],
  }) =>
      post('/tree/verify', {
        'treeId': treeId,
        'lat': lat,
        'lng': lng,
        'accuracyM': accuracyM,
        'photoFileId': photoFileId,
        'phash': phash,
        'mocked': mocked,
        'heightCm': heightCm,
        'plantConfidence': plantConfidence,
        'labels': labels,
      });

  // --- Custody chain -------------------------------------------------------

  /// Sender step: locks the items and returns a short-lived handshake token.
  Future<Map<String, dynamic>> issueTransfer({
    required List<String> codes,
    double? lat,
    double? lng,
  }) =>
      post('/transfer/issue', {
        'codes': codes,
        'lat': lat,
        'lng': lng,
      });

  /// Receiver step: consumes the token and advances each item one legal state.
  Future<Map<String, dynamic>> claimTransfer({
    required String token,
    double? lat,
    double? lng,
  }) =>
      post('/transfer/claim', {
        'token': token,
        'lat': lat,
        'lng': lng,
      });

  Future<Map<String, dynamic>> lookupItem(String code) =>
      post('/item/lookup', {'code': code});

  /// Demo helper: mints serialized items so the chain can be exercised
  /// end-to-end without a real factory line.
  Future<Map<String, dynamic>> mintItems({
    required String productType,
    required int count,
    int sizeMl = 500,
    String productName = '',
    String brandName = '',
  }) =>
      post('/item/mint', {
        'productType': productType,
        'count': count,
        'sizeMl': sizeMl,
        'productName': productName,
        'brandName': brandName,
      });

  // --- Rewards -------------------------------------------------------------

  Future<Map<String, dynamic>> redeem({
    required String rewardId,
    Map<String, dynamic> payload = const {},
  }) =>
      post('/redeem', {'rewardId': rewardId, 'payload': payload});

  Future<Map<String, dynamic>> submitElectricityAccount({
    required String consumerNo,
    required String provider,
    required String providerCode,
    required String billFileId,
    required String ocrExcerpt,
    String? holderName,
    String? stateName,
  }) =>
      post('/electricity/submit', {
        'consumerNo': consumerNo,
        'provider': provider,
        'providerCode': providerCode,
        'billFileId': billFileId,
        'ocrExcerpt': ocrExcerpt,
        'holderName': holderName,
        'stateName': stateName,
      });

  // --- Feedback ------------------------------------------------------------

  Future<Map<String, dynamic>> submitFeedback({
    required String category,
    required String message,
    String? screenshotFileId,
    String? refType,
    String? refId,
    String appVersion = '',
    String platform = '',
    String deviceModel = '',
  }) =>
      post('/feedback/submit', {
        'category': category,
        'message': message,
        'screenshotFileId': screenshotFileId,
        'refType': refType,
        'refId': refId,
        'appVersion': appVersion,
        'platform': platform,
        'deviceModel': deviceModel,
      });

  // --- Gamification --------------------------------------------------------

  Future<Map<String, dynamic>> syncBadges() => post('/badges/sync');

  /// Asks the server to rebuild the public leaderboard snapshot. Cheap and
  /// safe to call often: the server skips the rebuild if it is already fresh.
  Future<Map<String, dynamic>> refreshLeaderboard({
    String period = 'all_time',
  }) =>
      post('/leaderboard/refresh', {'period': period});
}

final apiProvider = Provider<Api>((ref) => Api(ref));
