import 'dart:math' as math;

import 'tuning.dart';

// ---------------------------------------------------------
// LIBRARY
// ---------------------------------------------------------
class LibraryTrack {
  final String path;
  final String title;
  final String artist;
  final String genre;
  final int year;
  final double duration;
  bool shazam = false;
  Analysis? analysis;
  StemSet? stems;
  // Known even for sounds with no beat (rain, pads): level, tuning, waveform.
  double? level;
  double? tuningHz;
  List<double> waveform = const [];
  bool analysisTried = false;

  LibraryTrack({
    required this.path,
    required this.title,
    required this.artist,
    required this.genre,
    required this.year,
    required this.duration,
  });

  factory LibraryTrack.fromJson(Map<String, dynamic> j) => LibraryTrack(
        path: j['path'] as String,
        title: (j['title'] as String?) ?? '',
        artist: (j['artist'] as String?) ?? '',
        genre: (j['genre'] as String?) ?? '',
        year: (j['year'] as num?)?.toInt() ?? 0,
        duration: (j['duration'] as num?)?.toDouble() ?? 0,
      );
}

/// A song split into vocals / drums / bass / other (Demucs), plus how much
/// singing there is on each of the analyser's beats.
class StemSet {
  final Map<String, String> paths; // vocals, drums, bass, other -> FLAC file
  final List<double> vocalBeats; // per original beat, 0..1
  final double vocalShare; // vocals' share of the song's level (instrumentals ~0)
  final Map<String, double> tuning; // concert pitch (Hz) of 'vocals' and 'other'
  final Map<String, double> levels; // dB of 'vocals' (while singing) and 'instrumental'

  StemSet(this.paths, this.vocalBeats, this.vocalShare, [this.tuning = const {}, this.levels = const {}]);

  factory StemSet.fromJson(Map<String, dynamic> j) => StemSet(
        ((j['stems'] as Map?) ?? const {}).map((k, v) => MapEntry(k as String, v as String)),
        ((j['vocalBeats'] as List?) ?? const []).map((e) => (e as num).toDouble()).toList(),
        (j['vocalShare'] as num?)?.toDouble() ?? 0,
        ((j['tuning'] as Map?) ?? const {}).map((k, v) => MapEntry(k as String, (v as num).toDouble())),
        ((j['levels'] as Map?) ?? const {}).map((k, v) => MapEntry(k as String, (v as num).toDouble())),
      );

  bool get complete => const ['vocals', 'drums', 'bass', 'other'].every(paths.containsKey);

  /// Average singing level between two song times, using the original beats.
  double vocalBetween(List<double> originalBeats, double t0, double t1) {
    var sum = 0.0;
    var n = 0;
    for (var i = 0; i < vocalBeats.length && i < originalBeats.length; i++) {
      final t = originalBeats[i];
      if (t >= t1) break;
      if (t >= t0) {
        sum += vocalBeats[i];
        n++;
      }
    }
    return n == 0 ? 0 : sum / n;
  }
}

/// What the analyser heard in a song. Beat/bar indices count from the song's
/// first detected beat; [barPhase] is which beat is the first downbeat.
class Analysis {
  final double bpm;
  final List<double> beats;
  final int barPhase;
  final List<double> barEnergy;
  final int firstBar;
  final int lastBar;
  final String camelot;
  final String key;
  final double loudnessDb;
  final double danceability;
  final List<double> waveform;
  final double? tuning; // concert pitch of the recording (Hz)

  Analysis({
    required this.bpm,
    required this.beats,
    required this.barPhase,
    required this.barEnergy,
    required this.firstBar,
    required this.lastBar,
    required this.camelot,
    required this.key,
    required this.loudnessDb,
    required this.danceability,
    required this.waveform,
    this.tuning,
  });

  factory Analysis.fromJson(Map<String, dynamic> j) {
    List<double> d(String k) => ((j[k] as List?) ?? const []).map((e) => (e as num).toDouble()).toList();
    return Analysis(
      bpm: (j['bpm'] as num).toDouble(),
      beats: d('beats'),
      barPhase: (j['barPhase'] as num?)?.toInt() ?? 0,
      barEnergy: d('barEnergy'),
      firstBar: (j['firstBar'] as num?)?.toInt() ?? 0,
      lastBar: (j['lastBar'] as num?)?.toInt() ?? 0,
      camelot: (j['camelot'] as String?) ?? '',
      key: (j['key'] as String?) ?? '',
      loudnessDb: (j['loudnessDb'] as num?)?.toDouble() ?? -14,
      danceability: (j['danceability'] as num?)?.toDouble() ?? 1,
      waveform: d('waveform'),
      tuning: (j['tuning'] as num?)?.toDouble(),
    );
  }

  int get barCount => barEnergy.length;

