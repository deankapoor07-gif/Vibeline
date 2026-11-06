import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/mashup.dart';
import 'package:vibeline/models.dart';

// Bar by bar, as measured from a copy of Livin' On a Prayer.
const vocal = <double>[0.001, 0.001, 0.001, 0.001, 0.368, 0.457, 0.368, 0.35, 0.24, 0.194, 0.276, 0.276, 0.408, 0.393, 0.27, 0.373, 0.708, 0.372, 0.675, 0.697, 0.328, 0.466, 0.568, 0.406, 0.813, 0.323, 0.627, 0.702, 0.384, 0.727, 0.527, 0.645, 0.687, 0.603, 0.554, 0.661, 0.677, 0.726, 0.543, 0.74, 0.977, 0.898, 0.821, 0.847, 0.669, 0.665, 0.754, 0.813, 0.347, 0.297, 0.669, 0.417, 0.708, 0.679, 0.368, 0.7, 0.389, 0.327, 0.814, 0.47, 0.679, 0.561, 0.715, 0.42, 0.491, 0.415, 0.655, 0.659, 0.595, 0.619, 0.734, 0.723, 0.601, 0.585, 0.95, 0.873, 0.816, 0.835, 0.718, 0.661, 0.884, 0.81, 0.707, 0.85, 0.111, 0.027, 0.002, 0.002, 0.089, 0.197, 0.003, 0.14, 0.684, 0.748, 0.858, 0.709, 0.937, 0.919, 0.84, 0.699, 0.723, 0.746, 0.756, 0.748, 0.677, 0.691, 0.676, 0.624, 0.841, 0.763, 0.734, 0.699, 0.764, 0.613, 0.321, 0.091, 0.042];
const barEnergy = <double>[0.708, 0.688, 0.703, 0.804, 0.861, 0.841, 0.841, 0.818, 0.905, 0.98, 0.919, 0.929, 0.931, 0.941, 0.916, 0.903, 0.857, 0.869, 0.84, 0.874, 0.892, 0.898, 0.894, 0.913, 0.891, 0.827, 0.836, 0.855, 0.922, 0.888, 0.906, 0.95, 0.857, 0.838, 0.882, 0.855, 0.831, 0.898, 0.903, 0.878, 0.868, 0.858, 0.855, 0.881, 0.872, 0.845, 0.84, 0.829, 0.904, 0.875, 0.869, 0.873, 0.885, 0.891, 0.885, 0.902, 0.858, 0.844, 0.9, 0.889, 0.86, 0.89, 0.896, 0.926, 0.894, 0.933, 0.895, 0.916, 0.938, 0.916, 0.921, 0.927, 0.945, 0.899, 0.862, 0.86, 0.848, 0.884, 0.849, 0.854, 0.837, 0.86, 0.838, 0.85, 0.87, 0.85, 0.881, 0.865, 0.909, 0.881, 0.894, 0.899, 1.0, 0.935, 0.952, 0.91, 0.927, 0.792, 0.818, 0.809, 0.894, 0.821, 0.826, 0.801, 0.822, 0.746, 0.759, 0.758, 0.828, 0.773, 0.773, 0.775, 0.805, 0.591, 0.317, 0.124, 0.049];

void main() {
  double at(List<double> v, int bar) => bar >= 0 && bar < v.length ? v[bar] : 0;
  double mean(int a, int b) {
    var s = 0.0;
    for (var i = a; i < b; i++) {
      s += at(barEnergy, i);
    }
    return s / (b > a ? b - a : 1);
  }

  group('a vocal has to suit the beat it sings over', () {
    // Measured from the real songs: the first mashup of a Kiwi set, where the
    // vocal suits the anchor but not the beat it spends the song over.
    const everything = <double>[0.049, 0.237, 0.071, 0.108, 0.057, 0.081, 0.081, 0.037, 0.094, 0.051, 0.078, 0.054];
    const wannaBeStartin = <double>[0.072, 0.066, 0.162, 0.048, 0.163, 0.047, 0.085, 0.066, 0.067, 0.104, 0.036, 0.084];
    const pumpUpTheJam = <double>[0.224, 0.07, 0.079, 0.157, 0.051, 0.105, 0.044, 0.082, 0.065, 0.031, 0.058, 0.035];
    const beatShift = 1; // what the beat takes to sit with this anchor

    test('a great fit with the anchor cannot excuse a clash with its own beat', () {
      expect(MashupMaker.vocalShiftByNotes(everything, wannaBeStartin, beatShift, pumpUpTheJam), isNull);
    });

    test('a vocal that suits its beat is kept', () {
      expect(MashupMaker.vocalShiftByNotes(everything, everything, 0, pumpUpTheJam), 0);
      expect(MashupMaker.vocalShiftByNotes(everything, everything, 0, null), 0);
    });

    test('with no choice to make, a clash still gets a pitch', () {
      expect(MashupMaker.vocalShiftByNotes(everything, wannaBeStartin, beatShift, pumpUpTheJam, strict: false), isNotNull);
    });
  });

  test('the beat deck follows the beat actually playing', () {
    final anchor = LibraryTrack(path: '/anchor.mp3', title: 'Anchor', artist: '', genre: '', year: 0, duration: 200);
    final first = LibraryTrack(path: '/first.mp3', title: 'First', artist: '', genre: '', year: 0, duration: 200);
    final spans = [BeatSpan(0, anchor, '8A', home: true), BeatSpan(16, first, '9A'), BeatSpan(90, anchor, '8A', home: true)];
    expect(BeatSpan.at(spans, 3)!.track, anchor);
    expect(BeatSpan.at(spans, 16)!.track, first);
    expect(BeatSpan.at(spans, 89.9)!.track, first);
    expect(BeatSpan.at(spans, 100)!.home, isTrue);
    expect(BeatSpan.at(const [], 5), isNull);
  });

  test('a vocal starts on a fresh line, not halfway through a verse', () {
    final picked = MashupMaker.pickVocalSection(
      firstBar: 0,
      lastBar: 114,
      room: 200,
      vocalAt: (b) => at(vocal, b),
      energy: mean,
      lurches: (a, b) => false,
    )!;
    expect(picked.$1, 16, reason: 'the first verse, where the singing really starts');
    expect(at(vocal, picked.$1 - 1), lessThan(0.45));
    expect(at(vocal, picked.$1 - 2), lessThan(0.45));
    expect(at(vocal, picked.$1), greaterThanOrEqualTo(0.5));
  });

  test('a song that never pauses still gets a section', () {
    final picked = MashupMaker.pickVocalSection(
      firstBar: 0,
      lastBar: 100,
      room: 200,
      vocalAt: (b) => 0.8,
      energy: (a, b) => 0.5,
      lurches: (a, b) => false,
    );
    expect(picked, isNotNull);
  });

  test('a song with nothing to sing gets none', () {
    final picked = MashupMaker.pickVocalSection(
      firstBar: 0,
      lastBar: 100,
      room: 200,
      vocalAt: (b) => 0,
      energy: (a, b) => 0.5,
      lurches: (a, b) => false,
    );
    expect(picked, isNull);
  });
}
