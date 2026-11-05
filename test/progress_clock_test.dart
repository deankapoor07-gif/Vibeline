import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';

void main() {
  late DateTime t;
  late ProgressClock clock;
  setUp(() {
    t = DateTime(2026);
    clock = ProgressClock(now: () => t);
  });

  String run(int fromDone, int songs, int total, Duration each) {
    var out = '';
    for (var i = 1; i <= songs; i++) {
      t = t.add(each);
      out = clock.tick(fromDone + i, total);
    }
    return out;
  }

  test('says nothing until it has seen enough songs', () {
    expect(run(0, 5, 100, const Duration(seconds: 2)), '');
  });

  test('songs already analysed do not make the estimate too short', () {
    run(0, 1300, 2000, const Duration(milliseconds: 2)); // instant
    expect(run(1300, 20, 2000, const Duration(seconds: 1)), ' · about 12 min left');
  });

  test('longer waits read in hours', () {
    expect(run(0, 10, 2010, const Duration(seconds: 3)), ' · about 1 hr 40 min left');
  });

  test('close to the end', () {
    expect(run(0, 10, 15, const Duration(seconds: 2)), ' · under a minute left');
  });

  test('nothing once every song is done', () {
    expect(run(0, 10, 10, const Duration(seconds: 2)), '');
  });
}