  /// Re-counts the song at double (factor 2) or half (factor 0.5) tempo so a
  /// 80 BPM half-time read can mix with 160 BPM songs, and vice versa.
  Analysis scaled(double factor) {
    if (factor == 1) return this;
    if (factor == 2) {
      final dense = <double>[];
      for (var i = 0; i < beats.length - 1; i++) {
        dense
          ..add(beats[i])
          ..add((beats[i] + beats[i + 1]) / 2);
      }
      if (beats.isNotEmpty) dense.add(beats.last);
      final e = <double>[];
      for (final v in barEnergy) {
        e
          ..add(v)
          ..add(v);
      }
      // Each old beat becomes two; each old bar becomes two bars.
      final phase = (barPhase * 2) % 4;
      final shift = barPhase * 2 >= 4 ? 1 : 0;
      if (shift == 1 && e.isNotEmpty) e.insert(0, e.first);
      return _copy(bpm * 2, dense, phase, e, firstBar * 2 + shift, lastBar * 2 + 1 + shift);
    }
    // Half time: keep every other beat, starting on the downbeat side.
    final start = barPhase % 2;
    final sparse = <double>[for (var i = start; i < beats.length; i += 2) beats[i]];
    final e = <double>[];
    for (var i = 0; i + 1 < barEnergy.length; i += 2) {
      e.add((barEnergy[i] + barEnergy[i + 1]) / 2);
    }
    return _copy(bpm / 2, sparse, (barPhase - start) ~/ 2, e, firstBar ~/ 2, lastBar ~/ 2);
  }

  Analysis _copy(double b, List<double> bt, int ph, List<double> e, int fb, int lb) => Analysis(
        bpm: b,
        beats: bt,
        barPhase: ph,
        barEnergy: e.isEmpty ? [0] : e,
        firstBar: fb.clamp(0, math.max(0, e.length - 1)),
        lastBar: lb.clamp(0, math.max(0, e.length - 1)),
        camelot: camelot,
        key: key,
        loudnessDb: loudnessDb,
        danceability: danceability,
        waveform: waveform,
        tuning: tuning,
      );

  int beatIndexOfBar(int bar) => barPhase + 4 * bar;

  /// Straight-line fit of the beats between two beat indices. Individual beat
  /// marks wobble by a few ms and the tracker sometimes stumbles in quiet
  /// breakdowns, so stray beats are dropped before the final fit.
  LocalGrid fit(int fromBeat, int toBeat) {
    var a = fromBeat.clamp(0, beats.length - 2);
    var b = toBeat.clamp(a + 1, beats.length - 1);
    if (b - a < 8) {
      a = math.max(0, b - 8);
      b = math.min(beats.length - 1, a + 8);
    }
    var use = [for (var i = a; i <= b; i++) i];
    var grid = _lsq(use);
    for (var pass = 0; pass < 2; pass++) {
      final keep = use.where((i) => (beats[i] - grid.timeOfBeat(i)).abs() < grid.period * 0.12).toList();
      if (keep.length < math.max(6, use.length ~/ 2) || keep.length == use.length) break;
      use = keep;
      grid = _lsq(use);
    }
    var ss = 0.0;
    for (final i in use) {
      final r = beats[i] - grid.timeOfBeat(i);
      ss += r * r;
    }
    final kept = use.length / (b - a + 1);
    final jitter = math.sqrt(ss / use.length) / grid.period + (1 - kept) * 0.2;
    return LocalGrid(grid.period, grid.offset, jitter);
  }

  LocalGrid _lsq(List<int> idx) {
    final n = idx.length;
    var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
    for (final i in idx) {
      final x = i.toDouble(), y = beats[i];
      sx += x;
      sy += y;
      sxx += x * x;
      sxy += x * y;
    }
    final den = n * sxx - sx * sx;
    final period = den.abs() < 1e-9 ? 60 / bpm : (n * sxy - sx * sy) / den;
    return LocalGrid(period, (sy - period * sx) / n);
  }

  List<double>? _smooth;

  /// Beat times with tracker jitter smoothed out but real tempo drift kept
  /// (a local line fit around each beat).
  double smoothBeat(int i) {
    _smooth ??= List<double>.filled(beats.length, double.nan);
    if (i < 0 || i >= beats.length) {
      final edge = i < 0 ? 0 : beats.length - 1;
      final g = fit(edge - 8, edge + 8);
      return g.timeOfBeat(i);
    }
    if (_smooth![i].isNaN) _smooth![i] = fit(i - 8, i + 8).timeOfBeat(i);
    return _smooth![i];
  }

  List<double>? _windowTempos;

  /// Tempo of each 16-bar stretch of the song.
  List<double> get windowTempos {
    if (_windowTempos != null) return _windowTempos!;
    final out = <double>[];
    for (var s = 0; s + 64 < beats.length; s += 32) {
      out.add(60 / _lsq([for (var i = s; i < s + 64; i++) i]).period);
    }
    if (out.isEmpty) out.add(bpm);
    return _windowTempos = out;
  }

