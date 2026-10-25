import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'library.dart';
import 'models.dart';
import 'planner.dart';
import 'tuning.dart';
import 'vibe.dart';

// ---------------------------------------------------------
// MASHUP MODEL
// ---------------------------------------------------------

/// One stem of one song, as a lane in a mashup.
class StemLane {
  final String stem; // vocals / other / bass / drums (Demucs names)
  final bool fromVocalSong;
  bool muted;
  bool solo = false;

  StemLane(this.stem, this.fromVocalSong, {this.muted = false});

  String get label => switch (stem) {
        'vocals' => 'Vocals',
        'other' => 'Melody',
        'bass' => 'Bass',
        _ => 'Drums',
      };

  Color get color => switch (stem) {
        'vocals' => Colors.pinkAccent,
        'other' => Colors.cyanAccent,
        'bass' => Colors.amberAccent,
        _ => Colors.greenAccent,
      };
}

/// A vocal from one song over the beat (melody + bass + drums) of another,
/// or a beat break (instrumental only).
class Mashup {
  LibraryTrack vocal;
  LibraryTrack beat;
  Analysis vocalGrid; // tempo-scaled
  Analysis beatGrid; // at its natural tempo
  final bool beatOnly;

  // Pitch of the vocal: whole semitones (key match) plus fine cents by ear.
  int vocalShift = 0;
  int autoShift = 0;
  double fineCents = 0;
  int beatShift = 0; // semitones on the beat (anchor mode: to sit with the anchor's key)

  // Your volume faders (dB), applied live on top of the automatic balance.
  double vocalDb = 0;
  double beatDb = 0;

  /// Tempo of this mashup relative to the beat's own speed (1.0 = natural).
  /// Below 1 drags the beat out (slower), above 1 tightens it (faster); the
  /// vocal always follows the beat.
  double tempoScale = 1.0;

  // Structure, in bars of each song's (scaled) grid.
  int beatStart = 0; // beat song bar the mashup starts on
  int vocalStart = 0; // vocal song bar the singing starts on
  int vocalBars = 32;
  int vocalTailBeats = 0; // the last word ringing on past the section end
  static const introBars = 8;
  static const outroBars = 8;

  late List<StemLane> lanes;

  Mashup(this.vocal, this.beat, this.vocalGrid, this.beatGrid, {this.beatOnly = false}) {
    lanes = [
      StemLane('vocals', true, muted: beatOnly),
      StemLane('other', false),
      StemLane('bass', false),
      StemLane('drums', false),
      // Off by default; unmute to layer them in.
      StemLane('vocals', false, muted: true),
      if (!beatOnly) ...[
        StemLane('other', true, muted: true),
        StemLane('bass', true, muted: true),
        StemLane('drums', true, muted: true),
      ],
    ];
  }

  int get totalBars => introBars + vocalBars + outroBars;

  bool laneAudible(StemLane l) {
    final anySolo = lanes.any((x) => x.solo);
    return anySolo ? l.solo : !l.muted;
  }

  double? get _vocalHz => vocal.stems?.tuning['vocals'] ?? vocal.analysis?.tuning;
  double? get _beatHz => beat.stems?.tuning['other'] ?? beat.analysis?.tuning;

  /// Cents applied to the beat song's stems (retunes it to 432 Hz, or 0).
  double get beatCents => Tuning.toReference(_beatHz) + beatShift * 100;

  /// Cents applied to the vocal: key shift + tuning match + your fine-tune.
  double get vocalCents => vocalShift * 100 + Tuning.vocalCents(_vocalHz, _beatHz) + fineCents;

  /// The part baked into the render (automatic key shift + tuning match)…
  double get renderedVocalCents => autoShift * 100 + Tuning.vocalCents(_vocalHz, _beatHz);

  /// …and your adjustment on top, applied live by the player (instant).
  double get liveVocalCents => (vocalShift - autoShift) * 100 + fineCents;

  /// Automatic vocal level, relative to the beat as recorded: every vocal is
  /// aimed at the same place, about 2.5 dB under the full beat while singing,
  /// whatever volume its file was saved at.
  double get autoVocalDb {
    final vVocal = vocal.stems?.levels['vocals'];
    final bInst = beat.stems?.levels['instrumental'] ?? beat.analysis?.loudnessDb;
    if (vVocal == null || bInst == null) return 1.0;
    return (bInst - vVocal - 2.5).clamp(-24.0, 24.0);
  }

  /// Levels the beat song to a common loudness. Files in a library can differ
  /// by 20 dB (some are saved much quieter), so without this a quiet file's
  /// beat would drop away next to a loud one.
  double get beatGainDb {
    final bInst = beat.stems?.levels['instrumental'];
    if (bInst != null) return (-14.0 - bInst).clamp(-12.0, 20.0);
    final l = beat.analysis?.loudnessDb;
    return l == null ? 0 : (-13.5 - l).clamp(-12.0, 20.0);
  }

  /// How far the vocal's own tuning was corrected automatically (for display).
  double get autoTuneCents => Tuning.vocalCents(_vocalHz, _beatHz) - beatCents;

  String get keyMatch {
    if (beatOnly) return 'beat';
    final c = keyCompat(shiftCamelot(beatGrid.camelot, beatShift), shiftCamelot(vocalGrid.camelot, vocalShift));
    if (c >= 0.99) return vocalShift == autoShift && vocalShift != 0 ? 'shifted' : 'perfect';
    if (c >= 0.8) return 'compatible';
    if (c >= 0.45) return 'loose';
    return 'clash';
  }

  double get tempo => beatGrid.steadyBpm;

  /// The tempo at which the vocal plays at its own natural speed (no stretch).
  double get vocalNaturalScale => beatOnly ? 1.0 : (vocalGrid.steadyBpm / beatGrid.steadyBpm).clamp(0.85, 1.15);

  /// How fast the vocal is playing vs. its original (1.0 = untouched).
  double get vocalSpeed => beatOnly ? 1.0 : beatGrid.steadyBpm * tempoScale / vocalGrid.steadyBpm;

  String get styleLine {
    String fam(LibraryTrack t) {
      final g = t.genre.isEmpty ? 'Mystery' : t.genre;
      return t.year > 0 ? '$g ${t.year}' : g;
    }

    return beatOnly ? 'Beat break · ${fam(beat)}' : '${fam(vocal)} vocal × ${fam(beat)} beat';
  }

  // Filled in when the set is laid out.
  double start = 0; // mix time of bar 0
  double vocalIn = 0; // mix time the vocal enters
  double vocalOut = 0;
  double end = 0;
  double vocalRate = 1;
  double playedBpm = 0;
  List<double> beatTimes = const []; // mix time of every beat of this mashup
}

/// A sound, loop or acapella placed on the sample lane over a mashup. It is
/// anchored to its mashup (and a bar in it), so it moves with the mashup.
class SamplePlacement {
  final LibraryTrack track;
  Mashup anchor;
  int bar; // bar of the anchor mashup it starts on
  int bars; // how long it plays, in bars
  double db = 0; // your volume on top of the automatic level
  double fade = 2.0; // seconds of fade in and out
  bool vocalOnly = false; // play just the singing (acapella)
  bool sync; // lock its beat to the mashup's (songs with a beat)

  SamplePlacement(this.track, this.anchor, {this.bar = 0, this.bars = 16}) : sync = track.analysis != null;

  bool get canSync => track.analysis != null;

  /// Automatic level: sits under the music (about −20 dB average).
  double get autoDb {
    final l = track.level ?? track.analysis?.loudnessDb;
    if (l == null) return -6;
    return (-21.0 - l).clamp(-18.0, 18.0);
  }
}

/// The steady groove a set comes home to: a 16-bar loop of one beat. New
/// vocals come in over it, the mashup's own beat takes over once the vocal has
/// settled, and the set cuts back to it now and then. Everything runs at its
/// tempo and sits in (or next to) its key.
class AnchorBeat {
  final LibraryTrack track;
  final Analysis grid;
  final int loopStart; // first bar of the 16-bar loop
  static const loopBars = 16;

  AnchorBeat(this.track, this.grid, this.loopStart);

  double get tempo => grid.steadyBpm;
  String get camelot => grid.camelot;
  double get gainDb {
    final loop = MashupMaker.sectionGainDb(track, grid, loopStart, loopStart + loopBars);
    if (loop != null) return loop;
    final inst = track.stems?.levels['instrumental'];
    if (inst != null) return (-14.0 - inst).clamp(-12.0, 20.0);
    final l = track.analysis?.loudnessDb;
    return l == null ? 0 : (-13.5 - l).clamp(-12.0, 20.0);
  }

  double get cents => Tuning.toReference(track.stems?.tuning['other'] ?? track.analysis?.tuning);
}

class MashupSetPlan {
  final List<Mashup> mashups;
  final double duration;
  final String summary;
  final Map<String, dynamic> renderJson;
  final List<double> cuts; // section boundaries (where blends finish)
  MashupSetPlan(this.mashups, this.duration, this.summary, this.renderJson, this.cuts);

  /// Your live pitch and volume moves for each mashup, for the player.
  /// Beat regions change hands halfway through each blend.
  Map<String, dynamic> get liveMap => {
        'vocal': [
          for (final m in mashups)
            if (!m.beatOnly && (m.liveVocalCents != 0 || m.vocalDb != 0))
              {'start': m.vocalIn - 4, 'end': m.vocalOut + 7, 'cents': m.liveVocalCents, 'db': m.vocalDb}
        ],
        'beat': [
          for (var i = 0; i < mashups.length; i++)
            if (mashups[i].beatDb != 0)
              {
                'start': i == 0 ? 0.0 : (mashups[i].start + mashups[i].vocalIn) / 2,
                'end': i + 1 < mashups.length ? (mashups[i + 1].start + mashups[i + 1].vocalIn) / 2 : duration + 5,
                'db': mashups[i].beatDb,
              }
        ],
      };
}

