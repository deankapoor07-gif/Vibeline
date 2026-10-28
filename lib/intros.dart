import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'library.dart';
import 'models.dart';

/// A marker in an intro, counted in bars and beats from the intro's bar 0
/// (negative bars are pre-roll). Bars, not seconds, so it stays on the beat
/// at whatever tempo the set plays the song.
class IntroCue {
  final String id;
  final int bar;
  final int beat; // 1..4
  final String type; // vocalDrop, scratch, songStart, overlayEnd, …
  const IntroCue(this.id, this.bar, this.beat, this.type);

  factory IntroCue.fromJson(Map<String, dynamic> j) =>
      IntroCue('${j['id'] ?? ''}', (j['bar'] as num?)?.toInt() ?? 0, (j['beat'] as num?)?.toInt() ?? 1, '${j['type'] ?? ''}');

  Map<String, dynamic> toJson() => {'id': id, 'bar': bar, 'beat': beat, 'type': type};
}

/// A prepared intro for one song: an overlay (scratches, drops, acapellas)
/// rendered at the song's own tempo and key, plus where it sits on the song's
/// beat grid. Stored as intros/<name>.json next to its .wav.
class Intro {
  final String song; // the song file it belongs to
  final String asset; // the overlay .wav (absolute, or relative to the intros folder)
  final int assetStartsAtBar; // intro bar the overlay file starts on
  final int lengthBars;
  /// What bar 0 is: 'takeover' = the downbeat where the song has the floor
  /// to itself (end of the blend into it); 'songStart' = the song's first
  /// bar, and only when the mix plays it from the top.
  final String anchor;
  /// When it plays: 'always', 'setOpener', 'afterBlend' or 'off'.
  final String when;
  final double gainDb;
  final List<IntroCue> cues;
  final String file; // the sidecar it was read from

  Intro({
    required this.song,
    required this.asset,
    this.assetStartsAtBar = 0,
    this.lengthBars = 8,
    this.anchor = 'takeover',
    this.when = 'always',
    this.gainDb = 0,
    this.cues = const [],
    this.file = '',
  });

  static String get folder => '${MusicLibrary.supportDir}/intros';

  String get assetPath => asset.startsWith('/') ? asset : '$folder/$asset';

  factory Intro.fromJson(Map<String, dynamic> j, {String file = ''}) => Intro(
        song: '${j['song']}',
        asset: '${j['asset']}',
        assetStartsAtBar: (j['assetStartsAtBar'] as num?)?.toInt() ?? 0,
        lengthBars: (j['lengthBars'] as num?)?.toInt() ?? 8,
        anchor: '${j['anchor'] ?? 'takeover'}',
        when: '${j['when'] ?? 'always'}',
        gainDb: (j['gainDb'] as num?)?.toDouble() ?? 0,
        cues: [for (final c in (j['cues'] as List? ?? const [])) IntroCue.fromJson((c as Map).cast())],
        file: file,
      );

  Map<String, dynamic> toJson() => {
        'song': song,
        'asset': asset,
        'assetStartsAtBar': assetStartsAtBar,
        'lengthBars': lengthBars,
        'anchor': anchor,
        'when': when,
        'gainDb': gainDb,
        'cues': cues.map((c) => c.toJson()).toList(),
      };

  /// Every intro in the intros folder, by song path. Broken files are skipped.
  static Future<Map<String, Intro>> loadAll([String? dir]) async {
    final d = Directory(dir ?? folder);
    final out = <String, Intro>{};
    if (!await d.exists()) return out;
    await for (final f in d.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final i = Intro.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>, file: f.path);
        if (i.when != 'off' && File(i.assetPath).existsSync()) out[i.song] = i;
      } catch (_) {}
    }
    return out;
  }
}

/// The overlay clips for the songs in [plan] that have an intro, each locked
/// to its song: same speed and pitch, bar 0 on the song's downbeat.
List<Map<String, dynamic>> introClips(MixPlan plan, Map<String, Intro> intros) {
  final clips = <Map<String, dynamic>>[];
  for (var i = 0; i < plan.tracks.length; i++) {
    final p = plan.tracks[i];
    final intro = intros[p.track.path];
    final a = p.track.analysis;
    if (intro == null || a == null || a.beats.length < 16) continue;
    if (intro.when == 'setOpener' && i != 0) continue;
    if (intro.when == 'afterBlend' && i == 0) continue;
    final at = introBar0(p, a, intro.anchor, i == 0 ? null : plan.transitions[i - 1].end);
    if (at == null) continue;
    final clip = overlayClip(p, intro, at.$1, at.$2);
    if (clip != null) clips.add(clip);
  }
  return clips;
}

/// Song time (s) of the intro's bar 0 and the song's beat length there (s).
(double, double)? introBar0(PlannedTrack p, Analysis a, String anchor, double? blendEnd) {
  int bi; // beat index of the downbeat
  if (anchor == 'songStart') {
    bi = a.beatIndexOfBar(a.firstBar);
    // Only when the mix plays the song from (about) its first bar.
    if (p.srcStart > a.beats[bi.clamp(0, a.beats.length - 1)] + 0.5) return null;
  } else {
    final s = p.srcAt(blendEnd ?? p.outStart);
    var nearest = 0;
    for (var k = 1; k < a.beats.length; k++) {
      if ((a.beats[k] - s).abs() < (a.beats[nearest] - s).abs()) nearest = k;
    }
    bi = a.beatIndexOfBar(((nearest - a.barPhase) / 4).round());
  }
  final g = a.fit(bi - 16, bi + 16);
  return (g.timeOfBeat(bi), g.period);
}

/// The overlay as a clip whose bar 0 lands at song time [bar0].
Map<String, dynamic>? overlayClip(PlannedTrack p, Intro intro, double bar0, double beatLen) {
  final fileStart = bar0 + intro.assetStartsAtBar * 4 * beatLen; // song time the file starts at
  var outStart = p.mixAt(fileStart);
  var srcStart = 0.0;
  if (outStart < 0) {
    srcStart = -outStart * p.rate;
    outStart = 0;
  }
  // Run to the end of the file (the player stops there), with a tail for echoes.
  final srcEnd = (intro.lengthBars + 2) * 4 * beatLen + 4;
  if (srcEnd <= srcStart) return null;
  final json = p.toJson();
  return {
    'path': intro.assetPath,
    'srcStart': srcStart,
    'srcEnd': srcEnd,
    'outStart': outStart,
    'rate': p.rate,
    'pitchCents': json['pitchCents'], // in key with the song as it's played
    if (p.rides) 'warp': p.warp(fileStart), // and riding home with it
    if (json['pitchRamp'] != null) 'pitchRamp': json['pitchRamp'],
    'gainDb': math.max(-24.0, math.min(24.0, intro.gainDb)),
    'deck': 2,
    'echoTime': p.echoTime,
    'keys': const [],
  };
}
