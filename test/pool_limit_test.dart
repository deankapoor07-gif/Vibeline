import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/models.dart';

LibraryTrack song(String path, {bool shazam = false}) =>
    LibraryTrack(path: path, title: path, artist: '', genre: '', year: 0, duration: 200)..shazam = shazam;

List<LibraryTrack> drive(int n) => [for (var i = 0; i < n; i++) song('/Volumes/SPARE DRIVE/$i.mp3')];
List<LibraryTrack> mac(int n) => [for (var i = 0; i < n; i++) song('/Users/dean/Music/$i.mp3')];

void main() {
  test('a pool that already fits is left alone', () {
    final pool = [...drive(300), ...mac(50)];
    expect(MusicLibrary.limitPool(pool), same(pool));
  });

  test('every song on the Mac stays, with some from the drive', () {
    final out = MusicLibrary.limitPool([...drive(19727), ...mac(1695)]);
    expect(out.length, 1795);
    expect(out.where((t) => t.path.startsWith('/Users/')).length, 1695);
    expect(out.where((t) => t.path.startsWith('/Volumes/')).length, 100);
  });

  test('Shazamed songs on the drive come before other drive songs', () {
    final liked = [for (var i = 0; i < 500; i++) song('/Volumes/SPARE DRIVE/liked$i.mp3', shazam: true)];
    final out = MusicLibrary.limitPool([...drive(5000), ...liked, ...mac(100)]);
    expect(out.length, 700);
    expect(out.where((t) => t.shazam).length, 500);
    expect(out.where((t) => t.path.startsWith('/Users/')).length, 100);
  });

  test('a library only on the drive still gets a full pool', () {
    expect(MusicLibrary.limitPool(drive(20000)).length, 400);
  });

  test('never more than the most a set will listen to', () {
    expect(MusicLibrary.limitPool([...mac(5000), ...drive(5000)]).length, MusicLibrary.maxPoolSongs);
  });

  test('keeps the ranked order within each group', () {
    final d = drive(1000);
    final out = MusicLibrary.limitPool([...d, ...mac(10)]);
    expect(out.skip(10).take(5).map((t) => t.path), d.take(5).map((t) => t.path));
  });
}
