import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/mashup.dart';
import 'package:vibeline/models.dart';
import 'package:vibeline/vibe.dart';

void main() {
  LibraryTrack song(String genre) => LibraryTrack(path: '/\$genre.mp3', title: genre, artist: '', genre: genre, year: 0, duration: 200);

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

  test('a set still finishes when only jumps are left, as the last choice', () {
    final jump = MashupMaker.moveCost(song('Reggae'), song('Dance'), loose: true)!;
    final related = MashupMaker.moveCost(song('Reggae'), song('Pop'), loose: true)!;
    expect(jump, greaterThan(related));
  });
}
