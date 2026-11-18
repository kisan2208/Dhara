import 'dart:async';

import 'package:dhara/core/services/location.dart';
import 'package:geolocator/geolocator.dart';

Position pos({
  double lat = 12.9716,
  double lng = 77.5946,
  double accuracy = 8,
  bool mocked = false,
}) =>
    Position(
      longitude: lng,
      latitude: lat,
      timestamp: DateTime.utc(2026, 10, 17, 12),
      accuracy: accuracy,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
      isMocked: mocked,
    );

/// A stand-in for the phone.
///
/// [requestPermission] behaves like the real Android plugin: it takes time (the
/// dialog) and a second request made while the first is open is refused with
/// `PermissionRequestInProgressException`. That is the failure the plant
/// screen hit on a first run, so the fake has to be able to produce it.
class FakeLocationBackend extends LocationBackend {
  bool serviceEnabled = true;
  LocationPermission permission = LocationPermission.denied;

  /// What the person taps in the dialog.
  LocationPermission answer = LocationPermission.whileInUse;
  Duration dialogTime = const Duration(milliseconds: 40);

  int requestCalls = 0;
  int checkCalls = 0;
  int currentCalls = 0;
  LocationSettings? lastCurrentSettings;
  LocationSettings? lastStreamSettings;

  Position? cached;

  /// Each call to `currentPosition` takes the next of these; the last repeats.
  List<FutureOr<Position> Function()> readings = [() => pos()];

  final stream = StreamController<Position>.broadcast();

  bool _dialogOpen = false;

  @override
  Future<bool> isServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermission> checkPermission() async {
    checkCalls++;
    return permission;
  }

  @override
  Future<LocationPermission> requestPermission() async {
    requestCalls++;
    if (_dialogOpen) {
      throw const PermissionRequestInProgressException(
        'Permissions request is already running.',
      );
    }
    _dialogOpen = true;
    await Future<void>.delayed(dialogTime);
    _dialogOpen = false;
    permission = answer;
    return permission;
  }

  @override
  Future<Position> currentPosition(LocationSettings settings) async {
    lastCurrentSettings = settings;
    final i = currentCalls < readings.length ? currentCalls : readings.length - 1;
    currentCalls++;
    return readings[i]();
  }

  @override
  Future<Position?> lastKnownPosition() async => cached;

  /// What the person chose: precise, or Android's "Approximate".
  LocationAccuracyStatus accuracy = LocationAccuracyStatus.precise;

  @override
  Future<LocationAccuracyStatus> accuracyStatus() async => accuracy;

  @override
  Stream<Position> positionStream(LocationSettings settings) {
    lastStreamSettings = settings;
    return stream.stream;
  }

  /// Simulates the dialog being open because something else asked.
  Future<void> openDialogElsewhere() async {
    _dialogOpen = true;
    await Future<void>.delayed(dialogTime);
    _dialogOpen = false;
    permission = answer;
  }
}
