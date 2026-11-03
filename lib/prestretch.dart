import 'dart:convert';
import 'dart:io';

import 'library.dart';

/// Studio-clean vocals and beats. Each vocal and beat in a mashup set is
/// stretched onto the grid and tuned once, ahead of time, with Rubber Band
/// (keeping the singer's formants; a beat's stems are summed first), and the
/// mixer then plays that file untouched, with no stretcher of its own
/// colouring the voice or smearing the drums. Until a vocal's file is ready the set
/// uses the mixer's own stretcher, and [onReady] says when to lay out again.
class Prestretcher {
  final MusicLibrary lib;
  void Function()? onReady;
  Prestretcher(this.lib);

  static String get dir => '${MusicLibrary.home}/Library/Caches/Vibeline/prestretch';

  final _queue = <String, Map<String, dynamic>>{}; // key -> job, earliest in the set first
  final _failed = <String>{};
  final _tries = <String, int>{};
  bool _running = false;
  bool get busy => _running || _queue.isNotEmpty;

  /// [json] with every vocal clip that has a ready file swapped for it; the
  /// rest are queued.
  Map<String, dynamic> apply(Map<String, dynamic> json) {
    final clips = (json['clips'] as List).cast<Map<String, dynamic>>();
    final out = <Map<String, dynamic>>[];
    for (final c in clips) {
      final warp = (c['warp'] as List?)?.map((w) => (w as List).cast<num>()).toList();
      if (warp == null || warp.length < 2 || c['pitchRamp'] != null) {
        out.add(c);
        continue;
      }
      final m0 = warp.first[0].toDouble();
      final vocal = c['bus'] == 1;
      final mix = ((c['mix'] as List?) ?? const []).cast<String>();
      final key = _key([c['path'] as String, ...mix].join('+'), warp, (c['pitchCents'] as num).toDouble());
      final file = '$dir/$key.flac';
      if (File(file).existsSync()) {
        out.add({
          ...c,
          'path': file,
          'outStart': m0,
          'srcStart': ((c['outStart'] as num).toDouble() - m0).clamp(0.0, double.infinity),
          'srcEnd': warp.last[0].toDouble() - m0,
          'rate': 1.0,
          'pitchCents': 0.0,
          // A beat's file is saved 6 dB down so its summed stems can't clip.
          if (!vocal) 'gainDb': ((c['gainDb'] as num?) ?? 0).toDouble() + 6.0206,
        }
          ..remove('warp')
          ..remove('pitchRamp')
          ..remove('mix'));
        continue;
      }
      out.add(c);
      if (!_failed.contains(key)) {
        _queue.putIfAbsent(key, () => {
              'input': c['path'],
              if (mix.isNotEmpty) 'mix': mix,
              if (!vocal) 'beat': true, // see prestretch() in vibeline_ai.py
              'warp': warp,
              'cents': c['pitchCents'],
              'out': file,
              'at': m0,
            });
      }
    }
    _work();
    return {...json, 'clips': out};
  }

  /// The same vocal, beat map shape and tuning give the same file, wherever
  /// in the set it plays.
  static String _key(String path, List<List<num>> warp, double cents) {
    // v2: the standard Rubber Band engine (v1's drifted off the beat map).
    final m0 = warp.first[0], s = StringBuffer('v2|$path|${cents.toStringAsFixed(2)}');
    for (final w in warp) {
      s.write('|${(w[0] - m0).toStringAsFixed(4)},${w[1].toStringAsFixed(4)}');
    }
    var h1 = 0x811c9dc5, h2 = 0x01000193;
    for (final c in utf8.encode(s.toString())) {
      h1 = ((h1 ^ c) * 0x01000193) & 0xffffffff;
      h2 = ((h2 ^ c) * 0x5bd1e995 + 7) & 0xffffffff;
    }
    return '${h1.toRadixString(16).padLeft(8, '0')}${h2.toRadixString(16).padLeft(8, '0')}';
  }

  /// One vocal at a time, earliest in the set first (about 5 s each).
  Future<void> _work() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final next = _queue.entries.reduce((a, b) => (a.value['at'] as num) <= (b.value['at'] as num) ? a : b);
        _queue.remove(next.key);
        final job = File('${Directory.systemTemp.path}/vibeline-pre-${next.key}.json');
        await Directory(dir).create(recursive: true);
        await job.writeAsString(jsonEncode(next.value));
        var ok = false;
        String? error;
        await for (final row in lib.prestretch([job.path])) {
          if (row['type'] == 'prestretch') {
            ok = row['ok'] == true;
            error = row['error'] as String?;
          }
        }
        if (ok) {
          onReady?.call();
        } else {
          _log('${next.value['input']}: ${error ?? 'no result'}');
          // One more go (a hiccup, e.g. memory while stems split); after
          // that it keeps the mixer's own stretcher.
          if ((_tries[next.key] = (_tries[next.key] ?? 0) + 1) < 2) {
            _queue[next.key] = next.value;
          } else {
            _failed.add(next.key);
          }
        }
      }
    } finally {
      _running = false;
    }
  }

  /// Why a vocal couldn't be made clean, for fixing it later.
  static void _log(String line) {
    try {
      final f = File('${MusicLibrary.home}/Library/Logs/D-Jay Noodles/prestretch.log');
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('${DateTime.now().toIso8601String()} $line\n', mode: FileMode.append);
    } catch (_) {}
  }

  /// Files not played for a fortnight.
  static void prune() {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return;
      final cutoff = DateTime.now().subtract(const Duration(days: 14));
      for (final f in d.listSync().whereType<File>()) {
        if (f.statSync().accessed.isBefore(cutoff) || f.path.endsWith('.part.flac')) f.deleteSync();
      }
    } catch (_) {}
  }
}
