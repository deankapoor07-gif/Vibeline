import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/mashup.dart';
import 'package:vibeline/models.dart';
import 'package:vibeline/vibe.dart';

void main() {
  LibraryTrack song(String genre) => LibraryTrack(path: '/\$genre.mp3', title: genre, artist: '', genre: genre, year: 0, duration: 200);

  test('a song in 3 is never mixed; an unclear one only as a last choice', () {
    LibraryTrack beats(int? n) => song('Pop')..barBeats = n;
    expect(MashupMaker.meterOk(beats(4)), isTrue);
    expect(MashupMaker.meterOk(beats(null)), isTrue, reason: 'not measured yet: checked before splitting');
    expect(MashupMaker.meterOk(beats(3)), isFalse);
    expect(MashupMaker.meterOk(beats(3), loose: true), isFalse, reason: 'running short never lets a waltz in');
    expect(MashupMaker.meterOk(beats(0)), isFalse);
    expect(MashupMaker.meterOk(beats(0), loose: true), isTrue);
  });

  test('styles a set can move between', () {
    expect(feelGap('Reggae', 'Reggae'), 0);
    expect(feelGap('Reggae', 'R&B/Soul'), 1, reason: 'reggae can move to soul');
    expect(feelGap('Disco', 'House'), 0, reason: 'disco and house are one family');
    expect(feelGap('Reggae', 'Dance'), 2, reason: 'relaxed reggae straight into fast dance');
    expect(feelGap('Reggae', 'Hard Rock'), 2);
    expect(feelGap('Dance', 'Reggae'), 2, reason: 'the same in either direction');
    expect(feelGap('', 'Reggae'), 1, reason: 'no useful tag: it cannot be judged');
    expect(feelGap('', ''), 1);
  });

  test('a jump in mood is ruled out while anything connected is left', () {
    expect(MashupMaker.moveCost(song('Reggae'), song('Dance')), isNull);
    expect(MashupMaker.moveCost(song('Reggae'), song('Reggae')), 0);
    expect(MashupMaker.moveCost(null, song('Dance')), 0, reason: 'nothing before it');
  });

  test('a vocal and beat that suit each other score higher than a clash of styles', () {
    final suits = MashupMaker.pairFeel('R&B/Soul', 'R&B/Soul', 0.5, 0.5);
    final related = MashupMaker.pairFeel('R&B/Soul', 'Pop', 0.5, 0.5);
    final clash = MashupMaker.pairFeel('Reggae', 'Hard Rock', 0.5, 0.5);
    expect(suits, greaterThan(related));
    expect(related, greaterThan(clash));
  });

  test('a big gap in energy counts against a pair even in matching styles', () {
    expect(MashupMaker.pairFeel('Pop', 'Pop', 0.2, 0.9), lessThan(MashupMaker.pairFeel('Pop', 'Pop', 0.5, 0.5)));
  });

  test('a beat with strong drums and bass and little singing leaves the most room', () {
    final plain = MashupMaker.beatBusyCost(drums: 2, bass: 2, vocalShare: 0.2);
    final melodic = MashupMaker.beatBusyCost(drums: -8, bass: -8, vocalShare: 0.2);
    final sung = MashupMaker.beatBusyCost(drums: 2, bass: 2, vocalShare: 0.45);
    expect(plain, 0);
    expect(melodic, greaterThan(plain));
    expect(sung, greaterThan(plain));
    expect(MashupMaker.beatBusyCost(), 0, reason: 'not split yet: nothing to go on');
  });

  test('a set still finishes when only jumps are left, as the last choice', () {
    final jump = MashupMaker.moveCost(song('Reggae'), song('Dance'), loose: true)!;
    final related = MashupMaker.moveCost(song('Reggae'), song('Pop'), loose: true)!;
    expect(jump, greaterThan(related));
  });
}