// ---------------------------------------------------------
// MASHUP MAKER
// ---------------------------------------------------------

class _Pair {
  final LibraryTrack vocal, beat;
  final Analysis vGrid, bGrid;
  final int shift;
  final double score;
  final int beatShift;
  _Pair(this.vocal, this.beat, this.vGrid, this.bGrid, this.shift, this.score, [this.beatShift = 0]);
  double get tempo => bGrid.steadyBpm;
  String get key => '${vocal.path}|${beat.path}';
}

class MashupMaker {
  final VibeProfile vibe;
  final math.Random rng;
  MashupMaker(this.vibe, {int? seed}) : rng = math.Random(seed);

  int get mashupCount => (vibe.minutes / 2.1).round().clamp(2, 160);

  // ------------------------------------------------------------- tempo

  /// Scales a song to the tempo closest to [tempo] (half / double time).
  static Analysis? fitTo(Analysis a, double tempo, double maxStretch) {
    var best = 1.0;
    for (final f in const [0.5, 1.0, 2.0]) {
      if ((math.log(tempo / (a.steadyBpm * f))).abs() < (math.log(tempo / (a.steadyBpm * best))).abs()) best = f;
    }
    if ((tempo / (a.steadyBpm * best) - 1).abs() > maxStretch) return null;
    return a.scaled(best);
  }

  /// A beat plays at its own tempo, counted in the range that suits the vibe.
  Analysis _natural(Analysis a) => fitTo(a, vibe.targetBpm, 10)!;

  /// The tempo the set should be at a point in it (0..1): it rises with the
  /// energy curve, and in long sets it travels in gentle waves.
  double targetTempo(double p) {
    final span = math.max(0.01, vibe.peakEnergy - vibe.startEnergy);
    final lift = ((vibe.energyAt(p) - vibe.startEnergy) / span).clamp(0.0, 1.0);
    final waves = vibe.minutes > 45 ? 0.04 * math.sin(p * math.pi * 2 * (vibe.minutes / 50)) : 0.0;
    return vibe.targetBpm * (0.94 + 0.08 * lift + waves);
  }

  // ------------------------------------------------------------- pairing

  /// Every vocal-song / beat-song pairing worth trying, best first.
  /// Mashups are about contrast: different genres and eras score higher.
  List<_Pair> rankPairs(List<LibraryTrack> pool, {LibraryTrack? onlyBeat}) {
    final songs = pool.where((t) => t.analysis != null && t.analysis!.barCount >= 40).toList();
    final tags = {for (final t in songs) t.path: tagScore(t, vibe, rng)};
    final pairs = <_Pair>[];
    final beats = onlyBeat != null ? [onlyBeat] : songs;
    for (final b in beats) {
      if (b.analysis == null) continue;
      final bg = _natural(b.analysis!);
      final tb = bg.steadyBpm;
      if (onlyBeat == null && (tb < vibe.targetBpm * 0.78 || tb > vibe.targetBpm * 1.22)) continue;
      // A good beat grooves and keeps steady time.
      var bScore = 0.6 * ((b.analysis!.danceability - 1.0).clamp(-0.5, 1.0));
      if (b.analysis!.tempoDrift > 0.03) bScore -= 1.2;
      bScore -= 1.5 * (math.log(tb / vibe.targetBpm)).abs();
      for (final v in songs) {
        if (identical(v, b) || v.artist.toLowerCase() == b.artist.toLowerCase()) continue;
        final vg = fitTo(v.analysis!, tb, 0.14);
        if (vg == null) continue;
        if (v.stems != null && v.stems!.vocalShare < 0.08) continue; // no real vocal
        // Key: shift the vocal up to 3 semitones to sit on the beat.
        var shift = 0, compat = -1.0;
        for (final s in const [0, 1, -1, 2, -2, 3, -3]) {
          final c = keyCompat(bg.camelot, shiftCamelot(vg.camelot, s)) - 0.07 * s.abs();
          if (c > compat) {
            compat = c;
            shift = s;
          }
        }
        if (compat < 0.6) continue;
        final stretch = (tb / vg.steadyBpm - 1).abs();
        var s = 1.5 * compat - 4.0 * stretch + bScore;
        s += 0.55 * (tags[v.path]! + (tags[b.path] ?? 0));
        if (vibe.vocalFamily != null) s += genreFamily(v.genre) == vibe.vocalFamily ? 2.0 : -2.0;
        if (vibe.beatFamily != null) s += genreFamily(b.genre) == vibe.beatFamily ? 2.0 : -2.0;
        final contrast = genreFamily(v.genre) != genreFamily(b.genre);
        s += contrast ? 1.2 : -0.4;
        if (v.year > 0 && b.year > 0 && (v.year - b.year).abs() >= 10) s += 0.5;
        if (v.analysis!.tempoDrift > 0.04) s -= 0.4;
        s += rng.nextDouble() * 0.5;
        pairs.add(_Pair(v, b, vg, bg, shift, s));
      }
    }
    pairs.sort((a, b) => b.score.compareTo(a.score));
    return pairs;
  }

  /// Best pairing to follow [prev] at set position [p]: its beat must be
  /// within 6% of the tempo the set is at, so the blend can match it.
  _Pair? pickNext(List<_Pair> ranked, Mashup? prev, double p, Set<String> used, Set<String> rejected) {
    final target = targetTempo(p);
    _Pair? best;
    var bestScore = -1e9;
    var looked = 0;
    for (final x in ranked) {
      if (used.contains(x.vocal.path) || used.contains(x.beat.path) || rejected.contains(x.key)) continue;
      if (prev != null && (math.log(x.tempo / prev.tempo)).abs() > math.log(1.06)) continue;
      var s = x.score - 9 * (math.log(x.tempo / target)).abs() - 2 * (x.bGrid.energy - vibe.energyAt(p)).abs();
      if (prev != null) s += keyCompat(prev.beatGrid.camelot, x.bGrid.camelot);
      if (s > bestScore) {
        bestScore = s;
        best = x;
      }
      if (++looked > 4000) break; // ranked best-first; no need to scan everything
    }
    return best;
  }

  /// Turns a pairing into a mashup once stems are known. Returns null if the
  /// vocal song turns out to have too little singing.
  Mashup? build(_Pair p) {
    final vs = p.vocal.stems, bs = p.beat.stems;
    if (vs == null || bs == null || vs.vocalShare < 0.08) return null;
    final m = Mashup(p.vocal, p.beat, p.vGrid, p.bGrid)
      ..vocalShift = p.shift
      ..autoShift = p.shift
      ..beatShift = p.beatShift;
    if (!_placeVocal(m)) return null;
    return m;
  }

  /// How well [vocal] would sit on [beat]: (key shift, key score 0..1,
  /// vocal stretch as a fraction). Null if the tempos are too far apart.
  ({int shift, double key, double stretch, Analysis vGrid, Analysis bGrid})? fit(LibraryTrack vocal, LibraryTrack beat,
      {double? nearTempo}) {
    final va = vocal.analysis, ba = beat.analysis;
    if (va == null || ba == null) return null;
    final bg = nearTempo != null ? fitTo(ba, nearTempo, 10)! : _natural(ba);
    final vg = fitTo(va, bg.steadyBpm, 0.25);
    if (vg == null) return null;
    var shift = 0, best = -1.0;
    for (final s in const [0, 1, -1, 2, -2, 3, -3]) {
      final c = keyCompat(bg.camelot, shiftCamelot(vg.camelot, s)) - 0.07 * s.abs();
      if (c > best) {
        best = c;
        shift = s;
      }
    }
    final key = keyCompat(bg.camelot, shiftCamelot(vg.camelot, shift));
    return (shift: shift, key: key, stretch: bg.steadyBpm / vg.steadyBpm - 1, vGrid: vg, bGrid: bg);
  }

  /// A mashup of exactly these two songs (your pick), or a reason it can't be.
  (Mashup?, String?) pairOf(LibraryTrack vocal, LibraryTrack beat, {double? nearTempo}) {
    if (identical(vocal, beat)) return (null, 'Pick a different song — that one is already in this mashup.');
    final f = fit(vocal, beat, nearTempo: nearTempo);
    if (f == null) return (null, 'The tempos of "${vocal.title}" and "${beat.title}" are too far apart to match.');
    if ((vocal.stems?.vocalShare ?? 1) < 0.08) {
      return (null, '"${vocal.title}" has hardly any singing, so it can\'t be the vocal. Try it as a beat.');
    }
    final m = build(_Pair(vocal, beat, f.vGrid, f.bGrid, f.shift, 0));
    if (m == null) return (null, 'Couldn\'t find a clean vocal section in "${vocal.title}".');
    return (m, null);
  }

  /// An instrumental break from [song] (its own vocals muted).
  Mashup? beatBreak(LibraryTrack song, {int bars = 16, double? nearTempo}) {
    if (song.analysis == null || song.stems == null) return null;
    final g = nearTempo != null ? fitTo(song.analysis!, nearTempo, 10)! : _natural(song.analysis!);
    final m = Mashup(song, song, g, g, beatOnly: true)..vocalBars = bars;
    _placeBeat(m);
    return m;
  }

  /// Rebuilds a mashup with the roles flipped (the beat song sings).
  Mashup? swapped(Mashup m) {
    if (m.beatOnly || m.beat.stems == null || m.vocal.stems == null) return null;
    final bg = _natural(m.vocal.analysis!);
    final vg = fitTo(m.beat.analysis!, bg.steadyBpm, 0.16);
    if (vg == null) return null;
    var shift = 0, compat = -1.0;
    for (final s in const [0, 1, -1, 2, -2, 3, -3]) {
      final c = keyCompat(bg.camelot, shiftCamelot(vg.camelot, s)) - 0.07 * s.abs();
      if (c > compat) {
        compat = c;
        shift = s;
      }
    }
    return build(_Pair(m.beat, m.vocal, vg, bg, shift, 0));
  }