  /// The song's real tempo: the median of its 16-bar stretches, which ignores
  /// breakdowns where the beat tracker wanders.
  double get steadyBpm {
    final t = [...windowTempos]..sort();
    return t[t.length ~/ 2];
  }

  /// How much the tempo wanders (0.01 = 1%). Live bands drift; machines don't.
  double get tempoDrift {
    final t = [...windowTempos]..sort();
    if (t.length < 4) return 0;
    final lo = t[(t.length * 0.15).floor()], hi = t[(t.length * 0.85).floor().clamp(0, t.length - 1)];
    return (hi - lo) / steadyBpm;
  }

  /// Song energy on a common 0..1 scale (used to shape the set's energy curve).
  double get energy {
    final d = ((danceability - 0.8) / 1.4).clamp(0.0, 1.0);
    final l = ((loudnessDb + 22) / 12).clamp(0.0, 1.0);
    return (0.6 * d + 0.4 * l).clamp(0.0, 1.0);
  }
}

class LocalGrid {
  final double period;
  final double offset;
  final double jitter; // spread of the beats around the line, as a fraction of a beat
  const LocalGrid(this.period, this.offset, [this.jitter = 0]);

  /// The beats in this stretch sit tightly on a line, so its tempo is real
  /// (not a beat-tracker stumble).
  bool get trustworthy => jitter < 0.04;
  double timeOfBeat(num beatIndex) => offset + period * beatIndex;
}

// ---------------------------------------------------------
// MIX PLAN
// ---------------------------------------------------------
enum TransitionType { bassSwap, filterSweep, dropSwap, echoOut }

extension TransitionLabel on TransitionType {
  String get label => switch (this) {
        TransitionType.bassSwap => 'BASS SWAP',
        TransitionType.filterSweep => 'FILTER SWEEP',
        TransitionType.dropSwap => 'DROP SWAP',
        TransitionType.echoOut => 'ECHO OUT',
      };
}

class Keyframe {
  final double t;
  final double gain, low, mid, high, hpf, lpf, echo;
  const Keyframe(this.t,
      {this.gain = 1, this.low = 0, this.mid = 0, this.high = 0, this.hpf = 20, this.lpf = 20000, this.echo = 0});

  Map<String, dynamic> toJson() =>
      {'t': t, 'gain': gain, 'low': low, 'mid': mid, 'high': high, 'hpf': hpf, 'lpf': lpf, 'echo': echo};
}

class PlannedTrack {
  final LibraryTrack track;
  final Analysis grid; // tempo-scaled analysis actually used for mixing
  final double rate;
  final int pitchSemitones;
  final double gainDb;
  final int deck;
  double outStart = 0; // when it enters the mix (seconds)
  double outEnd = 0; // when it has fully left
  double srcStart = 0;
  double srcEnd = 0;
  final List<Keyframe> keys = [];
  double echoTime = 0.25;

  PlannedTrack({
    required this.track,
    required this.grid,
    required this.rate,
    required this.pitchSemitones,
    required this.gainDb,
    required this.deck,
  });

  double get playedBpm => grid.bpm * rate;

  /// Mix time -> position in the song (seconds).
  double srcAt(double mixTime) => srcStart + (mixTime - outStart) * rate;

  /// Song position -> mix time.
  double mixAt(double srcTime) => outStart + (srcTime - srcStart) / rate;

  Map<String, dynamic> toJson() => {
        'path': track.path,
        'srcStart': srcStart,
        'srcEnd': srcEnd,
        'outStart': outStart,
        'rate': rate,
        'pitchCents': pitchSemitones * 100.0 + Tuning.toReference(track.analysis?.tuning),
        'gainDb': gainDb,
        'deck': deck,
        'echoTime': echoTime,
        'keys': keys.map((k) => k.toJson()).toList(),
      };
}

class PlannedTransition {
  final TransitionType type;
  final int bars;
  final String keyMatch; // perfect / compatible / shifted / energy / clash
  final double start; // mix time the blend starts
  final double end;
  const PlannedTransition(this.type, this.bars, this.keyMatch, this.start, this.end);
}

class MixPlan {
  final List<PlannedTrack> tracks;
  final List<PlannedTransition> transitions;
  final double duration;
  final String summary;
  MixPlan(this.tracks, this.transitions, this.duration, this.summary);

  Map<String, dynamic> toRenderJson() => {
        'duration': duration,
        'clips': tracks.map((t) => t.toJson()).toList(),
      };

  /// Section boundaries: just after each blend (and any echo tail) is over.
  List<double> get cuts => [for (final t in transitions) t.end + 3.0];
}
