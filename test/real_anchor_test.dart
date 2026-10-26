// Builds an anchor-mode mashup set and writes the render plan.
// Skipped unless VIBELINE_REAL=1.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/mashup.dart';
import 'package:vibeline/vibe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('anchor mode set', () async {
    final lib = MusicLibrary()..useMusicApp = false;
    await lib.scan();
    final vibe = parseVibe(Platform.environment['VIBELINE_VIBE'] ?? 'party, mix genres, my shazams');
    final maker = MashupMaker(vibe, seed: 5);
    final rng = math.Random(5);
    // VIBELINE_APPLIKE=1 picks the pool the way the app does (VIBELINE_POOL overrides its size).
    final appLike = Platform.environment['VIBELINE_APPLIKE'] == '1';
    var tracks = lib.tracks.toList();
    if (appLike && vibe.shazamOnly) {
      final mine = tracks.where((t) => t.shazam).toList();
      if (mine.length >= 8) tracks = mine;
    }
    final ranked = tracks.map((t) => (t, tagScore(t, vibe, rng))).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    final pool = ranked.take(appLike ? int.tryParse(Platform.environment['VIBELINE_POOL'] ?? '') ?? math.max(240, maker.mashupCount * 6) : 120).map((e) => e.$1).toList();
    final sw = Stopwatch()..start();
    await lib.analyze(pool, (d, t) {});
    print('analysed ${pool.length} in ${sw.elapsed.inSeconds}s');
    final session = MashupSession.start(maker, pool)..anchorMode = true;
    // VIBELINE_ANCHOR=<title words> uses that song as the anchor.
    final want = Platform.environment['VIBELINE_ANCHOR']?.toLowerCase();
    if (want != null) {
      final t = lib.tracks.firstWhere((t) => t.title.toLowerCase().contains(want));
      expect(await session.setAnchor(t, lib, (_) {}), isNull);
    }
    print('pool ${pool.length} (${pool.where((t) => t.shazam).length} Shazams)');
    await session.fill(lib, int.tryParse(Platform.environment['VIBELINE_COUNT'] ?? '') ?? (appLike ? maker.mashupCount : 4), (s) {}, () {});
    final a = session.anchor!;
    print('ANCHOR: ${a.track.artist} – ${a.track.title} · ${a.tempo.toStringAsFixed(1)} BPM · key ${a.camelot} · loop from bar ${a.loopStart} · gain ${a.gainDb.toStringAsFixed(1)} dB · bass ${a.track.stems?.relative('bass')?.toStringAsFixed(1)} drums ${a.track.stems?.relative('drums')?.toStringAsFixed(1)}');
    final plan = session.layout();
    if (Platform.environment['VIBELINE_INTRO_CHECK'] == '1') {
      String intro(MashupSetPlan pl) => jsonEncode([
            for (final c in (pl.renderJson['clips'] as List).cast<Map<String, dynamic>>())
              if ((c['outStart'] as num) < 16.02) c
          ]);
      final full = intro(plan);
      final all = [...session.mashups];
      for (var n = 1; n < all.length; n++) {
        session.mashups..clear()..addAll(all.take(n));
        print('intro with $n mashups same as with ${all.length}: ${intro(session.layout()) == full}');
      }
      session.mashups..clear()..addAll(all);
    }
    for (final m in plan.mashups) {
      print('${m.vocal.title} (vocal ${m.vocalShift >= 0 ? '+' : ''}${m.vocalShift} st) OVER ${m.beat.title} (beat ${m.beatShift >= 0 ? '+' : ''}${m.beatShift} st, key ${m.beatGrid.camelot}) · '
          'vocal ${m.vocalIn.toStringAsFixed(1)}–${m.vocalOut.toStringAsFixed(1)}s (${m.vocalBars} bars) · '
          'beat bass ${m.beat.stems?.relative('bass')?.toStringAsFixed(1)} · gaps (drums, bass) ${MashupMaker.dropouts(m.beat, m.beatGrid, m.beatStart, m.beatStart + m.totalBars)}');
    }
    print(plan.summary);
    final out = Platform.environment['VIBELINE_PLAN_OUT'];
    if (out != null) File(out).writeAsStringSync(jsonEncode({...plan.renderJson, 'cuts': plan.cuts}));
  }, skip: Platform.environment['VIBELINE_REAL'] != '1', timeout: const Timeout(Duration(minutes: 60)));
}