  // ------------------------------------------------------------- structure

  double _vocalAt(Mashup m, int bar) {
    final g = m.vocalGrid;
    final a = g.beatIndexOfBar(bar), b = g.beatIndexOfBar(bar + 1);
    if (a < 0 || b >= g.beats.length) return 0;
    return m.vocal.stems!.vocalBetween(m.vocal.analysis!.beats, g.beats[a], g.beats[b]);
  }

  double _meanVocal(Mashup m, int from, int to) {
    var s = 0.0;
    for (var i = from; i < to; i++) {
      s += _vocalAt(m, i);
    }
    return s / math.max(1, to - from);
  }

  /// Song time of a bar's downbeat.
  static double _barTime(Analysis g, int bar) {
    if (g.beats.isEmpty) return 0;
    return g.beats[g.beatIndexOfBar(bar).clamp(0, g.beats.length - 1)];
  }

  /// How much of bars [from, to) of a song lose their drums / their bass
  /// (0..1; 0 when the stems haven't been measured). A full stop, where
  /// everything cuts out even for half a second, counts as a big drum gap.
  static (double, double) dropouts(LibraryTrack t, Analysis g, int from, int to) {
    final st = t.stems;
    if (st == null || !st.hasCurves) return (0, 0);
    final t0 = _barTime(g, from), t1 = _barTime(g, to);
    final stop = st.stops(t0, t1) > 0 ? 0.25 : 0.0;
    return (st.dropout('drums', t0, t1) + stop, st.dropout('bass', t0, t1));
  }

  /// Gain that brings bars [from, to) of a song to a common loudness, as the
  /// ear hears it, measured on the part that actually plays (null when the
  /// stems haven't been measured).
  static double? sectionGainDb(LibraryTrack t, Analysis g, int from, int to) {
    final st = t.stems;
    if (st == null || !st.hasCurves) return null;
    return (-14.0 - st.levelDb('inst', _barTime(g, from), _barTime(g, to))).clamp(-12.0, 26.0);
  }

  /// A beat with no real bass or drums to carry a section on its own.
  static bool weakBeat(LibraryTrack t) {
    final st = t.stems;
    if (st == null || !st.hasCurves) return false;
    return st.bassless || (st.relative('drums') ?? 0) < -12;
  }

  /// In anchor mode, a beat whose chosen section still loses its drums (or
  /// bass) somewhere while it's heard: the song has no long enough unbroken
  /// groove, so another pairing is used instead.
  /// The end of the vocal, the solo and the handover must be completely
  /// unbroken. [relaxed] (when the library runs short) allows small gaps.
  static bool gappyBeat(Mashup m, {bool relaxed = false}) {
    final (drumsOut, bassOut) = dropouts(m.beat, m.beatGrid, m.beatStart, m.beatStart + m.vocalBars + 12);
    if (relaxed) return drumsOut > 0.05 || bassOut > 0.12;
    final (tailDrums, tailBass) =
        dropouts(m.beat, m.beatGrid, m.beatStart + m.vocalBars - 8, m.beatStart + m.vocalBars + 12);
    return drumsOut > 0.02 || bassOut > 0.05 || tailDrums > 0 || tailBass > 0.02;
  }

  /// Solid enough to be the anchor: a real bassline and steady drums.
  static bool solidAnchor(LibraryTrack t) {
    final st = t.stems;
    if (st == null || !st.hasCurves) return true; // not measured yet
    return (st.relative('bass') ?? 0) > -12 && (st.relative('drums') ?? 0) > -6;
  }

  double _meanEnergy(Analysis g, int from, int to) {
    final a = from.clamp(0, g.barCount - 1), b = to.clamp(a + 1, g.barCount);
    var s = 0.0;
    for (var i = a; i < b; i++) {
      s += g.barEnergy[i];
    }
    return s / (b - a);
  }

  /// Chooses the vocal section (verse into chorus, starting on a fresh line)
  /// and the part of the beat it rides on.
  bool _placeVocal(Mashup m) {
    final vg = m.vocalGrid, bg = m.beatGrid;
    final beatRoom = bg.lastBar - bg.firstBar - Mashup.introBars - Mashup.outroBars;
    var best = -1e9;
    var bestStart = -1, bestLen = 0;
    for (final len in const [48, 40, 32, 24, 16]) {
      if (len > beatRoom) continue;
      for (var s = vg.firstBar; s + len <= vg.lastBar; s++) {
        if ((s - vg.firstBar) % 4 != 0) continue;
        final first = _vocalAt(m, s);
        if (first < 0.35) continue;
        final fresh = _vocalAt(m, s - 1) < 0.45 ? 0.4 : 0.0; // a new line, not mid-sentence
        // End where the singer has finished the line (quiet for a moment
        // after), so the vocal can leave smoothly rather than mid-word.
        final after = _vocalAt(m, s + len), after2 = _vocalAt(m, s + len + 1);
        final endsClean = after < 0.3 && after2 < 0.45
            ? 0.9
            : after < 0.45
                ? 0.2
                : -0.9;
        // Avoid sections with a long stretch of no singing (solos, breakdowns).
        var gap = 0, longest = 0;
        for (var b = s; b < s + len; b++) {
          gap = _vocalAt(m, b) < 0.15 ? gap + 1 : 0;
          longest = math.max(longest, gap);
        }
        if (longest >= 6) continue;
        final gapPenalty = longest >= 3 ? 0.4 : 0.0;
        // Prefer sections that open into more energy (verse → chorus feel).
        final open = _meanEnergy(vg, s, s + 4);
        final later = _meanEnergy(vg, s + len ~/ 2, s + len);
        final lift = (later - open).clamp(-0.2, 0.5);
        final score = 1.2 * _meanVocal(m, s, s + len) +
            0.5 * _meanEnergy(vg, s, s + len) +
            0.4 * lift +
            fresh +
            endsClean +
            len / 48 -
            (s - vg.firstBar) / 400 -
            gapPenalty;
        if (score > best) {
          best = score;
          bestStart = s;
          bestLen = len;
        }
      }
      if (bestStart >= 0 && best > 1.2) break;
    }
    if (bestStart < 0) return false;
    m
      ..vocalStart = bestStart
      ..vocalBars = bestLen
      ..vocalTailBeats = _tailBeats(m, bestStart + bestLen);
    _placeBeat(m);
    return true;
  }

  /// How many beats the last word rings on past [endBar] (up to 6): the vocal
  /// keeps playing until the singer has actually finished.
  int _tailBeats(Mashup m, int endBar) {
    final g = m.vocalGrid;
    final base = g.beatIndexOfBar(endBar);
    var n = 0;
    while (n < 6 && base + n + 1 < g.beats.length) {
      final v = m.vocal.stems!.vocalBetween(m.vocal.analysis!.beats, g.beats[base + n], g.beats[base + n + 1]);
      if (v < 0.3) break;
      n++;
    }
    return n;
  }

  /// How a featured vocal leaves: a smooth fade over about a bar (plus any
  /// ringing last word), with an echo and a hall reverb carrying the end of
  /// the line out over the beat — never a cut.
  static List<Keyframe> vocalKeys(double outStart, double fadeInEnd, double vOut, int tailBeats, double beat) {
    final fadeEnd = vOut + (tailBeats + 2) * beat;
    return [
      Keyframe(outStart, gain: 0),
      Keyframe(fadeInEnd, gain: 1),
      Keyframe(vOut - 2 * beat),
      Keyframe(vOut, gain: 0.85, echo: 0.2, verb: 0.15),
      Keyframe(fadeEnd - beat, gain: 0.35, echo: 0.35, verb: 0.35),
      Keyframe(fadeEnd, gain: 0, echo: 0.4, verb: 0.45),
    ];
  }

  /// Strongest groove of the beat song that fits the vocal's energy shape,
  /// on an 8-bar phrase. Matches phrase character (verse/chorus feel) instead
  /// of only picking the loudest stretch of the instrumental.
  void _placeBeat(Mashup m) {
    final bg = m.beatGrid;
    final vg = m.vocalGrid;
    final need = m.totalBars;

    // Vocal energy contour over intro + vocal + outro bars of this mashup.
    final vEnergies = <double>[];
    for (var i = 0; i < need; i++) {
      final bar = m.vocalStart + (i - Mashup.introBars);
      if (bar < vg.firstBar || bar >= vg.lastBar || bar < 0 || bar >= vg.barEnergy.length) {
        vEnergies.add(0.25);
      } else {
        vEnergies.add(vg.barEnergy[bar]);
      }
    }

    var bBest = -1e9;
    var bStart = bg.firstBar;

    for (var s = bg.firstBar; s + need <= bg.lastBar + 1; s++) {
      if ((s - bg.firstBar) % 8 != 0) continue;

      final groove = _meanEnergy(bg, s + Mashup.introBars, s + Mashup.introBars + m.vocalBars);

      var shape = 0.0;
      var n = 0;
      for (var i = 0; i < need; i++) {
        final bi = s + i;
        if (bi < 0 || bi >= bg.barEnergy.length) continue;
        shape += 1.0 - (bg.barEnergy[bi] - vEnergies[i]).abs();
        n++;
      }
      final shapeScore = n == 0 ? 0.0 : shape / n;

      final pre = _meanEnergy(bg, s, s + Mashup.introBars);
      final atVocal = _meanEnergy(bg, s + Mashup.introBars, s + Mashup.introBars + 4);
      final build = (atVocal - pre).clamp(-0.3, 0.5);

      final vocalLoud = _meanVocal(m, m.vocalStart, m.vocalStart + math.min(8, m.vocalBars));
      final clashPenalty = (vocalLoud < 0.4 && atVocal > 0.85) ? 0.6 : 0.0;

      // Never under a vocal where the beat's drums (or bass) drop out.
      final (drumsOut, bassOut) = dropouts(m.beat, bg, s, s + need);
      // A steady groove (no big lifts and drops inside it) under the vocal.
      final g0 = s + Mashup.introBars, g1 = s + Mashup.introBars + m.vocalBars;
      var dev = 0.0;
      for (var b = g0; b < g1 && b < bg.barEnergy.length; b++) {
        dev += (bg.barEnergy[b] - groove).abs();
      }
      final unsteady = dev / math.max(1, g1 - g0);

      final score = 0.55 * groove +
          0.9 * shapeScore +
          0.35 * build -
          clashPenalty -
          6.0 * drumsOut -
          4.0 * bassOut -
          1.5 * unsteady -
          (s - bg.firstBar) / 300;

      if (score > bBest) {
        bBest = score;
        bStart = s;
      }
    }

    // (No ±1-bar nudge: the beat must start on an 8-bar phrase so blends,
    // builds and cut-backs land on phrase boundaries.)
    m.beatStart = bStart;
  }

