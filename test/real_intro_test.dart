// Plans a theme-night blend mix, gives one song a click-track intro (a click
// on every beat from bar -4 to bar 8) and writes two plans to render: the
// intro overlay alone, and clicks on the song's own analysed beats played
// exactly like the song. If the intro is locked to the song, the clicks of
// the two renders coincide.
// Skipped unless VIBELINE_REAL=1. VIBELINE_INTRO_OUT=<folder>, VIBELINE_INTRO_SONG=<index>.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/intros.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/planner.dart';
import 'package:vibeline/vibe.dart';

/// Mono 16-bit WAV with a short 2 kHz click at each time in [clicks] (s).
void writeClicks(String path, List<double> clicks, double seconds) {
  const sr = 44100;
  final n = (seconds * sr).ceil();
  final pcm = Int16List(n);
  for (final c in clicks) {
    final s0 = (c * sr).round();
    for (var i = 0; i < 400 && s0 + i < n; i++) {
      if (s0 + i < 0) continue;
      pcm[s0 + i] = (12000 * math.sin(2 * math.pi * 2000 * i / sr) * math.exp(-i / 120)).round();
    }
  }
  final b = BytesBuilder();
  void u32(int v) => b.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
  void u16(int v) => b.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));
  b.add(ascii.encode('RIFF'));
  u32(36 + n * 2);
  b.add(ascii.encode('WAVEfmt '));
  u32(16);
  u16(1);
  u16(1);
  u32(sr);
  u32(sr * 2);
  u16(2);
  u16(16);
  b.add(ascii.encode('data'));
  u32(n * 2);
  b.add(pcm.buffer.asUint8List());
  File(path).writeAsBytesSync(b.toBytes());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('intro overlay lands on the beat', () async {
    final out = Platform.environment['VIBELINE_INTRO_OUT']!;
    final which = int.parse(Platform.environment['VIBELINE_INTRO_SONG'] ?? '1');
    final lib = MusicLibrary();
    await lib.loadSettings();
    await lib.scan();
    final vibe = parseTheme('party, mix genres, my shazams', Platform.environment['VIBELINE_THEME'] ?? 'Kiwi');
    final rng = math.Random(5);
    final pool = lib.tracks.where(vibe.fits).toList()
      ..sort((a, b) => tagScore(b, vibe, rng).compareTo(tagScore(a, vibe, rng)));
    await lib.analyze(pool, (d, t) {});
    fitThemeTempo(vibe, pool);
    await lib.separate(pool.where((t) => t.analysis != null).toList(), (d, n, c) {});
    final plan = MixPlanner(vibe, seed: 5).plan(pool)!;
    final p = plan.tracks[which];
    final a = p.track.analysis!;
    print('SONG ${p.track.title} · rate ${p.rate.toStringAsFixed(3)} · in ${p.outStart.toStringAsFixed(1)}s');

    final bar0 = introBar0(p, a, 'takeover', which == 0 ? null : plan.transitions[which - 1].end)!;
    final beatLen = bar0.$2;
    // Overlay: file starts at bar -4, a click on every beat for 12 bars.
    writeClicks('$out/overlay.wav', [for (var k = 0; k < 48; k++) k * beatLen], 48 * beatLen + 2);
    final intro = Intro(song: p.track.path, asset: '$out/overlay.wav', assetStartsAtBar: -4, lengthBars: 12);
    final overlay = introClips(plan, {p.track.path: intro});
    expect(overlay.length, 1);

    // Reference: clicks on the song's own beats near bar 0, played like the song.
    final near = [for (final t in a.beats) if ((t - bar0.$1).abs() < 20 * beatLen) t];
    writeClicks('$out/reference.wav', near, p.track.duration + 1);
    final ref = {...p.toJson(), 'path': '$out/reference.wav', 'keys': const [], 'gainDb': 0.0};

    final from = overlay.first['outStart'] as double;
    final to = from + 50 * beatLen / p.rate;
    for (final (name, clip) in [('overlay', overlay.first), ('reference', ref)]) {
      File('$out/$name.json').writeAsStringSync(jsonEncode({
        'duration': to + 2,
        'clips': [clip],
        'window': {'start': math.max(0.0, from - 2), 'end': to + 2, 'preRoll': 2.0, 'fadeIn': 0.0, 'fadeOut': 0.0},
      }));
    }
    print('BAR0 mix ${p.mixAt(bar0.$1).toStringAsFixed(3)}s · window ${from.toStringAsFixed(2)}–${to.toStringAsFixed(2)}');
  }, skip: Platform.environment['VIBELINE_REAL'] != '1', timeout: const Timeout(Duration(minutes: 60)));
}
