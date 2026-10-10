import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/tuning.dart';

void main() {
  test('432 retune is measured from the nearest note', () {
    Tuning.use432 = true;
    expect(Tuning.toReference(440), closeTo(-31.77, 0.01));
    expect(Tuning.toReference(432), closeTo(0, 0.01));
    // 454 Hz is 45 cents flat of the next note, not 55 sharp of A.
    expect(Tuning.toReference(454.2), closeTo(-31.77 + 45.0, 0.5));
    for (final hz in [427.5, 435.0, 444.0, 452.0]) {
      expect(Tuning.toReference(hz), inInclusiveRange(-82, 19));
    }
  });
  test('original tuning keeps songs as they are', () {
    Tuning.use432 = false;
    expect(Tuning.toReference(444), 0);
    expect(Tuning.vocalCents(444, 436).abs(), lessThanOrEqualTo(50));
    Tuning.use432 = true;
  });
}