  // ------------------------------------------------------------- layout

  /// Lays the mashups end to end (each one's 8-bar instrumental intro blends
  /// over the previous one's outro) and builds the render plan. Each beat
  /// plays at its own tempo: it comes in matched to the previous beat, then
  /// eases to its natural speed over 16 bars, so the set's tempo can travel.
  MashupSetPlan layout(List<Mashup> ms, {Map<String, dynamic>? warmth, List<SamplePlacement> samples = const []}) {
    final clips = <Map<String, dynamic>>[];
    final cuts = <double>[];
    List<double>? prevOutro; // previous mashup's outro beats in mix time
    double? nextStart;
    const kill = -30.0;

    for (var i = 0; i < ms.length; i++) {
      final m = ms[i];
      final bg = m.beatGrid, vg = m.vocalGrid;
      final group = (i % 2) * 8;
      final start = nextStart ?? 0.0;

      // Beat map: song time of each beat -> mix time, with the tempo ramp.
      final bBase = bg.beatIndexOfBar(m.beatStart);
      final totalBeats = m.totalBars * 4;
      double src(int n) => bg.smoothBeat(bBase + n);
      // During the blend (first 32 beats) every beat is pinned to the matching
      // beat of the outgoing song, so even drifting live recordings stay locked;
      // afterwards the tempo eases to this song's own speed over 16 bars.
      final outT = <double>[start];
      final pinned = prevOutro != null && prevOutro.length >= 33;
      if (pinned) {
        for (var n = 1; n <= 32; n++) {
          outT.add(prevOutro[n]);
        }
      }
      final s = m.tempoScale;
      final rEntry = pinned
          ? ((src(32) - src(28)) / (outT[32] - outT[28])).clamp(0.8, 1.2)
          : s;
      double rateAt(int n) {
        if (n < 32) return rEntry;
        if (n < 96) return rEntry + (s - rEntry) * (n - 32) / 64;
        return s;
      }

      for (var n = outT.length - 1; n <= totalBeats; n++) {
        outT.add(outT.last + (src(n + 1) - src(n)) / rateAt(n));
      }
      final beatWarp = [
        for (var n = 0; n <= totalBeats + 1; n++) [outT[n], src(n)]
      ];
      double barX(int bar) => outT[(bar * 4).clamp(0, totalBeats + 1)];
      double beatLen(int bar) => (barX(bar + 1) - barX(bar)) / 4;
      final srcStartB = src(0);
      final srcEndB = src(totalBeats) + 0.05;
      final outroBar = Mashup.introBars + m.vocalBars;

      // Vocal: each beat of the vocal song pinned to the matching beat of the
      // beat song (warp map), so even a drifting live vocal stays locked. Two
      // beats of pre-roll catch pickup notes sung just before the line.
      final vEntryBeat = vg.beatIndexOfBar(m.vocalStart);
      final warp = <List<double>>[
        for (var n = -2; n <= m.vocalBars * 4 + m.vocalTailBeats + 4; n++)
          [n + 32 >= 0 ? outT[n + 32] : start - (src(0) - bg.smoothBeat(bBase + n + 32)), vg.smoothBeat(vEntryBeat + n)]
      ];
      final vIn = barX(Mashup.introBars);
      final vOut = barX(outroBar);
      final outStartV = warp.first[0];
      final srcStartV = math.max(0.0, warp.first[1]);
      final srcEndV = warp.last[1] + 0.05;
      final preRollOut = vIn - outStartV;

      m
        ..beatTimes = List.unmodifiable(outT)
        ..start = start
        ..vocalIn = vIn
        ..vocalOut = vOut
        ..end = barX(m.totalBars)
        ..vocalRate = (warp.last[1] - warp.first[1]) / (warp.last[0] - warp.first[0])
        ..playedBpm = bg.steadyBpm * m.tempoScale;
      // Cuts go where the blend into this mashup is over. The first mashup is
      // also cut where its vocal enters, so the opening renders in a second
      // or two and the set can start straight away.
      cuts.add(vIn);

      // Blend keyframes shared by every stem of this mashup.
      List<Keyframe> head() {
        if (i == 0) return [Keyframe(start)];
        return [
          Keyframe(barX(0), gain: 0, low: kill, high: -6),
          Keyframe(barX(3), gain: 0.8, low: kill),
          Keyframe(barX(4) - beatLen(3) * 0.25, gain: 0.95, low: kill),
          Keyframe(barX(4)),
        ];
      }

      List<Keyframe> tail({required bool last}) {
        final o = outroBar;
        if (last) return [Keyframe(barX(o + 4)), Keyframe(barX(o + 8), gain: 0, lpf: 2500)];
        return [
          Keyframe(barX(o)),
          Keyframe(barX(o + 4) - beatLen(o + 3) * 0.25),
          Keyframe(barX(o + 4), low: kill),
          Keyframe(barX(o + 6), low: kill),
          Keyframe(barX(o + 8), gain: 0, low: kill, hpf: 450),
        ];
      }

      final isLast = i == ms.length - 1;
      final vBeat = beatLen(outroBar - 1);
      for (var li = 0; li < m.lanes.length; li++) {
        final lane = m.lanes[li];
        if (!m.laneAudible(lane)) continue;
        final song = lane.fromVocalSong ? m.vocal : m.beat;
        final path = song.stems!.paths[lane.stem]!;

        if (lane.fromVocalSong && !m.beatOnly) {
          final keys = lane.stem == 'vocals'
              // The featured vocal: rides in over the groove, leaves smoothly.
              ? vocalKeys(outStartV, outStartV + preRollOut * 0.5, vOut, m.vocalTailBeats, vBeat)
              // Vocal song's own backing stems (only when unmuted).
              : [Keyframe(outStartV, gain: 0), Keyframe(vIn, gain: 1), Keyframe(vOut - vBeat), Keyframe(vOut, gain: 0)];
          clips.add(_clip(path, srcStartV, srcEndV, outStartV, m.vocalRate, m.renderedVocalCents, group + li, vBeat * 0.75,
              keys, gainDb: m.beatGainDb + (lane.stem == 'vocals' ? m.autoVocalDb : m.autoVocalDb - 1.5), warp: warp, bus: 1));
          continue;
        }
        if (lane.fromVocalSong) continue; // beat break: no vocal-song lanes
      }

      // Beat song stems: summed into one clip (one time-stretch instead of
      // three — much faster), with a little build into the drop.
      final beatStems = [
        for (final lane in m.lanes)
          if (!lane.fromVocalSong && m.laneAudible(lane)) m.beat.stems!.paths[lane.stem]!
      ];
      if (beatStems.isNotEmpty) {
        final keys = <Keyframe>[...head()];
        if (!m.beatOnly) {
          keys.addAll([
            Keyframe(barX(Mashup.introBars - 2)),
            Keyframe(barX(Mashup.introBars) - beatLen(Mashup.introBars - 1) * 0.25, low: kill, hpf: 250),
            Keyframe(barX(Mashup.introBars)),
          ]);
        }
        keys.addAll(tail(last: isLast));
        keys.sort((a, b) => a.t.compareTo(b.t));
        // Vocal pocket: dip the beat around 3 kHz while the vocal sings.
        final pocketed = m.beatOnly || !m.laneAudible(m.lanes.first) ? keys : _withPocket(keys, vIn, vOut, beatLen(8));
        clips.add(_clip(beatStems.first, srcStartB, srcEndB, start, 1.0, m.beatCents, group, beatLen(0) * 0.5, pocketed,
            gainDb: m.beatGainDb, warp: beatWarp, mix: beatStems.skip(1).toList()));
      }
      nextStart = barX(outroBar);
      prevOutro = outT.sublist(outroBar * 4, math.min(outT.length, outroBar * 4 + 33));
    }

    // Samples on the sample lane.
    for (final s in samples) {
      if (!ms.contains(s.anchor) || s.anchor.beatTimes.length < 8) continue;
      final clip = _sampleClip(s, ms.indexOf(s.anchor));
      if (clip != null) clips.add(clip);
    }

    final duration = ms.isEmpty ? 0.0 : ms.last.end + 1.5;
    final mins = (duration / 60).round();
    final summary = '${vibe.summary} · ${ms.length} mashups · ${mins >= 60 ? '${mins ~/ 60}h ${mins % 60}m' : '$mins min'}';
    final json = <String, dynamic>{'duration': duration, 'clips': clips, if (warmth != null) 'warmth': warmth};
    return MashupSetPlan(ms, duration, summary, json, cuts);
  }


