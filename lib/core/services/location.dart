import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:geolocator/geolocator.dart';

import '../utils/formatters.dart';

/// Why a location request could not be satisfied.
enum LocationProblem {
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
  timeout,
  mocked,
  inaccurate,
  unknown,
}

class LocationFix {
  const LocationFix({
    required this.lat,
    required this.lng,
    required this.accuracyM,
    required this.isMocked,
    this.address,
    this.samples = 1,
    this.altitudeM = 0,
    this.altitudeAccuracyM = 0,
    this.headingDeg = 0,
    this.speedMps = 0,
    this.capturedAt,
  });

  /// Maps a platform reading onto the app's own type.
  ///
  /// One place for this on purpose: the same eleven-field copy used to be
  /// written out by hand in three methods, and a field added to one and
  /// forgotten in another is the kind of drift that only shows up in an audit.
  factory LocationFix.fromPosition(
    Position p, {
    String? address,
    int samples = 1,
  }) =>
      LocationFix(
        lat: p.latitude,
        lng: p.longitude,
        accuracyM: p.accuracy,
        isMocked: p.isMocked,
        address: address,
        samples: samples,
        altitudeM: p.altitude,
        altitudeAccuracyM: p.altitudeAccuracy,
        headingDeg: p.heading,
        speedMps: p.speed,
        capturedAt: p.timestamp,
      );

  final double lat;
  final double lng;
  final double accuracyM;
  final bool isMocked;
  final String? address;
  final int samples;

  /// Metres above the WGS-84 ellipsoid, as reported by the device.
  final double altitudeM;
  final double altitudeAccuracyM;

  /// Degrees clockwise from true north. Only meaningful while moving — a
  /// stationary phone has no course to report.
  final double headingDeg;
  final double speedMps;

  /// When the GPS chip produced the fix, not when the app read it.
  ///
  /// Kept distinct from `DateTime.now()` because a fix can be served from a
  /// cache seconds old, and a stamp claiming a time the reading does not have
  /// would be a lie in an audit trail.
  final DateTime? capturedAt;

  /// Many devices report 0 with 0 accuracy when they have no altitude at all,
  /// which is indistinguishable from genuine sea level. Treated as unknown
  /// rather than shown as a real reading.
  bool get hasAltitude => altitudeM != 0 || altitudeAccuracyM > 0;

  bool isWithin(double targetLat, double targetLng, double radiusM) {
    final d = Geolocator.distanceBetween(lat, lng, targetLat, targetLng);
    return d <= radiusM;
  }

  /// Degrees, minutes, seconds. Delegated to [Fmt] because a stored tree is
  /// shown the same way and only has plain coordinates to format — two copies of
  /// this would drift apart.
  String get latDms => Fmt.latDms(lat);
  String get lngDms => Fmt.lngDms(lng);
}

class LocationFailure implements Exception {
  const LocationFailure(this.problem, this.message);

  final LocationProblem problem;
  final String message;

  @override
  String toString() => message;
}

/// The platform calls [LocationService] depends on.
///
/// Geolocator exposes only static methods, which cannot be replaced in a test.
/// Putting them behind this seam is what lets every failure path — a refused
/// permission, a fix that never arrives, two requests racing — be exercised
/// without a phone.
abstract class LocationBackend {
  const LocationBackend();

  Future<bool> isServiceEnabled();
  Future<LocationPermission> checkPermission();
  Future<LocationPermission> requestPermission();
  Future<Position> currentPosition(LocationSettings settings);
  Future<Position?> lastKnownPosition();
  Stream<Position> positionStream(LocationSettings settings);

  /// Whether the user granted precise or only approximate location. Android
  /// 12+ lets a user pick "Approximate", which is accurate to a few
  /// kilometres. Defaults to precise so a backend that cannot tell never
  /// blocks anyone.
  Future<LocationAccuracyStatus> accuracyStatus() async =>
      LocationAccuracyStatus.precise;
}

class GeolocatorBackend extends LocationBackend {
  const GeolocatorBackend();

  @override
  Future<bool> isServiceEnabled() => Geolocator.isLocationServiceEnabled();

  @override
  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();

  @override
  Future<LocationPermission> requestPermission() =>
      Geolocator.requestPermission();

  @override
  Future<Position> currentPosition(LocationSettings settings) =>
      Geolocator.getCurrentPosition(locationSettings: settings);

  @override
  Future<Position?> lastKnownPosition() => Geolocator.getLastKnownPosition();

  @override
  Stream<Position> positionStream(LocationSettings settings) =>
      Geolocator.getPositionStream(locationSettings: settings);

