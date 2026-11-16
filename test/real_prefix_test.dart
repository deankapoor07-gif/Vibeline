// How much of a set stays the same when mashups are added one by one.
// Skipped unless VIBELINE_REAL=1. VIBELINE_ANCHOR_MODE=0 tests classic layout.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/mashup.dart';
import 'package:vibeline/vibe.dart';

double firstDiff(Map<String, dynamic> a, Map<String, dynamic> b) {
  final ca = (a['clips'] as List).map((c) => jsonEncode(c)).toList();
  final cb = (b['clips'] as List).map((c) => jsonEncode(c)).toList();
  final sa = ca.toSet(), sb = cb.toSet();
  var t = double.infinity;
  for (final c in [...ca.where((x) => !sb.contains(x)), ...cb.where((x) => !sa.contains(x))]) {
    final m = jsonDecode(c) as Map<String, dynamic>;
    t = math.min(t, (m['outStart'] as num).toDouble());
  }
  return t;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('prefix stability', () async {
    if (Platform.environment['VIBELINE_REAL'] != '1') return;
    final lib = MusicLibrary()..useMusicApp = false;
    await lib.scan();
    final anchorOn = Platform.environment['VIBELINE_ANCHOR_MODE'] != '0';
    final vibe = parseVibe(Platform.environment['VIBELINE_VIBE'] ?? 'party, mix genres, my shazams');
    final maker = MashupMaker(vibe, seed: int.tryParse(Platform.environment['VIBELINE_RNG'] ?? '') ?? 5);
    final rng = math.Random(5);
    var tracks = lib.tracks.where((t) => t.analysis != null || true).toList();
    if (vibe.shazamOnly) {
      final mine = tracks.where((t) => t.shazam).toList();
      if (mine.length >= 8) tracks = mine;
    }
    final ranked = tracks.map((t) => (t, tagScore(t, vibe, rng))).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    final pool = ranked.take(math.max(240, maker.mashupCount * 6)).map((e) => e.$1).toList();
    await lib.analyze(pool, (d, t) {});
    final session = MashupSession.start(maker, pool.where((t) => t.analysis != null).toList())..anchorMode = anchorOn;
    final sw = Stopwatch()..start();
    final added = <int>[];
    await session.fill(lib, maker.mashupCount, (s) {}, () => added.add(sw.elapsed.inSeconds));
    print('mode ${anchorOn ? 'anchor' : 'classic'} · ${session.mashups.length} mashups · added at $added s');
    final all = [...session.mashups];
    final plans = <Map<String, dynamic>>[];
    final starts = <List<double>>[];
    for (var n = 1; n <= all.length; n++) {
      session.mashups..clear()..addAll(all.take(n));
      final p = session.layout();
      plans.add(p.renderJson);
      starts.add([for (final m in p.mashups) m.start]);
      print('n=$n duration ${p.duration.toStringAsFixed(1)} starts ${starts.last.map((s) => s.toStringAsFixed(0)).join(',')}');
    }
    for (var n = 1; n < all.length; n++) {
      final d = firstDiff(plans[n - 1], plans[n]);
      final dur = (plans[n - 1]['duration'] as num).toDouble();
      print('add #${n + 1}: first change at ${d.toStringAsFixed(1)} s of ${dur.toStringAsFixed(1)} (lead before end ${(dur - d).toStringAsFixed(1)} s; mashup $n started ${starts[n - 1][n - 1].toStringAsFixed(1)})');
    }
  }, timeout: const Timeout(Duration(minutes: 40)));
}