  // ------------------------------------------------------------- anchor mode

  /// Beats that would make a good anchor: grooving, steady, near the vibe's
  /// tempo, and liked (tags / Shazam). Best first.
  List<LibraryTrack> anchorCandidates(List<LibraryTrack> pool) {
    final scored = <(LibraryTrack, double)>[];
    for (final t in pool) {
      final a = t.analysis;
      if (a == null || a.barCount < 48 || a.tempoDrift > 0.025) continue;
      // The anchor's drums play all set long: only tight ones.
      if ((t.stems?.gridTight ?? 1) < 0.85) continue;
      // …and it carries the set, so it needs a real bassline and steady drums.
      if (!solidAnchor(t)) continue;
      final g = _natural(a);
      var s = 1.2 * (a.danceability - 1.0) + 0.5 * tagScore(t, vibe, rng);
      s -= 3 * (math.log(g.steadyBpm / vibe.targetBpm)).abs();
      s += 0.6 * g.energy;
      scored.add((t, s));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final x in scored.take(10)) x.$1];
  }

  /// Turns a song (with stems) into an anchor: its strongest 16-bar groove.
  AnchorBeat? anchorFor(LibraryTrack t) {
    final a = t.analysis;
    if (a == null || t.stems == null) return null;
    final g = _natural(a);
    return AnchorBeat(t, g, loopStartFor(t, g).$1);
  }

  /// A song's best 16-bar loop to come home to (first bar, score): strong,
  /// steady, and no drum or bass gaps, since it repeats.
  (int, double) loopStartFor(LibraryTrack t, Analysis g) {
    var best = -1e9;
    var start = g.firstBar;
    for (var s = g.firstBar; s + AnchorBeat.loopBars <= g.lastBar; s++) {
      if ((s - g.firstBar) % 8 != 0) continue;
      final e = _meanEnergy(g, s, s + AnchorBeat.loopBars);
      final steady = g.fit(g.beatIndexOfBar(s), g.beatIndexOfBar(s + AnchorBeat.loopBars)).trustworthy ? 0.2 : 0;
      // The loop repeats all set: no drum or bass gaps in it.
      final (drumsOut, bassOut) = dropouts(t, g, s, s + AnchorBeat.loopBars);
      final score = e + steady - 4 * drumsOut - 2 * bassOut - (s - g.firstBar) / 400;
      if (score > best) {
        best = score;
        start = s;
      }
    }
    return (start, best);
  }

  /// A pairing re-fitted to the anchor: both songs at the anchor's tempo, the
  /// beat shifted (up to 2 semitones) and the vocal (up to 3) into its key.
  _Pair? anchored(_Pair p, AnchorBeat anchor) {
    final t = anchor.tempo;
    final bg = fitTo(p.beat.analysis!, t, 0.08);
    final vg = fitTo(p.vocal.analysis!, t, 0.14);
    if (bg == null || vg == null) return null;
    int? bestShift(String key, List<int> shifts, double perStep) {
      int? best;
      var score = -1.0;
      for (final s in shifts) {
        final c = keyCompat(anchor.camelot, shiftCamelot(key, s)) - perStep * s.abs();
        if (c > score) {
          score = c;
          best = s;
        }
      }
      return best != null && keyCompat(anchor.camelot, shiftCamelot(key, best)) >= 0.8 ? best : null;
    }

    final bs = bestShift(bg.camelot, const [0, 1, -1, 2, -2], 0.08);
    final vs = bestShift(vg.camelot, const [0, 1, -1, 2, -2, 3, -3], 0.07);
    if (bs == null || vs == null) return null;
    final stretch = (t / bg.steadyBpm - 1).abs() + 0.5 * (t / vg.steadyBpm - 1).abs();
    // Loose live drumming (beats far off any steady grid) makes a vocal
    // wobble against the beat: such songs are only used when little else fits.
    double loose(LibraryTrack x) => ((0.85 - (x.stems?.gridTight ?? 1)) * 6).clamp(0.0, 3.0);
    // Each beat carries its section on its own: bass-less or drum-less ones last.
    final weak = weakBeat(p.beat) ? 3.0 : 0.0;
    final score = p.score - 0.3 * bs.abs() - 0.15 * vs.abs() - 4 * stretch - loose(p.vocal) - loose(p.beat) - weak;
    return _Pair(p.vocal, p.beat, vg, bg, vs, score, bs);
  }

  /// Re-fits a mashup (e.g. one you picked or shuffled) to the anchor.
  Mashup conform(Mashup m, AnchorBeat anchor) {
    final t = anchor.tempo;
    final bg = fitTo(m.beat.analysis!, t, 1) ?? m.beatGrid;
    if (m.beatOnly) {
      final b = Mashup(m.vocal, m.beat, bg, bg, beatOnly: true)..vocalBars = m.vocalBars;
      _placeBeat(b);
      return b;
    }
    final vg = fitTo(m.vocal.analysis!, t, 1) ?? m.vocalGrid;
    int shift(String key, int range) {
      var best = 0;
      var score = -1.0;
      for (var s = -range; s <= range; s++) {
        final c = keyCompat(anchor.camelot, shiftCamelot(key, s)) - 0.07 * s.abs();
        if (c > score) {
          score = c;
          best = s;
        }
      }
      return best;
    }

    final n = build(_Pair(m.vocal, m.beat, vg, bg, shift(vg.camelot, 3), 0, shift(bg.camelot, 2)));
    if (n == null) return m;
    n
      ..vocalDb = m.vocalDb
      ..beatDb = m.beatDb
      ..fineCents = m.fineCents;
    for (var i = 0; i < n.lanes.length && i < m.lanes.length; i++) {
      n.lanes[i]
        ..muted = m.lanes[i].muted
        ..solo = m.lanes[i].solo;
    }
    return n;
  }

  /// Anchor-mode layout (Dean's structure), on one master grid at the anchor's
  /// tempo:
  ///   anchor intro → vocal 1 enters over the anchor → 4–8 bars in, beat 1
  ///   rises in (no bass) for 2 bars and takes over on the downbeat (bass
  ///   swap, the anchor drops out) → the vocal sings over beat 1 → beat 1
  ///   plays on alone for 8 bars → vocal 2 enters over beat 1 → beat 2 takes
  ///   over the same way … Mid-set (5+ mashups) and for the outro the set
  ///   comes home (8 bars of beat solo, the home groove swaps back in, 4 bars
  ///   of it, next vocal) to a promoted anchor: the strongest beat used so
  ///   far. The original anchor is heard at most twice, so the set travels.
  /// Only one beat is ever fully playing, so the groove under a vocal never
  /// smears, and every switch is a clean swap on a downbeat.
  MashupSetPlan layoutAnchored(List<Mashup> ms, AnchorBeat anchor,
      {Map<String, dynamic>? warmth, List<SamplePlacement> samples = const []}) {
    final p = 60 / anchor.tempo; // seconds per beat
    final barLen = 4 * p;
    double bt(num bar) => bar * barLen;
    const kill = -30.0;
    const rise = 2, solo = 8, gap = 4; // bars
    final clips = <Map<String, dynamic>>[];
    final cuts = <double>[];

    // The original anchor opens the set. Later, the set comes home to a
    // promoted anchor instead: the strongest beat used so far (solid drums,
    // real bass, an unbroken loop), mid-set (sets of 5+) and for the outro.
    // So the original is heard at most twice, and usually once.
    final mid = ms.length >= 5 ? ms.length ~/ 2 : -1;
    int? promoted;
    var promotedLoop = 0;
    var bestScore = -1e9;
    for (var i = 1; i < (mid > 0 ? mid : ms.length - 1); i++) {
      final b = ms[i].beat, g = ms[i].beatGrid;
      if (!(b.stems?.hasCurves ?? false) || !solidAnchor(b) || weakBeat(b)) continue;
      final (loop, score) = loopStartFor(b, g);
      final (drumsOut, bassOut) = dropouts(b, g, loop, loop + AnchorBeat.loopBars);
      if (drumsOut > 0.02 || bassOut > 0.1) continue;
      final sc = score + 0.05 * (b.stems!.relative('bass') ?? -10);
      if (sc > bestScore) {
        bestScore = sc;
        promoted = i;
        promotedLoop = loop;
      }
    }
    final home = [
      for (var i = 0; i < ms.length; i++) i == ms.length - 1 || (promoted != null && i == mid)
    ];

    // Structure, in master bars: beatIn is the downbeat the mashup's beat
    // takes over on; beatEnd the downbeat the next beat (or the home groove)
    // takes over from it.
    final vIn = <int>[], beatIn = <int>[], beatEnd = <int>[];
    var cursor = 8; // 8 bars of anchor first
    for (var i = 0; i < ms.length; i++) {
      final len = ms[i].vocalBars;
      final settle = ms[i].beatOnly ? rise : (len >= 32 ? 8 : 4);
      vIn.add(cursor);
      beatIn.add(cursor + settle);
      beatEnd.add(cursor + len + solo);
      cursor += len + solo + (home[i] ? gap : 0);
    }
    for (var i = 0; i + 1 < ms.length; i++) {
      if (!home[i]) beatEnd[i] = beatIn[i + 1]; // carries the next vocal in
    }
    final endBar = ms.isEmpty ? 16 : beatEnd.last + 12;

    // Vocal spans (for the vocal pocket on whatever beat is under them).
    final spans = <(double, double)>[
      for (var i = 0; i < ms.length; i++)
        if (!ms[i].beatOnly && ms[i].laneAudible(ms[i].lanes.first)) (bt(vIn[i]), bt(vIn[i] + ms[i].vocalBars))
    ];

    // Gain over time of a home groove: it drops out in the last quarter beat
    // before a mashup's beat takes over (bass and all), and swaps back in
    // rising without bass over 2 bars, full on the downbeat.
    List<(double, double, double)> envelope({required bool opens, required bool homes}) {
      final env = <(double, double, double)>[opens ? (0, 1, 0) : (0, 0, kill)]; // (time, gain, low)
      if (ms.isNotEmpty && opens) {
        env
          ..add((bt(beatIn[0]) - p * 0.25, 1, 0))
          ..add((bt(beatIn[0]), 0, kill));
      }
      if (homes) {
        for (var i = 0; i < ms.length; i++) {
          if (!home[i]) continue;
          env
            ..add((bt(beatEnd[i] - rise), 0, kill))
            ..add((bt(beatEnd[i]) - p * 0.25, 0.8, kill))
            ..add((bt(beatEnd[i]), 1, 0));
          if (i + 1 < ms.length) {
            env
              ..add((bt(beatIn[i + 1]) - p * 0.25, 1, 0))
              ..add((bt(beatIn[i + 1]), 0, kill));
          }
        }
        env
          ..add((bt(endBar - 8), 1, 0))
          ..add((bt(endBar), 0, 0));
      }
      env.sort((a, b) => a.$1.compareTo(b.$1));
      return env;
    }

    // A home groove's clips: its 16-bar loop, one clip per loop pass (20 ms
    // crossfades at the loop points), skipped where it is silent.
    void addGroove(LibraryTrack track, Analysis grid, int loopStart, double cents, double gainDb,
        List<(double, double, double)> env) {
      double envAt(double t, {bool low = false}) {
        if (t <= env.first.$1) return low ? env.first.$3 : env.first.$2;
        for (var i = 1; i < env.length; i++) {
          if (t <= env[i].$1) {
            final a = env[i - 1], b = env[i];
            final x = (t - a.$1) / math.max(1e-9, b.$1 - a.$1);
            return low ? a.$3 + (b.$3 - a.$3) * x : a.$2 + (b.$2 - a.$2) * x;
          }
        }
        return low ? env.last.$3 : env.last.$2;
      }

      final aStems = [
        for (final s in const ['other', 'bass', 'drums']) track.stems!.paths[s]!
      ];
      final aBase = grid.beatIndexOfBar(loopStart);
      const xf = 0.02;
      for (var c0 = 0; c0 < endBar; c0 += AnchorBeat.loopBars) {
        final c1 = math.min(endBar, c0 + AnchorBeat.loopBars);
        final w0 = bt(c0) - (c0 > 0 ? xf : 0), w1 = bt(c1) + xf;
        var audible = false;
        for (var t = w0; t <= w1; t += p) {
          if (envAt(t) > 0.001) {
            audible = true;
            break;
          }
        }
        if (!audible) continue;
        final warp = <List<double>>[
          for (var n = 0; n <= (c1 - c0) * 4; n++) [bt(c0) + n * p, grid.smoothBeat(aBase + n)]
        ];
        final slope = (warp[1][1] - warp[0][1]) / (warp[1][0] - warp[0][0]);
        final times = <double>{w0, w1, for (final e in env) if (e.$1 > w0 && e.$1 < w1) e.$1};
        if (c0 > 0) times.add(bt(c0) + xf);
        times.add(bt(c1) - xf);
        final sorted = times.toList()..sort();
        var keys = <Keyframe>[
          for (final t in sorted)
            Keyframe(t,
                gain: envAt(t) *
                    (c0 > 0 && t < bt(c0) + xf ? ((t - w0) / (2 * xf)).clamp(0.0, 1.0) : 1) *
                    (t > bt(c1) - xf ? ((w1 - t) / (2 * xf)).clamp(0.0, 1.0) : 1),
                low: envAt(t, low: true))
        ];
        keys = _withPockets(keys, spans, p);
        clips.add(_clip(aStems.first, math.max(0, warp.first[1] - (bt(c0) - w0) * slope), warp.last[1] + xf * slope + 0.02, w0,
            1.0, cents, 0, p * 0.5, keys,
            gainDb: gainDb, warp: warp, mix: aStems.skip(1).toList()));
      }
    }

    addGroove(anchor.track, anchor.grid, anchor.loopStart, anchor.cents, anchor.gainDb,
        envelope(opens: true, homes: promoted == null));
    if (promoted != null) {
      final m = ms[promoted];
      addGroove(m.beat, m.beatGrid, promotedLoop, m.beatCents,
          sectionGainDb(m.beat, m.beatGrid, promotedLoop, promotedLoop + AnchorBeat.loopBars) ?? m.beatGainDb,
          envelope(opens: false, homes: true));
    }

    // Each mashup: its vocal over the anchor, then its own beat.
    for (var i = 0; i < ms.length; i++) {
      final m = ms[i];
      final bg = m.beatGrid, vg = m.vocalGrid;
      final len = m.vocalBars;
      final group = (i % 2) * 8;

      // Beat: rises in (no bass) over 2 bars, takes over on beatIn, keeps the
      // bass through the anchor's rise and hands over on beatEnd.
      final beatStems = [
        for (final lane in m.lanes)
          if (!lane.fromVocalSong && m.laneAudible(lane)) m.beat.stems!.paths[lane.stem]!
      ];
      if (beatStems.isNotEmpty) {
        final b0 = beatIn[i] - rise, b1 = beatEnd[i];
        final bBase = bg.beatIndexOfBar(m.beatStart);
        final warp = <List<double>>[
          for (var n = 0; n <= (b1 - b0) * 4; n++) [bt(b0) + n * p, bg.smoothBeat(bBase + n)]
        ];
        var keys = <Keyframe>[
          Keyframe(bt(b0), gain: 0, low: kill),
          Keyframe(bt(beatIn[i]) - p * 0.25, gain: 0.8, low: kill),
          Keyframe(bt(beatIn[i])),
          Keyframe(bt(b1) - p * 0.25),
          Keyframe(bt(b1), gain: 0, low: kill),
        ];
        keys = _withPockets(keys, spans, p);
        // Levelled on the bars that actually play, the same way as the
        // anchor, so no section jumps out or drops away.
        final gain = sectionGainDb(m.beat, bg, m.beatStart, m.beatStart + b1 - b0) ?? m.beatGainDb;
        clips.add(_clip(beatStems.first, math.max(0, warp.first[1]), warp.last[1] + 0.05, bt(b0), 1.0, m.beatCents, group,
            p * 0.5, keys, gainDb: gain, warp: warp, mix: beatStems.skip(1).toList()));
      }

      // Vocal: pinned beat by beat onto the master grid from its first bar.
      final vEntry = vg.beatIndexOfBar(m.vocalStart);
      final vInT = bt(vIn[i]), vOutT = bt(vIn[i] + len);
      if (!m.beatOnly) {
        final warp = <List<double>>[
          for (var n = -2; n <= len * 4 + m.vocalTailBeats + 4; n++) [vInT + n * p, vg.smoothBeat(vEntry + n)]
        ];
        final outStartV = warp.first[0];
        for (var li = 0; li < m.lanes.length; li++) {
          final lane = m.lanes[li];
          if (!lane.fromVocalSong || !m.laneAudible(lane)) continue;
          final path = m.vocal.stems!.paths[lane.stem]!;
          final keys = lane.stem == 'vocals'
              ? vocalKeys(outStartV, outStartV + p, vOutT, m.vocalTailBeats, p)
              : [Keyframe(outStartV, gain: 0), Keyframe(vInT, gain: 1), Keyframe(vOutT - p), Keyframe(vOutT, gain: 0)];
          clips.add(_clip(path, math.max(0.0, warp.first[1]), warp.last[1] + 0.05, outStartV,
              (warp.last[1] - warp.first[1]) / (warp.last[0] - warp.first[0]), m.renderedVocalCents, group + li, p * 0.75,
              keys,
              gainDb: m.beatGainDb + (lane.stem == 'vocals' ? m.autoVocalDb : m.autoVocalDb - 1.5), warp: warp, bus: 1));
        }
        m.vocalRate = (warp.last[1] - warp.first[1]) / (warp.last[0] - warp.first[0]);
      }

      final first = i == 0 ? 0 : vIn[i] - (home[i - 1] ? gap : 0);
      m
        ..start = bt(first)
        ..vocalIn = vInT
        ..vocalOut = vOutT
        ..end = bt(beatEnd[i])
        ..playedBpm = anchor.tempo
        ..beatTimes = List.unmodifiable([for (var n = first * 4; n <= (math.max(beatEnd[i], i + 1 < ms.length ? vIn[i + 1] : 0) + gap) * 4; n++) n * p]);
      cuts.add(vInT);
    }

    for (final s in samples) {
      if (!ms.contains(s.anchor) || s.anchor.beatTimes.length < 8) continue;
      final clip = _sampleClip(s, ms.indexOf(s.anchor));
      if (clip != null) clips.add(clip);
    }

    final duration = bt(endBar) + 1.5;
    final mins = (duration / 60).round();
    final summary = '${vibe.summary} · ⚓ ${anchor.track.title}${promoted == null ? '' : ' → ${ms[promoted].beat.title}'} · ${ms.length} mashups · '
        '${mins >= 60 ? '${mins ~/ 60}h ${mins % 60}m' : '$mins min'}';
    final json = <String, dynamic>{'duration': duration, 'clips': clips, if (warmth != null) 'warmth': warmth};
    return MashupSetPlan(ms, duration, summary, json, cuts);
  }

  /// The vocal pocket for several vocals (whichever is singing at the time).
  static List<Keyframe> _withPockets(List<Keyframe> keys, List<(double, double)> spans, double beat) {
    var out = keys;
    final mids = <double, double>{};
    for (final (a, b) in spans) {
      final k = _withPocket(out, a, b, beat);
      for (final x in k) {
        mids[x.t] = math.min(mids[x.t] ?? 0, x.mid);
      }
      out = k;
    }
    return [
      for (final k in out)
        Keyframe(k.t, gain: k.gain, low: k.low, mid: mids[k.t] ?? 0, high: k.high, hpf: k.hpf, lpf: k.lpf, echo: k.echo)
    ];
  }

  /// Adds the vocal pocket (−4 dB around 3 kHz) to a clip's automation between
  /// [vIn] and [vOut], ramping over a beat at each end.
  static List<Keyframe> _withPocket(List<Keyframe> keys, double vIn, double vOut, double beat) {
    const dip = -4.0;
    double pocketAt(double t) {
      if (t <= vIn - beat || t >= vOut + beat) return 0;
      if (t < vIn) return dip * (t - (vIn - beat)) / beat;
      if (t > vOut) return dip * (1 - (t - vOut) / beat);
      return dip;
    }

    Keyframe at(double t) {
      // Value of the existing automation at t (linear between keys).
      if (keys.isEmpty) return Keyframe(t);
      if (t <= keys.first.t) return Keyframe(t, gain: keys.first.gain, low: keys.first.low, high: keys.first.high,
          hpf: keys.first.hpf, lpf: keys.first.lpf, echo: keys.first.echo);
      for (var i = 1; i < keys.length; i++) {
        if (t < keys[i].t) {
          final a = keys[i - 1], b = keys[i];
          final x = (t - a.t) / math.max(1e-9, b.t - a.t);
          double l(double p, double q) => p + (q - p) * x;
          double lf(double p, double q) => math.exp(math.log(p) + (math.log(q) - math.log(p)) * x);
          return Keyframe(t, gain: l(a.gain, b.gain), low: l(a.low, b.low), high: l(a.high, b.high),
              hpf: lf(a.hpf, b.hpf), lpf: lf(a.lpf, b.lpf), echo: l(a.echo, b.echo));
        }
      }
      final z = keys.last;
      return Keyframe(t, gain: z.gain, low: z.low, high: z.high, hpf: z.hpf, lpf: z.lpf, echo: z.echo);
    }

    final times = <double>{for (final k in keys) k.t, vIn - beat, vIn, vOut, vOut + beat}.toList()..sort();
    return [
      for (final t in times)
        () {
          final k = at(t);
          return Keyframe(t, gain: k.gain, low: k.low, mid: pocketAt(t), high: k.high, hpf: k.hpf, lpf: k.lpf, echo: k.echo);
        }()
    ];
  }

  /// Mix time of beat n of a mashup (extrapolated past its end).
  static double _beatAt(Mashup m, int n) {
    final b = m.beatTimes;
    if (n < 0) return b.first + n * (b[1] - b[0]);
    if (n < b.length) return b[n];
    final last = b.length - 1;
    return b[last] + (n - last) * (b[last] - b[last - 1]);
  }

  Map<String, dynamic>? _sampleClip(SamplePlacement s, int index) {
    final t = s.track;
    final path = s.vocalOnly ? t.stems?.paths['vocals'] : t.path;
    if (path == null) return null;
    final startBeat = s.bar * 4, beats = s.bars * 4;
    final t0 = _beatAt(s.anchor, startBeat), t1 = _beatAt(s.anchor, startBeat + beats);
    final cents = Tuning.toReference(s.vocalOnly ? (t.stems?.tuning['vocals'] ?? t.tuningHz) : (t.tuningHz ?? t.analysis?.tuning));
    final gain = s.autoDb + s.db + (s.vocalOnly ? 4 : 0); // a vocal alone measures quieter
    final f = math.min(s.fade, (t1 - t0) / 3);
    final keys = [
      Keyframe(t0, gain: f > 0 ? 0 : 1),
      Keyframe(t0 + f),
      Keyframe(t1 - f),
      Keyframe(t1, gain: 0),
    ];
    final a = t.analysis;
    if (s.sync && a != null) {
      // Lock its beats to the mashup's beats, from its first downbeat.
      final g = MashupMaker.fitTo(a, s.anchor.tempo * s.anchor.tempoScale, 0.25);
      if (g != null) {
        final first = g.beatIndexOfBar(g.firstBar);
        final warp = <List<double>>[
          for (var n = 0; n <= beats && first + n < g.beats.length; n++) [_beatAt(s.anchor, startBeat + n), g.smoothBeat(first + n)]
        ];
        if (warp.length >= 2) {
          return _clip(path, math.max(0, warp.first[1]), warp.last[1] + 0.05, warp.first[0], 1.0, cents, 0, 0.25, keys,
              gainDb: gain, warp: warp);
        }
      }
    }
    // Free-running (ambient sounds, or sync off): plays at its own speed.
    final len = math.min(t.duration > 0 ? t.duration : 600.0, t1 - t0);
    return _clip(path, 0, len, t0, 1.0, cents, 0, 0.25, keys.map((k) => k.t > t0 + len ? Keyframe(t0 + len, gain: 0) : k).toList(),
        gainDb: gain);
  }

  Map<String, dynamic> _clip(String path, double srcStart, double srcEnd, double outStart, double rate, double cents,
          int deck, double echoTime, List<Keyframe> keys,
          {double gainDb = 0, List<List<double>>? warp, int bus = 0, List<String> mix = const []}) =>
      {
        'path': path,
        'srcStart': srcStart,
        'srcEnd': srcEnd,
        'outStart': outStart,
        'rate': rate,
        'pitchCents': cents,
        'gainDb': gainDb,
        'deck': deck,
        'echoTime': echoTime,
        'keys': keys.map((k) => k.toJson()).toList(),
        if (warp != null) 'warp': warp,
        if (bus != 0) 'bus': bus,
        if (mix.isNotEmpty) 'mix': mix,
      };
}

