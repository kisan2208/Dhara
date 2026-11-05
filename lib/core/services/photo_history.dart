import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/phash.dart';

/// A local note that a very similar photo was already used on this device.
class RepeatMatch {
  const RepeatMatch({required this.distance, required this.usedAt});

  final int distance;
  final DateTime usedAt;
}

/// Remembers perceptual hashes of photos the user chose to submit, so reuse can
/// be flagged before upload.
///
/// ADVISORY: this lives on the phone, so it can be cleared or bypassed and it
/// proves nothing. Its only job is to stop an honest user wasting a submission
/// on a photo the server would reject as a duplicate. Only hashes and times are
/// stored, never the images.
class PhotoHistory {
  PhotoHistory({
    this.threshold = 8,
    this.maxEntries = 50,
    this.maxAge = const Duration(days: 90),
  });

  static const _key = 'treeguard.recent_photo_hashes';

  /// Mirrors the server's default `fraud.phash_hamming_threshold`.
  final int threshold;
  final int maxEntries;
  final Duration maxAge;
  SharedPreferences? _prefs;

  Future<SharedPreferences> get _store async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<List<({String hash, DateTime at})>> _load(DateTime now) async {
    final raw = (await _store).getStringList(_key) ?? const <String>[];
    final out = <({String hash, DateTime at})>[];
    for (final line in raw) {
      final i = line.indexOf('|');
      if (i <= 0) continue;
      final ms = int.tryParse(line.substring(i + 1));
      if (ms == null) continue;
      final at = DateTime.fromMillisecondsSinceEpoch(ms);
      if (now.difference(at) > maxAge) continue;
      out.add((hash: line.substring(0, i), at: at));
    }
    return out;
  }

  /// Closest earlier photo within [threshold], if any. Never throws: a storage
  /// problem must not block a submission.
  Future<RepeatMatch?> findRepeat(String phash, {DateTime? now}) async {
    if (phash.isEmpty) return null;
    try {
      RepeatMatch? best;
      for (final e in await _load(now ?? DateTime.now())) {
        final d = PHash.hamming(phash, e.hash);
        if (d <= threshold && (best == null || d < best.distance)) {
          best = RepeatMatch(distance: d, usedAt: e.at);
        }
      }
      return best;
    } catch (_) {
      return null;
    }
  }

  Future<void> remember(String phash, {DateTime? now}) async {
    if (phash.isEmpty) return;
    try {
      final clock = now ?? DateTime.now();
      final kept = await _load(clock);
      kept.add((hash: phash, at: clock));
      final trimmed = kept.length > maxEntries ? kept.sublist(kept.length - maxEntries) : kept;
      await (await _store).setStringList(
        _key,
        [for (final e in trimmed) '${e.hash}|${e.at.millisecondsSinceEpoch}'],
      );
    } catch (_) {
      // Advisory feature; losing a record is acceptable.
    }
  }
}

final photoHistoryProvider = Provider<PhotoHistory>((ref) => PhotoHistory());
