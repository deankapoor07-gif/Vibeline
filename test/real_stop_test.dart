// Background analysis stops as soon as it's told to, leaving nothing running.
// $VIBELINE_LIST is a JSON list of paths the analyser hasn't seen.
// Skipped unless VIBELINE_REAL=1.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('stopping background analysis', () async {
    final paths = (jsonDecode(File(Platform.environment['VIBELINE_LIST']!).readAsStringSync()) as List).cast<String>();
    final songs = [for (final p in paths) LibraryTrack(path: p, title: p, artist: '', genre: '', year: 0, duration: 200)];
    MusicLibrary.maxArgBytes = 1;
    var last = 0;
    await MusicLibrary().analyze(songs, (d, t) => last = d, gentle: true, stop: () => last >= 2);
    print('stopped after $last of ${songs.length}');
    expect(last, lessThan(songs.length));
    expect(Directory.systemTemp.listSync().where((e) => e.path.contains('noodles-list-')), isEmpty);
  }, skip: Platform.environment['VIBELINE_REAL'] != '1', timeout: const Timeout(Duration(minutes: 5)));
}
