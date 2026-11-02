import 'fx_deck.dart';
import 'mashup.dart';
import 'models.dart';

/// Auto FX: the Beat FX moves a DJ would throw in by themselves, placed on
/// the beat at the right moments of the set. Sparing on purpose: about one
/// move per changeover, never over a vocal line or an acapella drop, and
/// varied so no trick repeats back to back.
///
/// Each cue is {start, end, kind, beats, depth}; the player holds the pad
/// down from start to end (echoes ring out after).
Map<String, dynamic> _cue(double start, double end, BeatFx kind, double beats, double depth) =>
    {'start': start, 'end': end, 'kind': kind.index, 'beats': beats, 'depth': depth};

/// Mashup sets. Moves go where only beats are playing or a line has just
/// finished:
///  - echo out: the last beat of a vocal echoes away (3/4 beat)
///  - roll build: the new beat loops 1/2 then 1/4 beat in the bar before its
///    singer comes in, letting go two beats early so pickup notes stay clean
///  - spiral out: like the echo out, each repeat a semitone higher
List<Map<String, dynamic>> mashupFx(List<Mashup> ms) {
  final cues = <Map<String, dynamic>>[];
  for (var i = 1; i < ms.length; i++) {
    final m = ms[i], prev = ms[i - 1];
    final bt = m.beatTimes;
    // The beat the singer comes in on (bar 8 of a blend, later in an
    // anchored set).
    final vi = bt.indexWhere((t) => t >= m.vocalIn - 0.02);
    if (bt.length < 40 || vi < 8) continue;
    final beat = (bt[vi] - bt[vi - 4]) / 4;
    // An acapella drop already has its own moment.
    if (m.acapellaBars > 0) continue;
    switch (i % 3) {
      case 1:
        if (!prev.beatOnly) cues.add(_cue(prev.vocalOut - beat, prev.vocalOut, BeatFx.echo, 0.75, 0.45));
      case 2:
        if (!m.beatOnly) {
          cues.add(_cue(bt[vi - 6], bt[vi - 4], BeatFx.roll, 0.5, 0.6));
          cues.add(_cue(bt[vi - 4], bt[vi - 2], BeatFx.roll, 0.25, 0.6));
        }
      default:
        if (!prev.beatOnly) cues.add(_cue(prev.vocalOut - beat, prev.vocalOut, BeatFx.spiral, 1, 0.35));
    }
  }
  return cues;
}

/// Blend mixes, by transition type (echo outs and stem blends already throw
/// their own echo, so they're left alone):
///  - drop swap: a roll build into the downbeat where the songs swap
///  - filter sweep: a 1/2-beat echo on the last beat of the outgoing song
///  - bass swap: a slow flanger through the middle of the long blend
/// Every third changeover is left clean.
List<Map<String, dynamic>> blendFx(MixPlan plan) {
  final cues = <Map<String, dynamic>>[];
  for (var i = 0; i < plan.transitions.length; i++) {
    if (i % 3 == 2) continue;
    final x = plan.transitions[i];
    final beat = (x.end - x.start) / (x.bars * 4);
    if (beat <= 0.2 || beat > 2) continue;
    switch (x.type) {
      case TransitionType.dropSwap:
        cues.add(_cue(x.end - 4 * beat, x.end - 2 * beat, BeatFx.roll, 0.5, 0.55));
        cues.add(_cue(x.end - 2 * beat, x.end, BeatFx.roll, 0.25, 0.55));
      case TransitionType.filterSweep:
        cues.add(_cue(x.end - beat, x.end, BeatFx.echo, 0.5, 0.4));
      case TransitionType.bassSwap:
        if (x.bars >= 16) cues.add(_cue(x.start + 16 * beat, x.start + 48 * beat, BeatFx.flanger, 16, 0.35));
      default:
        break;
    }
  }
  return cues;
}
