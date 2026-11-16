// Times a first mashup set on a Mac that has never run the app (run with
// HOME pointing at an empty profile). Skipped unless VIBELINE_REAL=1.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/mashup.dart';
import 'package:vibeline/vibe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('fresh Mac first set', () async {
    if (Platform.environment['VIBELINE_REAL'] != '1') return;
    final sw = Stopwatch()..start();
    String t() => '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(0)}s';
    final lib = MusicLibrary()
      ..useMusicApp = false
      ..wholeMac = false
      ..folder = Platform.environment['VIBELINE_FOLDER']!;
    await lib.scan();
    print('${t()} scanned ${lib.tracks.length} songs');
    final vibe = parseTheme('Party, mix genres, my Shazams', '');
    final maker = MashupMaker(vibe);
    final count = maker.mashupCount;
    final rng = math.Random(3);
    var pool = lib.tracks.toList();
    if (vibe.shazamOnly) {
      final mine = pool.where((t) => t.shazam).toList();
      if (mine.length >= 8) pool = mine;
    }
    final ranked = pool.map((t) => (t, tagScore(t, vibe, rng))).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    final r = ranked.map((e) => e.$1).toList();
    final singers = r.where(vibe.sings).toList();
    final anchorOn = Platform.environment['VIBELINE_ANCHOR_MODE'] != '0';
    final wanted = anchorOn ? math.max(240, count * 6) : math.max(80, count * 4);
    final candidates = MusicLibrary.limitPool({...singers, ...r.where((t) => !vibe.themed || !vibe.sings(t)).take(wanted)}.toList());
    final first = MusicLibrary.songsToAnalyseFirst(candidates, minReady: wanted, matchMin: count * 4, matches: null);
    print('${t()} count $count · candidates ${candidates.length} · analysing first ${first.length}');
    var last = 0;
    await lib.analyze(first, (d, n) {
      if (d - last >= 40 || d == n) {
        last = d;
        print('${t()}   analysed $d / $n');
      }
    });
    final ready = candidates.where((t) => t.analysis != null).toList();
    print('${t()} analysis done · ${ready.length} ready');
    final session = MashupSession.start(maker, ready)..anchorMode = anchorOn;
    await session.fill(lib, count, (s) {
      print('${t()}   $s');
    }, () {
      final plan = session.layout();
      print('${t()} MASHUPS ${session.mashups.length} of $count · set ${plan.duration.toStringAsFixed(0)}s');
    });
    print('${t()} fill done · ${session.mashups.length} mashups');
  }, timeout: const Timeout(Duration(minutes: 60)));
}
