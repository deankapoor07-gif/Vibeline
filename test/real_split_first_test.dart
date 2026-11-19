// Times a theme or vibe set made the way the app makes it, on this Mac's
// library: how long until it's made, and how many new songs it had to split.
// Skipped unless VIBELINE_REAL=1. VIBELINE_THEME, VIBELINE_VIBE,
// VIBELINE_ANCHOR_ON=0 to leave the anchor beat off.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/mashup.dart';
import 'package:vibeline/models.dart';
import 'package:vibeline/recent_sets.dart';
import 'package:vibeline/stem_cache.dart';
import 'package:vibeline/vibe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('split-first set', () async {
    final sw = Stopwatch()..start();
    String t() => '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s';
    final lib = MusicLibrary();
    await lib.loadSettings();
    await lib.scan();
    await lib.loadKnown();
    final split0 = lib.tracks.where(StemCache.isSplit).length;
    print('${t()} scanned ${lib.tracks.length} songs · $split0 split already');
    sw.reset();
    final vibe = parseTheme(Platform.environment['VIBELINE_VIBE'] ?? 'party, mix genres', Platform.environment['VIBELINE_THEME'] ?? '');
    fitThemeLength(vibe, vibe.minutesAvailable(lib.tracks, mashups: true));
    final anchorOn = Platform.environment['VIBELINE_ANCHOR_ON'] != '0';
    final maker = MashupMaker(vibe);
    final count = maker.mashupCount;
    final rng = math.Random();
    final ranked = (lib.tracks.map((t) => (t, tagScore(t, vibe, rng))).toList()..sort((a, b) => b.$2.compareTo(a.$2)))
        .map((e) => e.$1)
        .toList();
    // As MainScreen._mashupCandidates.
    final singers = ranked.where(vibe.sings).toList();
    final wanted = anchorOn ? math.max(240, count * 6) : math.max(80, count * 4);
    final limited = MusicLibrary.limitPool({...singers, ...ranked.where((t) => !vibe.themed || !vibe.sings(t)).take(wanted)}.toList());
    final have = limited.toSet();
    final candidates = [...limited, ...ranked.where((t) => t.analysis != null && !have.contains(t) && StemCache.isSplit(t))];
    final bool Function(LibraryTrack)? suits = vibe.themed ? vibe.sings : null;
    final first = MusicLibrary.songsToAnalyseFirst(candidates, minReady: wanted, matchMin: count * 4, matches: suits);
    await lib.analyze(first, (d, n) {});
    fitThemeTempo(vibe, singers);
    final pool = candidates.where((t) => t.analysis != null).toList();
    print('${t()} "${vibe.summary}" · $count mashups · ${pool.length} songs in the pool · analysed ${first.length} first');
    MashupSession.thinFactor = double.tryParse(Platform.environment['VIBELINE_THIN'] ?? '') ?? 1.0;
    final recentDir = Platform.environment['VIBELINE_RECENT_DIR'];
    if (recentDir != null) RecentSets.load(dir: recentDir);
    final session = MashupSession.start(maker, pool)..anchorMode = anchorOn;
    print('${t()} pairings ranked');
    String? last;
    await session.fill(lib, count, (s) {
      if (s.startsWith('Splitting') && s != last) print('${t()}   $s');
      last = s;
    }, () => print('${t()} ${session.mashups.length} of $count made'));
    final split1 = lib.tracks.where(StemCache.isSplit).length;
    print('${t()} DONE ${session.mashups.length} of $count · anchor ${session.anchorMode ? 'on' : 'off'}'
        '${session.anchorTooThin ? ' (too few songs at one tempo)' : ''} · ${session.anchoredAtStart} songs fit the anchor · ${split1 - split0} new songs split');
    for (final m in session.mashups) {
      print('  ${m.vocal.title} OVER ${m.beat.title}');
    }
    if (recentDir != null) RecentSets.record(session.mashups.map((m) => (m.vocal, m.beat)));
    if (session.anchor != null) print('anchor ${session.anchor!.track.title} · split songs that fit it: ${session.anchoredVocals(splitOnly: true)}');
    print('fresh for next time: ${session.freshCandidates(2).map((t) => t.title).join(', ')}');
  }, skip: Platform.environment['VIBELINE_REAL'] != '1', timeout: const Timeout(Duration(minutes: 60)));
}