// ---------------------------------------------------------
// SESSION (the current set, built progressively, with spares)
// ---------------------------------------------------------

/// The mashups in the set, plus the ranked pairings to draw new ones from.
/// Long sets are built in the background, a few mashups at a time.
class MashupSession {
  final MashupMaker maker;
  final List<LibraryTrack> pool;
  final List<_Pair> _ranked;
  final List<Mashup> mashups = [];
  final List<SamplePlacement> samples = [];

  /// Samples follow their slot when a mashup is replaced (swap / shuffle / pick).
  void _reanchor(Mashup old, Mashup now) {
    for (final s in samples) {
      if (identical(s.anchor, old)) s.anchor = now;
    }
  }

  /// Puts a sound/song on the sample lane over mashup [i].
  Future<SamplePlacement> addSample(int i, LibraryTrack t, MusicLibrary lib) async {
    await lib.analyze([t], (d, n) {});
    final m = mashups[i];
    // Beat songs default to 16 bars over the intro blend; ambient sounds to
    // about 30 s.
    final s = SamplePlacement(t, m, bar: 0, bars: t.analysis != null ? 16 : math.max(4, (30 / (240 / m.tempo)).round()));
    samples.add(s);
    return s;
  }
  final Set<String> _rejected = {};
  /// Anchor mode: beats that turned out bass-less or without an unbroken
  /// groove once split (any pairing with them is skipped).
  final Set<String> _badBeats = {};
  /// …and beats whose grooves have gaps, skipped until the set runs short.
  final Set<String> _gappy = {};
  bool _relaxed = false;
  bool cancelled = false;
  int target = 0;

