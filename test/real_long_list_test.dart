// Sends a real list of songs to the analyser through the "long list" file,
// with one song that isn't there. $VIBELINE_LIST is a JSON list of paths.
// Skipped unless VIBELINE_REAL=1.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('long song list goes through a file', () async {
    final env = Platform.environment;
    final paths = (jsonDecode(File(env['VIBELINE_LIST']!).readAsStringSync()) as List).cast<String>();
    const missing = '/Volumes/Unplugged Drive/gone.mp3';
    final songs = [
      for (final p in [...paths, missing]) LibraryTrack(path: p, title: p, artist: '', genre: '', year: 0, duration: 200),
    ];
    MusicLibrary.maxArgBytes = 1000; // real lists pass this in the app
    var last = 0;
    await MusicLibrary().analyze(songs, (d, t) => last = d);
    expect(last, songs.length);
    expect(songs.where((s) => s.analysis != null).length, greaterThan(paths.length * 0.9));
    expect(songs.last.analysis, isNull);
    expect(songs.last.analysisTried, isTrue);
    final left = Directory.systemTemp.listSync().where((e) => e.path.contains('noodles-list-'));
    expect(left, isEmpty);
    print('${songs.length} songs, ${songs.where((s) => s.analysis != null).length} analysed');
  }, skip: Platform.environment['VIBELINE_REAL'] != '1', timeout: const Timeout(Duration(minutes: 10)));
}
