import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/vision.dart';
import '../core/utils/scene_hint.dart';
import 'treeguard_bench.dart';

/// Debug-only screen for trying the on-device TreeGuard checks against a
/// batch of photos already on the device.
///
/// This never appears in a release build: its only entry point,
/// [TreeGuardDebugLauncher], is gated by `kDebugMode`, and the screen itself
/// repeats that check as a second line of defence. Nothing it does leaves the
/// device — no Appwrite call, no upload — and it never touches the real tree
/// submission flow.
class TreeGuardBenchScreen extends ConsumerStatefulWidget {
  const TreeGuardBenchScreen({
    super.key,
    this.imageLister,
    this.exporter,
    this.qualityCheck,
  });

  /// Injectable for tests; defaults to [listSampleImages].
  final Future<List<File>> Function()? imageLister;

  /// Injectable for tests; defaults to [exportResults].
  final Future<File> Function(
    List<BenchResult> results, {
    required bool asJson,
  })?
  exporter;

  /// Injectable for tests, so they do not spawn a real isolate; production
  /// always uses the default (`compute`-backed) check. See [QualityCheck].
  final QualityCheck? qualityCheck;

  @override
  ConsumerState<TreeGuardBenchScreen> createState() =>
      _TreeGuardBenchScreenState();
}

class _TreeGuardBenchScreenState extends ConsumerState<TreeGuardBenchScreen> {
  List<File> _available = [];
  final Set<String> _selected = {};
  List<BenchResult> _results = [];
  bool _loadingList = true;
  bool _running = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  Future<void> _loadImages() async {
    try {
      final files = await (widget.imageLister ?? listSampleImages)();
      if (!mounted) return;
      setState(() {
        _available = files;
        _selected
          ..clear()
          ..addAll(files.map((f) => f.path));
        _loadingList = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = '$e';
        _loadingList = false;
      });
    }
  }

  Future<void> _run() async {
    final chosen = _available.where((f) => _selected.contains(f.path)).toList();
    if (chosen.isEmpty) return;
    setState(() {
      _running = true;
      _results = [];
    });
    final vision = ref.read(visionProvider);
    final results = await runBenchAll(
      chosen,
      vision,
      qualityCheck: widget.qualityCheck,
    );
    if (!mounted) return;
    setState(() {
      _results = results;
      _running = false;
    });
  }

  Future<void> _export(bool asJson) async {
    if (_results.isEmpty) return;
    final file = await (widget.exporter ?? exportResults)(
      _results,
      asJson: asJson,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Saved to ${file.path}')));
  }

  @override
  Widget build(BuildContext context) {
    // Defence in depth: the only way to reach this screen is already gated.
    if (!kDebugMode) return const SizedBox.shrink();

    final summary = summarizeBench(_results);
    return Scaffold(
      appBar: AppBar(title: const Text('TreeGuard test bench (debug)')),
      body: _loadingList
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Runs the on-device plant hint and photo-quality checks '
                  'against images already on this device. Nothing here is '
                  'uploaded; results stay on the device.',
                ),
                const SizedBox(height: 8),
                if (_loadError != null)
                  Text(
                    'Could not list images: $_loadError',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                FutureBuilder<Directory>(
                  future: sampleImagesDir(),
                  builder: (context, snap) => Text(
                    'Copy sample photos into: ${snap.data?.path ?? '…'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 12),
                if (_available.isEmpty)
                  const Text(
                    'No images found. Copy some into the folder above (e.g. '
                    'with adb push) and reopen this screen.',
                  )
                else ...[
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => setState(() {
                          _selected
                            ..clear()
                            ..addAll(_available.map((f) => f.path));
                        }),
                        child: const Text('Select all'),
                      ),
                      TextButton(
                        onPressed: () => setState(_selected.clear),
                        child: const Text('Select none'),
                      ),
                    ],
                  ),
                  for (final f in _available)
                    CheckboxListTile(
                      value: _selected.contains(f.path),
                      title: Text(f.uri.pathSegments.last),
                      onChanged: (v) => setState(() {
                        if (v ?? false) {
                          _selected.add(f.path);
                        } else {
                          _selected.remove(f.path);
                        }
                      }),
                    ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _running || _selected.isEmpty ? null : _run,
                    child: Text(_running ? 'Running…' : 'Run selected'),
                  ),
                ],
                if (_results.isNotEmpty) ...[
                  const Divider(height: 32),
                  Text(
                    'Summary',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Total: ${summary.total}   '
                    'Avg: ${summary.averageMs.toStringAsFixed(0)} ms   '
                    'Errors: ${summary.errorCount}   '
                    'Unreadable: ${summary.unreadableCount}',
                  ),
                  for (final h in PlantHint.values)
                    Text('${h.name}: ${summary.counts[h] ?? 0}'),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      OutlinedButton(
                        onPressed: () => _export(false),
                        child: const Text('Export CSV'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: () => _export(true),
                        child: const Text('Export JSON'),
                      ),
                    ],
                  ),
                  const Divider(height: 32),
                  for (final r in _results) _ResultCard(result: r),
                ],
              ],
            ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final BenchResult result;

  @override
  Widget build(BuildContext context) {
    final labelsText = result.labels
        .map((l) => '${l.label} ${l.confidence.toStringAsFixed(2)}')
        .join(', ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.fileName,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(result.hint.name),
            if (labelsText.isNotEmpty) Text('Labels: $labelsText'),
            if (result.qualityNotes.isNotEmpty)
              Text('Quality: ${result.qualityNotes.join(', ')}'),
            Text('${result.elapsedMs} ms'),
            if (result.error != null)
              Text(
                'Error: ${result.error}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }
}

/// Wraps the app with a small floating button that opens the test bench.
///
/// A no-op outside debug builds: in release, `kDebugMode` is a compile-time
/// constant `false`, so this returns [child] unchanged and the button is
/// never built. This is the only way to reach [TreeGuardBenchScreen].
///
/// It sits in `MaterialApp.builder`, i.e. ABOVE the app's Navigator and its
/// Overlay. Two consequences, both of which once broke the whole app in debug
/// builds (a full-screen translucent red ErrorWidget):
/// - nothing here may need an Overlay ancestor, so no `tooltip:` (Tooltip
///   requires one); the label is provided through Semantics instead;
/// - `Navigator.of(context)` cannot find a navigator from here, so the route is
///   pushed through [navigatorKey], the router's own navigator.
class TreeGuardDebugLauncher extends StatelessWidget {
  const TreeGuardDebugLauncher({
    super.key,
    required this.child,
    required this.navigatorKey,
  });

  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return child;
    return Stack(
      children: [
        child,
        Positioned(
          right: 12,
          bottom: 90,
          child: Semantics(
            label: 'TreeGuard test bench (debug)',
            button: true,
            child: FloatingActionButton.small(
              heroTag: 'treeguard_bench_launcher',
              onPressed: () => navigatorKey.currentState?.push(
                MaterialPageRoute(builder: (_) => const TreeGuardBenchScreen()),
              ),
              child: const Icon(Icons.science_outlined),
            ),
          ),
        ),
      ],
    );
  }
}
