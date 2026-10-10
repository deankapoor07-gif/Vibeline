// Swaps a mashup's vocal and beat for songs picked from the library.
// Skipped unless VIBELINE_REAL=1.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/mashup.dart';
import 'package:vibeline/vibe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('replace vocal and beat', () async {
    final lib = MusicLibrary();
    await lib.scan();
    final vibe = parseVibe('party, mix genres, my shazams');
    final maker = MashupMaker(vibe, seed: 3);
    final rng = math.Random(3);
    final ranked = lib.tracks.map((t) => (t, tagScore(t, vibe, rng))).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    final pool = ranked.take(80).map((e) => e.$1).toList();
    await lib.analyze(pool, (d, t) {});
    final session = MashupSession.start(maker, pool);
    await session.fill(lib, 2, (s) {}, () {});
    String desc(Mashup m) => '${m.vocal.title} / ${m.beat.title} · ${m.playedBpm.toStringAsFixed(1)} BPM · vocal shift ${m.vocalShift} · keys ${m.keyMatch}';
    session.layout();
    print('before: ${desc(session.mashups[0])}');
    final uptown = lib.tracks.firstWhere((t) => t.title.contains('Uptown Funk'));
    var err = await session.replace(0, uptown, asVocal: true, lib: lib, onStatus: (s) {});
    session.layout();
    print('vocal -> Uptown Funk: ${err ?? desc(session.mashups[0])}');
    final kiss = lib.tracks.firstWhere((t) => t.title == 'Kiss');
    err = await session.replace(0, kiss, asVocal: false, lib: lib, onStatus: (s) {});
    session.layout();
    print('beat -> Kiss: ${err ?? desc(session.mashups[0])}');
    final instrumental = lib.tracks.firstWhere((t) => t.title.contains('Music Sounds Better'));
    err = await session.replace(1, instrumental, asVocal: true, lib: lib, onStatus: (s) {});
    print('near-instrumental as vocal: ${err ?? 'accepted'}');
    final plan = session.layout();
    expect(plan.mashups.length, 2);
  }, skip: Platform.environment['VIBELINE_REAL'] != '1', timeout: const Timeout(Duration(minutes: 20)));
}
