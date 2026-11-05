import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/library_panel.dart';
import 'package:vibeline/models.dart';

Analysis grid(double bpm, String camelot) => Analysis.fromJson({
      'bpm': bpm,
      'beats': [for (var i = 0; i < 80; i++) i * 60 / bpm],
      'barPhase': 0,
      'barEnergy': [for (var i = 0; i < 20; i++) 0.8],
      'firstBar': 0,
      'lastBar': 19,
      'camelot': camelot,
      'key': 'A minor',
    });

LibraryTrack song(String name, {bool known = false, String genre = '', double bpm = 120, String camelot = '8A'}) {
  final t = LibraryTrack(path: '/Users/d/$name.mp3', title: name, artist: '', genre: genre, year: 0, duration: 200);
  if (known) t.analysis = grid(bpm, camelot);
  return t;
}

void main() {
  test('enough known songs: nothing to wait for', () {
    final pool = [for (var i = 0; i < 300; i++) song('k$i', known: true), for (var i = 0; i < 300; i++) song('n$i')];
    expect(MusicLibrary.songsToAnalyseFirst(pool, minReady: 240), isEmpty);
  });

  test('a new customer waits for just enough songs, best ranked first', () {
    final pool = [for (var i = 0; i < 2000; i++) song('n$i')];
    final first = MusicLibrary.songsToAnalyseFirst(pool, minReady: 240);
    expect(first.length, 240);
    expect(first.first.title, 'n0');
  });

  test('tops up only what is missing', () {
    final pool = [for (var i = 0; i < 200; i++) song('k$i', known: true), for (var i = 0; i < 100; i++) song('n$i')];
    expect(MusicLibrary.songsToAnalyseFirst(pool, minReady: 240).length, 40);
  });

  test('asking for a genre the known songs lack waits for that genre', () {
    final pool = [
      for (var i = 0; i < 300; i++) song('pop$i', known: true, genre: 'pop'),
      for (var i = 0; i < 50; i++) song('new pop$i', genre: 'pop'),
      for (var i = 0; i < 50; i++) song('country$i', genre: 'country'),
    ];
    final first = MusicLibrary.songsToAnalyseFirst(pool, minReady: 240, matchMin: 20, matches: (t) => t.genre == 'country');
    expect(first.length, 20);
    expect(first.every((t) => t.genre == 'country'), isTrue);
  });

  test('songs that already failed are not tried again', () {
    final failed = song('bad')..analysisTried = true;
    expect(MusicLibrary.songsToAnalyseFirst([failed], minReady: 10), isEmpty);
  });

  group('sorting the Songs panel', () {
    final rows = [
      song('none'),
      song('fast', known: true, bpm: 140, camelot: '2A'),
      song('slow', known: true, bpm: 90, camelot: '11B'),
      song('mid', known: true, bpm: 120, camelot: '2B'),
    ];
    List<String> sorted(SongSort s) => (rows.toList()..let(s)).map((t) => t.title).toList();

    test('by BPM, slowest first, unknown last', () {
      expect(sorted(SongSort.bpm), ['slow', 'mid', 'fast', 'none']);
    });
    test('by key, in wheel order, unknown last', () {
      expect(sorted(SongSort.key), ['fast', 'mid', 'slow', 'none']);
    });
    test('A to Z', () {
      expect(sorted(SongSort.title), ['fast', 'mid', 'none', 'slow']);
    });
  });
}

extension on List<LibraryTrack> {
  void let(SongSort s) => sortSongs(this, s);
}