  /// Anchor mode: one steady groove the set comes home to (null = classic).
  bool anchorMode = false;
  AnchorBeat? anchor;
  final Map<String, _Pair?> _anchoredCache = {};

  MashupSession(this.maker, this.pool, this._ranked);

  _Pair? _anchoredPair(_Pair p) =>
      _anchoredCache.putIfAbsent(p.key, () => anchor == null ? null : maker.anchored(p, anchor!));

  /// Best unused pairing that fits the anchor (anchor mode).
  _Pair? _pickAnchored(double pos, Set<String> used) {
    _Pair? best;
    var bestScore = -1e9;
    var looked = 0;
    for (final x in _ranked) {
      if (used.contains(x.vocal.path) || used.contains(x.beat.path) || _rejected.contains(x.key)) continue;
      if (_badBeats.contains(x.beat.path) || _gappy.contains(x.beat.path)) continue;
      if (anchor != null && (identical(x.beat, anchor!.track) || identical(x.vocal, anchor!.track))) continue;
      final a = _anchoredPair(x);
      if (a == null) continue;
      final s = a.score - 2 * (a.bGrid.energy - maker.vibe.energyAt(pos)).abs();
      if (s > bestScore) {
        bestScore = s;
        best = a;
      }
      if (++looked > 3000) break;
    }
    return best;
  }

  /// Picks and prepares the anchor (splits its stems).
  Future<bool> _ensureAnchor(MusicLibrary lib, void Function(String) onStatus) async {
    if (anchor != null) return true;
    for (final t in maker.anchorCandidates(pool)) {
      onStatus('Choosing the anchor beat · ${t.title}');
      await lib.separate([t], (d, n, c) {});
      if (!MashupMaker.solidAnchor(t)) continue; // thin bass / drums, now we can hear it
      final a = maker.anchorFor(t);
      if (a != null) {
        anchor = a;
        _anchoredCache.clear();
        return true;
      }
    }
    return false;
  }

