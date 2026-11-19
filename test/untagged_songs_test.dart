import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/models.dart';
import 'package:vibeline/recent_sets.dart';
import 'package:vibeline/vibe.dart';

LibraryTrack song(String path, {String title = '', String artist = '', String genre = ''}) =>
    LibraryTrack.fromJson({'path': path, 'title': title, 'artist': artist, 'genre': genre});

void main() {
  test('songs with no artist are not "the same artist"', () {
    expect(song('/a.m4a').sameArtist(song('/b.m4a')), isFalse);
    expect(song('/a', artist: 'Prince').sameArtist(song('/b', artist: 'prince ')), isTrue);
    expect(song('/a', artist: 'Prince').sameArtist(song('/b', artist: 'Madonna')), isFalse);
  });

  test('untagged songs get a genre from their folder and title', () {
    expect(song('/Users/x/Music/Demo/Reggae/Rise Up.m4a', title: 'Rise Up').genre, 'Reggae');
    expect(song('/Users/x/Music/Demo/Christmas/Soulfire Noel.m4a', title: 'Soulfire Noel').genre, 'Christmas, Soul');
    expect(song('/Users/x/Music/Mix/Track 1.mp3', title: 'Track 1').genre, '');
    expect(song('/x/Reggae/Song.mp3', title: 'Song', genre: 'Pop').genre, 'Pop'); // a real tag wins
    expect(song('/x/Drapery/Song.mp3', title: 'Song').genre, ''); // "rap" only as a whole word start
  });

  test('"reggae and soul" means either', () {
    final v = parseTheme('Summer Christmas, reggae and soul', '');
    expect(v.sings(song('/x/Reggae/Rise Up.m4a', title: 'Rise Up')), isTrue);
    expect(v.sings(song('/x/Smooth/Soulfire Unity.m4a', title: 'Soulfire Unity')), isTrue);
    expect(v.sings(song('/x/Rock/Loud.m4a', title: 'Loud')), isFalse);
  });

  test('recent sets hold pairings back, fading over time', () {
    final a = song('/a'), b = song('/b'), c = song('/c'), d = song('/d');
    final dir = Directory.systemTemp.createTempSync('recent');
    RecentSets.load(dir: dir.path);
    expect(RecentSets.penalty(a, b), 0);
    RecentSets.record([(a, b)]);
    final fresh = RecentSets.penalty(a, b);
    expect(fresh, greaterThan(RecentSets.penalty(a, c)));
    expect(RecentSets.penalty(c, d), 0);
    for (var i = 0; i < 3; i++) {
      RecentSets.record([(c, d)]);
    }
    expect(RecentSets.penalty(a, b), lessThan(fresh));
    RecentSets.clearForTest();
    dir.deleteSync(recursive: true);
  });
}
