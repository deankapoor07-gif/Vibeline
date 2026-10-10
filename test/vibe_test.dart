import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/vibe.dart';

void main() {
  test('vocals over beats', () {
    final v = parseVibe('country vocals over hip hop beats, party');
    expect(v.vocalFamily, 'country');
    expect(v.beatFamily, 'hiphop');
    final w = parseVibe('80s pop singing over a house groove');
    expect(w.vocalFamily, 'pop');
    expect(w.beatFamily, 'dance');
  });
  test('warmth follows the vibe', () {
    expect(parseVibe('cafe chill').crackle, 0.7);
    expect(parseVibe('rave all night').crackle, 0.1);
    expect(parseVibe('aussie rock crowd').drive, closeTo(1.4, 1e-9));
  });
  test('words match whole words only', () {
    expect(parseVibe('sunday brunch').targetBpm, 120); // not "run" = workout
  });
}

