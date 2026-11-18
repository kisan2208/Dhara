import 'package:equatable/equatable.dart';

enum TreeStatus {
  pendingReview('pending_review', 'In review'),
  alive('alive', 'Alive'),
  atRisk('at_risk', 'Needs check-in'),
  missed('missed', 'Check-in missed'),
  dead('dead', 'Lost'),
  rejected('rejected', 'Rejected');

  const TreeStatus(this.wire, this.label);
  final String wire;
  final String label;

  static TreeStatus parse(Object? v) => TreeStatus.values.firstWhere(
        (s) => s.wire == v,
        orElse: () => TreeStatus.pendingReview,
      );

  bool get countsAsLiving =>
      this == TreeStatus.alive || this == TreeStatus.atRisk;
}

class Species extends Equatable {
  const Species({
    required this.code,
    required this.name,
    this.scientificName = '',
    this.emoji = '\u{1F333}',
    this.co2PerYearGrams = 0,
    this.creditsPerVerification = 10,
    this.matureHeightCm = 0,
    this.careTip = '',
  });

  final String code;
  final String name;
  final String scientificName;
  final String emoji;
  final int co2PerYearGrams;
  final int creditsPerVerification;
  final int matureHeightCm;
  final String careTip;

  factory Species.fromMap(Map<String, dynamic> m) => Species(
        code: (m['code'] ?? '') as String,
        name: (m['name'] ?? '') as String,
        scientificName: (m['scientificName'] ?? '') as String,
        emoji: (m['emoji'] ?? '\u{1F333}') as String,
        co2PerYearGrams: _int(m['co2PerYearGrams']),
        creditsPerVerification: _int(m['creditsPerVerification'], 10),
        matureHeightCm: _int(m['matureHeightCm']),
        careTip: (m['careTip'] ?? '') as String,
      );

  @override
  List<Object?> get props => [code, name];
}

class Tree extends Equatable {
  const Tree({
    required this.id,
    required this.ownerId,
    required this.speciesCode,
    required this.speciesName,
    required this.lat,
    required this.lng,
    required this.plantedAt,
    required this.status,
    this.nickname,
    this.addressLabel,
    this.plantPhotoFileId,
    this.accuracyM = 0,
    this.verificationCount = 0,
    this.consecutiveMisses = 0,
    this.heightCm = 0,
    this.creditsVested = 0,
    this.creditsPending = 0,
    this.vestingMonths = 12,
    this.nextVerifyAfter,
    this.verifyWindowEnd,
    this.lastVerifiedAt,
    this.rejectReason,
    this.markerCode,
    this.altitudeM = 0,
    this.altitudeAccuracyM = 0,
    this.headingDeg = 0,
    this.speedMps = 0,
    this.fixCapturedAt,
  });

  final String id;
  final String ownerId;
  final String speciesCode;
  final String speciesName;
  final String? nickname;
  final double lat;
  final double lng;
  final double accuracyM;
  final String? addressLabel;
  final String? plantPhotoFileId;
  final DateTime plantedAt;
  final TreeStatus status;
  final String? rejectReason;
  final int verificationCount;
  final int consecutiveMisses;
  final int heightCm;
  final int creditsVested;
  final int creditsPending;
  final int vestingMonths;
  final DateTime? nextVerifyAfter;
  final DateTime? verifyWindowEnd;
  final DateTime? lastVerifiedAt;
  final String? markerCode;

  /// The rest of the GPS reading taken when the tree was registered.
  ///
  /// Zero means "the device did not report it", not a measured zero — see
  /// [hasAltitude]. These are kept for the audit trail rather than any
  /// calculation; nothing in the credit maths reads them.
  final double altitudeM;
  final double altitudeAccuracyM;
  final double headingDeg;
  final double speedMps;

  /// The device clock at the moment of the fix. Distinct from [plantedAt], which
  /// is the server's time and stays the authority.
  final DateTime? fixCapturedAt;

  bool get hasAltitude => altitudeM != 0 || altitudeAccuracyM > 0;

  factory Tree.fromMap(Map<String, dynamic> m) => Tree(
        id: (m[r'$id'] ?? '') as String,
        ownerId: (m['ownerId'] ?? '') as String,
        speciesCode: (m['speciesCode'] ?? 'other') as String,
        speciesName: (m['speciesName'] ?? 'Tree') as String,
        nickname: m['nickname'] as String?,
        lat: _dbl(m['lat']),
        lng: _dbl(m['lng']),
        accuracyM: _dbl(m['accuracyM']),
        addressLabel: m['addressLabel'] as String?,
        plantPhotoFileId: m['plantPhotoFileId'] as String?,
        plantedAt: _date(m['plantedAt']) ?? DateTime.now(),
        status: TreeStatus.parse(m['status']),
        rejectReason: m['rejectReason'] as String?,
        verificationCount: _int(m['verificationCount']),
        consecutiveMisses: _int(m['consecutiveMisses']),
        heightCm: _int(m['heightCm']),
        creditsVested: _int(m['creditsVested']),
        creditsPending: _int(m['creditsPending']),
        vestingMonths: _int(m['vestingMonths'], 12),
        nextVerifyAfter: _date(m['nextVerifyAfter']),
        verifyWindowEnd: _date(m['verifyWindowEnd']),
        lastVerifiedAt: _date(m['lastVerifiedAt']),
        markerCode: m['markerCode'] as String?,
        altitudeM: _dbl(m['altitudeM']),
        altitudeAccuracyM: _dbl(m['altitudeAccuracyM']),
        headingDeg: _dbl(m['headingDeg']),
        speedMps: _dbl(m['speedMps']),
        fixCapturedAt: _date(m['fixCapturedAt']),
      );

