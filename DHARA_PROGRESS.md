# Dhara Progress — Flutter / on-device (TreeGuard P0)

This branch (`feature/treeguard-flutter`) is a Flutter/Dart-only checkpoint, branched from `main`.
It deliberately contains NO backend, Appwrite, database, schema, API or deployment changes. The server-side
TreeGuard work (P1) lives only on the `feature/treeguard-local` branch and is not included here.

## TreeGuard P0 — on-device photo checks (advisory only)
All checks run on-device and never block a submission; the server remains the authority. No new pub dependency.

- `lib/core/utils/photo_precheck.dart`: readable/corrupt check, resolution, blur estimate (Laplacian variance),
  dark/overexposed, and EXIF capture-time/camera/GPS presence. Thresholds are UNCALIBRATED; no accuracy claim.
  Missing EXIF is info, never a warning.
- `lib/core/services/photo_history.dart`: local-only list of perceptual hashes (max 50, 90 days, hashes + times
  only) to warn about a photo already used on this phone. Bypassable; advisory only.
- `lib/core/utils/scene_hint.dart`: pure `classifyScene()` mapping ML Kit labels to
  PLANT_LIKELY / UNRELATED_IMAGE_SUSPECTED / UNCERTAIN / ANALYSIS_UNAVAILABLE. Weak/mixed evidence is UNCERTAIN,
  never "unrelated". Thresholds uncalibrated.
- `lib/core/services/vision.dart`: added `analyseScene()` (never throws) and `rawLabels()`, with a one-photo cache
  so ML Kit runs once per photo. Existing `checkPlant()` output and request fields unchanged. A debug-only label log
  (kDebugMode) was added for on-device tuning.
- `lib/ui/widgets/photo_review.dart`: preview + advisory notes + Use/Retake; `capturePhotoWithReview()` is a drop-in
  for `CameraCaptureScreen.push`, so the submission flow and request format are unchanged. Only an unreadable file
  blocks "Use photo". The scene hint loads separately with a 5 s cut-off to UNAVAILABLE.
- `lib/ui/screens/trees/plant_tree_screen.dart`, `verify_tree_screen.dart`: switched the capture call to
  `capturePhotoWithReview` (one import + one call each). No other change.

Tests: `test/photo_precheck_test.dart`, `test/scene_hint_test.dart`.

## Debug-only test bench (not wired into the app)
`lib/dev/treeguard_bench.dart` + `treeguard_bench_screen.dart`: a developer tool to run the on-device checks over a
batch of local sample images and export CSV/JSON. It has NO entry point in the app (its launcher was removed — see
red-overlay note). Reachable only if a developer adds an entry point. Tests: `test/dev/treeguard_bench_test.dart`.

## Red overlay bug (fixed, Flutter-side)
A debug-only `TreeGuardDebugLauncher` was briefly mounted in `MaterialApp.router(builder:)`. Its
`FloatingActionButton(tooltip:)` needs an Overlay ancestor, which `MaterialApp.builder` is above, so in debug builds
it threw and Flutter painted its full-screen debug error box (translucent dark red) over every screen. Fixed by
keeping `lib/main.dart` at its original, launcher-free version (this branch's `main.dart` == the committed one).
Verified on a Samsung SM-E156B: Home/Trees/Scan/Rewards/You all render normally; no release build was ever affected.

## Known issues / not done
- Excluded failing test: `test/dev/treeguard_launcher_test.dart` (tap test) targets the removed launcher and times
  out. It is NOT part of this checkpoint. Delete or rewrite it alongside any future bench entry point.
- Scene/quality thresholds are uncalibrated; need a labelled photo set before any accuracy claim.
- Not device-tested: camera-permission-denied path; local repeat-photo warning (needs a real submission).
- Unrelated, uninvestigated: Trees header "2 Planted / 2 Alive" vs list "No trees yet".
