// Runs every clip of a saved set plan ($VIBELINE_PLAN_IN) through the
// Prestretcher and writes the swapped plan to $VIBELINE_PLAN_OUT.
// Skipped unless VIBELINE_REAL=1.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/prestretch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('prestretch a set', () async {
    final env = Platform.environment;
    final plan = jsonDecode(File(env['VIBELINE_PLAN_IN']!).readAsStringSync()) as Map<String, dynamic>;
    final pre = Prestretcher(MusicLibrary()..useMusicApp = false);
    final sw = Stopwatch()..start();
    var json = pre.apply(plan);
    while (pre.busy) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    json = pre.apply(plan);
    final clips = (json['clips'] as List).cast<Map<String, dynamic>>();
    print('swapped ${clips.where((c) => (c['path'] as String).contains('/prestretch/')).length} of ${clips.where((c) => c['warp'] != null || (c['path'] as String).contains('/prestretch/')).length} warped clips in ${sw.elapsed.inSeconds}s');
    File(env['VIBELINE_PLAN_OUT']!).writeAsStringSync(jsonEncode(json));
  }, skip: Platform.environment['VIBELINE_REAL'] != '1', timeout: const Timeout(Duration(minutes: 60)));
}