  @override
  Future<LocationAccuracyStatus> accuracyStatus() async {
    try {
      return await Geolocator.getLocationAccuracy();
    } catch (_) {
      // Not supported on this platform: assume precise rather than block.
      return LocationAccuracyStatus.precise;
    }
  }
}

/// GPS access with the checks the tree flow depends on.
///
/// Two things matter here beyond simply reading a coordinate:
///
///   - [Position.isMocked] tells us a spoofing app supplied the fix. That is
///     the single cheapest and strongest anti-fraud signal available on
///     Android, and the server treats it as disqualifying.
///   - Accuracy is sampled repeatedly. A first GPS fix is often 50-100 m out,
///     which would fail a 30 m radius check for an honest user standing right
///     next to their tree.
class LocationService {
  const LocationService({this.backend = const GeolocatorBackend()});

  final LocationBackend backend;

  static const _settings = LocationSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 0,
    timeLimit: Duration(seconds: 20),
  );

  /// The permission check currently running, shared by every caller.
  ///
  /// The plant screen starts a live position stream and a precise fix in the
  /// same frame, and on a first run both found permission undecided and both
  /// asked the OS for it. Android allows one request at a time and the plugin
  /// throws `PermissionRequestInProgressException` for the second, so one of the
  /// two silently failed — and when it was the stream, the map had no position
  /// and sat on "Finding you" with nothing to say why. Sharing one in-flight
  /// request means everyone waits for the same answer.
  static Future<void>? _permissionInFlight;

  Future<void> ensureReady() {
    final running = _permissionInFlight;
    if (running != null) return running;

    final started = _ensureReady().whenComplete(() => _permissionInFlight = null);
    _permissionInFlight = started;
    return started;
  }

  Future<void> _ensureReady() async {
    if (!await backend.isServiceEnabled()) {
      throw const LocationFailure(
        LocationProblem.serviceDisabled,
        'Turn on location services to continue.',
      );
    }

    var permission = await backend.checkPermission();
    if (permission == LocationPermission.denied) {
      try {
        permission = await backend.requestPermission();
      } on PermissionRequestInProgressException {
        // Something else in the app is already showing the dialog. Wait for the
        // person to answer it, then read the result rather than asking again.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        permission = await backend.checkPermission();
      }
    }

    if (permission == LocationPermission.deniedForever) {
      throw const LocationFailure(
        LocationProblem.permissionDeniedForever,
        'Location permission is blocked. Enable it for Dhara in system settings.',
      );
    }
    if (permission == LocationPermission.denied) {
      throw const LocationFailure(
        LocationProblem.permissionDenied,
        'Dhara needs your location to confirm you are at the tree.',
      );
    }
  }

  static bool _granted(LocationPermission p) =>
      p == LocationPermission.whileInUse || p == LocationPermission.always;

  /// Collects several fixes and keeps the most accurate one.
  ///
  /// [onProgress] reports the best accuracy seen so far so the UI can show a
  /// live "getting a precise fix" indicator instead of freezing.
  Future<LocationFix> bestFix({
    double targetAccuracyM = 15,
    int maxSamples = 5,
    Duration budget = const Duration(seconds: 18),
    Duration sampleGap = const Duration(milliseconds: 700),
    void Function(double accuracyM, int sample)? onProgress,
    bool resolveAddress = false,
  }) async {
    await ensureReady();

    // With only approximate access the fix is a few kilometres wide, so the
    // sampling below could never reach a 20 m reading and the screen would
    // ask the user to retry forever. Say what is actually wrong instead.
    if (await backend.accuracyStatus() == LocationAccuracyStatus.reduced) {
      throw const LocationFailure(
        LocationProblem.inaccurate,
        'Dhara only has your approximate location. Turn on "Use precise '
        'location" for Dhara in your phone\u2019s Settings, then try again.',
      );
    }

    final deadline = DateTime.now().add(budget);
    Position? best;
    var samples = 0;

    while (samples < maxSamples && DateTime.now().isBefore(deadline)) {
      Position position;
      try {
        position = await backend.currentPosition(_settings);
      } on TimeoutException {
        break;
      } catch (_) {
        if (samples == 0) {
          throw const LocationFailure(
            LocationProblem.unknown,
            'Could not read your location. Step outside and try again.',
          );
        }
        break;
      }

      samples++;

      // Reject a spoofed fix immediately: no later sample can restore trust in
      // a device that is actively faking its position.
      if (position.isMocked) {
        throw const LocationFailure(
          LocationProblem.mocked,
          'Your device is reporting a fake location. Turn off any GPS spoofing '
          'app. (Android emulators report a simulated location, so use a real '
          'phone for this step.)',
        );
      }

      if (best == null || position.accuracy < best.accuracy) {
        best = position;
      }
      onProgress?.call(best.accuracy, samples);

      if (best.accuracy <= targetAccuracyM) break;

      await Future<void>.delayed(sampleGap);
    }

    if (best == null) {
      throw const LocationFailure(
        LocationProblem.timeout,
        'Could not get a GPS fix. Move to an open area and try again.',
      );
    }

    String? address;
    if (resolveAddress) {
      address = await describe(best.latitude, best.longitude);
    }

    return LocationFix.fromPosition(best, address: address, samples: samples);
  }

  /// A single quick fix, used where precision is not critical (for example
  /// tagging a handover location).
  Future<LocationFix?> quickFix() async {
    try {
      await ensureReady();
      final position = await backend.currentPosition(
        const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 8),
        ),
      );
      return LocationFix.fromPosition(position);
    } catch (_) {
      // Handovers still work without coordinates; distance checks are skipped.
      return null;
    }
  }

  /// The device's cached position, without asking for anything.
  ///
  /// Used to put the map somewhere sensible straight away while a precise fix
  /// settles. It never prompts: with no permission yet it simply returns null.
  /// Display only — it can be minutes old, so it is never submitted.
  Future<LocationFix?> lastKnown() async {
    try {
      if (!await backend.isServiceEnabled()) return null;
      if (!_granted(await backend.checkPermission())) return null;
      final cached = await backend.lastKnownPosition();
      return cached == null ? null : LocationFix.fromPosition(cached);
    } catch (_) {
      return null;
    }
  }

  /// A coarse position for background context such as local air quality.
  ///
  /// Never prompts, so opening the dashboard cannot throw a permission dialog at
  /// someone who has not asked for anything. Returns null unless access was
  /// already granted. Low accuracy is deliberate: the air data it feeds is a
  /// regional model, and a coarse read is faster and lighter on the battery.
  Future<LocationFix?> passiveFix({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      if (!await backend.isServiceEnabled()) return null;
      if (!_granted(await backend.checkPermission())) return null;

      final cached = await backend.lastKnownPosition();
      if (cached != null) return LocationFix.fromPosition(cached);

      final position = await backend.currentPosition(
        LocationSettings(accuracy: LocationAccuracy.low, timeLimit: timeout),
      );
      return LocationFix.fromPosition(position);
    } catch (_) {
      return null;
    }
  }

  /// Live position updates, for a map that tracks the user as they walk.
  ///
  /// Permission is settled before subscribing: `getPositionStream` emits an
  /// error rather than prompting, so a cold subscribe would just fail on a
  /// first run. Accuracy is carried through so the map can draw the real
  /// uncertainty circle instead of implying a pinpoint.
  ///
  /// Display only, so it asks for `high` rather than navigation-grade accuracy:
  /// the submitted reading comes from [bestFix], and the more demanding setting
  /// only made this stream slower to produce its first point indoors.
  Stream<LocationFix> watch({int distanceFilterM = 2}) async* {
    await ensureReady();

    yield* backend
        .positionStream(
          LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: distanceFilterM,
          ),
        )
        .map((p) => LocationFix.fromPosition(p));
  }

  /// Live distance to a fixed point, for the "walk closer" indicator.
  Stream<double> distanceTo(double lat, double lng) {
    return backend
        .positionStream(
          const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 1,
          ),
        )
        .map((p) => Geolocator.distanceBetween(p.latitude, p.longitude, lat, lng));
  }

  /// Reverse geocodes to a short human label ("Koramangala, Bengaluru").
  ///
  /// Purely cosmetic: the server never trusts a client-supplied address, so a
  /// failure here degrades to null rather than blocking the flow.
  Future<String?> describe(double lat, double lng) async {
    try {
      final places =
          await geo.Geocoding().placemarkFromCoordinates(lat, lng);
      if (places.isEmpty) return null;
      final p = places.first;
      final parts = <String?>[
        p.subLocality,
        p.locality,
        p.administrativeArea,
      ]
          .whereType<String>()
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList();
      return parts.isEmpty ? null : parts.join(', ');
    } catch (_) {
      return null;
    }
  }

  Future<void> openSettings() => Geolocator.openAppSettings();

  Future<void> openLocationSettings() => Geolocator.openLocationSettings();

  double distanceBetween(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) =>
      Geolocator.distanceBetween(lat1, lng1, lat2, lng2);
}

final locationServiceProvider =
    Provider<LocationService>((ref) => const LocationService());