  /// Makes [t] the anchor beat and re-fits every mashup to it.
  Future<String?> setAnchor(LibraryTrack t, MusicLibrary lib, void Function(String) onStatus) async {
    onStatus('Making "${t.title}" the anchor beat…');
    await lib.analyze([t], (d, n) {});
    if (t.analysis == null) return 'Couldn\'t find a steady beat in "${t.title}".';
    await lib.separate([t], (d, n, c) => onStatus('Splitting stems · ${t.title}'));
    final a = maker.anchorFor(t);
    if (a == null) return 'Couldn\'t use "${t.title}" as the anchor.';
    anchor = a;
    anchorMode = true;
    _anchoredCache.clear();
    for (var i = 0; i < mashups.length; i++) {
      final n = maker.conform(mashups[i], a);
      _reanchor(mashups[i], n);
      mashups[i] = n;
    }
    return null;
  }

  /// In anchor mode, fits a newly made mashup to the anchor.
  Mashup _fit(Mashup m) => anchorMode && anchor != null ? maker.conform(m, anchor!) : m;

  static MashupSession start(MashupMaker maker, List<LibraryTrack> pool) =>
      MashupSession(maker, pool, maker.rankPairs(pool));

  Set<String> get _used => {for (final m in mashups) ...[m.vocal.path, m.beat.path]};

  /// Keeps adding mashups until there are [count]. Calls [onAdded] after each
  /// batch so the set can start playing while the rest is prepared.
  Future<void> fill(MusicLibrary lib, int count, void Function(String status) onStatus, void Function() onAdded) async {
    target = count;
    var misses = 0;
    if (anchorMode && !await _ensureAnchor(lib, onStatus)) anchorMode = false;
    while (!cancelled && mashups.length < target) {
      if (misses >= (anchorMode ? 12 : 6)) {
        // Anchor mode: rather than end the set short, allow beats with small
        // gaps once the unbroken ones run out.
        if (!anchorMode || _relaxed) break;
        _relaxed = true;
        _gappy.clear();
        misses = 0;
      }
      // Plan the next few, then split all their stems in one go (faster).
      final picks = <_Pair>[];
      final used = _used;
      Mashup? prevSim = mashups.isEmpty ? null : mashups.last;
      double prevTempo = prevSim?.tempo ?? 0;
      final batch = mashups.length < 2 ? 2 : 4;
      for (var k = 0; k < batch && mashups.length + picks.length < target; k++) {
        final p = (mashups.length + picks.length) / math.max(1, target - 1);
        final pick = anchorMode ? _pickAnchored(p, used) : maker.pickNext(_ranked, prevSim, p, used, _rejected);
        if (pick == null) break;
        if (!anchorMode && prevTempo > 0 && (math.log(pick.tempo / prevTempo)).abs() > math.log(1.06)) break;
        picks.add(pick);
        used
          ..add(pick.vocal.path)
          ..add(pick.beat.path);
        prevTempo = pick.tempo;
        prevSim = null; // later picks in the batch chain on tempo only
      }
      if (picks.isEmpty) {
        if (anchorMode && !_relaxed) {
          misses = 99;
          continue;
        }
        break;
      }
      final songs = {for (final p in picks) ...[p.vocal, p.beat]}.toList();
      await lib.separate(songs, (d, t, c) {
        onStatus('Splitting stems for mashup ${mashups.length + 1}–${mashups.length + picks.length} of $target'
            '${c == null ? '' : ' · ${c.title}'}');
      });
      if (cancelled) return;
      var added = 0;
      for (final p in picks) {
        var m = anchorMode && MashupMaker.weakBeat(p.beat) ? null : maker.build(p);
        if (anchorMode && m == null && MashupMaker.weakBeat(p.beat)) {
          _badBeats.add(p.beat.path);
          continue;
        }
        if (anchorMode && m != null && MashupMaker.gappyBeat(m, relaxed: _relaxed)) {
          _gappy.add(p.beat.path);
          continue;
        }
        if (m == null) {
          _rejected.add(p.key);
          continue;
        }
        mashups.add(m);
        added++;
      }
      misses = added == 0 ? misses + 1 : 0;
      if (added > 0) onAdded();
    }
  }

  Future<Mashup?> _another(MusicLibrary lib, Mashup? prev, double p, Set<String> avoid, void Function(String) onStatus) async {
    for (var attempt = 0; attempt < 6; attempt++) {
      final pick = anchorMode
          ? _pickAnchored(p, {..._used, ...avoid})
          : maker.pickNext(_ranked, prev, p, {..._used, ...avoid}, _rejected);
      if (pick == null) return null;
      await lib.separate([pick.vocal, pick.beat], (d, t, c) => onStatus('Splitting stems${c == null ? '' : ' · ${c.title}'}'));
      final m = anchorMode && MashupMaker.weakBeat(pick.beat) ? null : maker.build(pick);
      if (anchorMode && m == null && MashupMaker.weakBeat(pick.beat)) {
        _badBeats.add(pick.beat.path);
        continue;
      }
      if (anchorMode && m != null && MashupMaker.gappyBeat(m, relaxed: _relaxed)) {
        _gappy.add(pick.beat.path);
        continue;
      }
      if (m != null) return m;
      _rejected.add(pick.key);
    }
    return null;
  }

  Future<bool> shuffle(int i, MusicLibrary lib, void Function(String status) onStatus) async {
    final old = mashups[i];
    final m = await _another(lib, i > 0 ? mashups[i - 1] : null, i / math.max(1, mashups.length - 1),
        {old.vocal.path, old.beat.path}, onStatus);
    if (m == null) return false;
    _reanchor(old, m);
    mashups[i] = m;
    return true;
  }

  bool swap(int i) {
    final s = maker.swapped(mashups[i]);
    if (s == null) return false;
    final m = _fit(s);
    _reanchor(mashups[i], m);
    mashups[i] = m;
    return true;
  }

  /// Puts [song] in after mashup [i]: as a beat break, or with an AI vocal on it.
  Future<String?> insertBeat(int i, LibraryTrack song, bool withVocal, MusicLibrary lib, void Function(String) onStatus) async {
    onStatus('Listening to ${song.title}…');
    await lib.analyze([song], (d, t) {});
    if (song.analysis == null) return 'Couldn\'t read the beat in "${song.title}".';
    if (withVocal) {
      final pairs = maker.rankPairs(pool, onlyBeat: song).where((p) => !_used.contains(p.vocal.path)).toList();
      for (final p in pairs.take(5)) {
        onStatus('Finding a vocal for ${song.title}…');
        await lib.separate([p.vocal, song], (d, t, c) => onStatus('Splitting stems${c == null ? '' : ' · ${c.title}'}'));
        final m = maker.build(p);
        if (m != null) {
          mashups.insert(i + 1, _fit(m));
          return null;
        }
      }
      return 'Couldn\'t find a vocal that fits "${song.title}" — try Beat only.';
    }
    await lib.separate([song], (d, t, c) => onStatus('Splitting stems · ${song.title}'));
    final m = maker.beatBreak(song, nearTempo: mashups.isEmpty ? null : mashups[i.clamp(0, mashups.length - 1)].tempo);
    if (m == null) return 'Couldn\'t split "${song.title}".';
    mashups.insert(i + 1, _fit(m));
    return null;
  }

  /// Swaps the vocal (or the beat) of mashup [i] for a song you picked.
  /// Returns an error message, or null when done.
  Future<String?> replace(int i, LibraryTrack song,
      {required bool asVocal, required MusicLibrary lib, required void Function(String) onStatus}) async {
    final old = mashups[i];
    onStatus('Listening to ${song.title}…');
    await lib.analyze([song], (d, t) {});
    if (song.analysis == null) return 'Couldn\'t read the beat in "${song.title}".';
    final vocal = asVocal ? song : (old.beatOnly ? null : old.vocal);
    final beat = asVocal ? old.beat : song;
    await lib.separate([song, if (vocal != null) vocal, beat],
        (d, t, c) => onStatus('Splitting stems${c == null ? '' : ' · ${c.title}'}'));
    Mashup? m;
    if (vocal == null) {
      // Replacing the beat of a beat break: still a beat break.
      m = maker.beatBreak(song, nearTempo: i > 0 ? mashups[i - 1].tempo : null);
      if (m == null) return 'Couldn\'t split "${song.title}".';
    } else {
      final (made, err) = maker.pairOf(vocal, beat, nearTempo: asVocal ? old.tempo : null);
      if (made == null) return err;
      m = made;
    }
    m = _fit(m);
    _reanchor(old, m);
    // Keep your settings for the half that didn't change.
    if (asVocal) {
      m
        ..beatDb = old.beatDb
        ..tempoScale = old.tempoScale;
    } else {
      m.vocalDb = old.vocalDb;
    }
    mashups[i] = m;
    return null;
  }

  MashupSetPlan layout({Map<String, dynamic>? warmth}) => anchorMode && anchor != null
      ? maker.layoutAnchored(mashups, anchor!, warmth: warmth, samples: samples)
      : maker.layout(mashups, warmth: warmth, samples: samples);

  /// Plans [count] pairings in order without splitting stems: (pair key, tempo).
  /// Used to check a library can supply a long set.
  List<(String, double)> dryRun(int count) {
    final out = <(String, double)>[];
    final used = <String>{};
    double? prevTempo;
    for (var i = 0; i < count; i++) {
      final p = i / math.max(1, count - 1);
      final target = maker.targetTempo(p);
      _Pair? best;
      var bestScore = -1e9;
      for (final x in _ranked) {
        if (used.contains(x.vocal.path) || used.contains(x.beat.path)) continue;
        if (prevTempo != null && (math.log(x.tempo / prevTempo)).abs() > math.log(1.06)) continue;
        final s = x.score - 9 * (math.log(x.tempo / target)).abs();
        if (s > bestScore) {
          bestScore = s;
          best = x;
        }
      }
      if (best == null) break;
      used
        ..add(best.vocal.path)
        ..add(best.beat.path);
      prevTempo = best.tempo;
      out.add((best.key, best.tempo));
    }
    return out;
  }
}
