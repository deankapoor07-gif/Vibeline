import 'dart:math' as math;

/// Concert-pitch reference for everything Vibeline plays. Dean's default is
/// A = 432 Hz: every recording is retuned from wherever it sits (measured per
/// song, usually within a few cents of 440) to 432. With [use432] off, songs
/// keep their own tuning and only vocals are nudged to match their beat.
class Tuning {
  static bool use432 = true;
  static const reference = 432.0;

  static double cents(double fromHz, double toHz) => 1200 * math.log(toHz / fromHz) / math.ln2;

  static double _wrap(double c) {
    while (c > 50) {
      c -= 100;
    }
    while (c < -50) {
      c += 100;
    }
    return c;
  }

  /// How sharp (+) or flat (−) a recording sits against the nearest note of
  /// standard 440 Hz tuning, in cents (−50…+50). Songs are labelled with the
  /// nearest key, so tuning is always measured from the nearest note.
  static double offset440(double hz) => _wrap(cents(440, hz));

  /// Cents that move a recording at [hz] onto the reference (0 if unknown).
  /// Always within about −82…+18 cents, so the key never changes.
  static double toReference(double? hz) =>
      (!use432 || hz == null || hz <= 0) ? 0 : cents(440, reference) - offset440(hz);

  /// Cents for a vocal at [vocalHz] so it sits in tune with a beat at [beatHz]
  /// (after the beat itself has been retuned).
  static double vocalCents(double? vocalHz, double? beatHz) {
    if (use432) return toReference(vocalHz);
    if (vocalHz == null || beatHz == null || vocalHz <= 0 || beatHz <= 0) return 0;
    return _wrap(cents(vocalHz, beatHz));
  }
}