  String get displayName =>
      (nickname != null && nickname!.trim().isNotEmpty) ? nickname! : speciesName;

  /// Credits only vest as the tree survives, so a fraudster would have to
  /// maintain a fake tree for a full year to earn out.
  double get vestingProgress =>
      (verificationCount / vestingMonths).clamp(0.0, 1.0);

  bool get isFullyVested => verificationCount >= vestingMonths;

  /// True when a check-in can be made now.
  ///
  /// Only the opening date is enforced, because that is all the server
  /// enforces (`routes/tree.js` refuses a check-in before `nextVerifyAfter`
  /// and nothing after `verifyWindowEnd`). Hiding the button once the window
  /// closed locked the tree out of check-ins for good, while the server would
  /// still have accepted one. A check-in after the window is shown as [isLate].
  bool get isVerifiable {
    if (!status.countsAsLiving && status != TreeStatus.missed) return false;
    final now = DateTime.now();
    final opens = nextVerifyAfter;
    if (opens == null) return true;
    if (now.isBefore(opens)) return false;
    return true;
  }

  /// A check-in is due and the suggested window has passed. Display only: the
  /// server applies the same credit rules to a late check-in as to any other.
  bool get isLate {
    final closes = verifyWindowEnd;
    return closes != null && isVerifiable && DateTime.now().isAfter(closes);
  }

  Duration? get untilVerifyOpens {
    final opens = nextVerifyAfter;
    if (opens == null) return null;
    final d = opens.difference(DateTime.now());
    return d.isNegative ? null : d;
  }

  Duration? get untilWindowCloses {
    final closes = verifyWindowEnd;
    if (closes == null || !isVerifiable) return null;
    final d = closes.difference(DateTime.now());
    return d.isNegative ? null : d;
  }

  int get ageInDays => DateTime.now().difference(plantedAt).inDays;

  @override
  List<Object?> get props => [
        id,
        status,
        verificationCount,
        creditsVested,
        heightCm,
        nextVerifyAfter,
        lastVerifiedAt,
      ];
}

enum VerificationStatus {
  approved('approved'),
  rejected('rejected'),
  manualReview('manual_review');

  const VerificationStatus(this.wire);
  final String wire;

  static VerificationStatus parse(Object? v) =>
      VerificationStatus.values.firstWhere(
        (s) => s.wire == v,
        orElse: () => VerificationStatus.manualReview,
      );
}

class TreeVerification extends Equatable {
  const TreeVerification({
    required this.id,
    required this.treeId,
    required this.monthKey,
    required this.status,
    required this.verifiedAt,
    this.photoFileId,
    this.distanceM = 0,
    this.heightCm = 0,
    this.creditsAwarded = 0,
    this.rejectReason,
    this.plantConfidence = 0,
  });

  final String id;
  final String treeId;
  final String monthKey;
  final VerificationStatus status;
  final DateTime verifiedAt;
  final String? photoFileId;
  final double distanceM;
  final int heightCm;
  final int creditsAwarded;
  final String? rejectReason;
  final double plantConfidence;

  factory TreeVerification.fromMap(Map<String, dynamic> m) => TreeVerification(
        id: (m[r'$id'] ?? '') as String,
        treeId: (m['treeId'] ?? '') as String,
        monthKey: (m['monthKey'] ?? '') as String,
        status: VerificationStatus.parse(m['status']),
        verifiedAt: _date(m['verifiedAt']) ?? DateTime.now(),
        photoFileId: m['photoFileId'] as String?,
        distanceM: _dbl(m['distanceM']),
        heightCm: _int(m['heightCm']),
        creditsAwarded: _int(m['creditsAwarded']),
        rejectReason: m['rejectReason'] as String?,
        plantConfidence: _dbl(m['plantConfidence']),
      );

  @override
  List<Object?> get props => [id, status, creditsAwarded];
}

int _int(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

double _dbl(Object? v, [double fallback = 0]) {
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? fallback;
  return fallback;
}

DateTime? _date(Object? v) {
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
  return null;
}
