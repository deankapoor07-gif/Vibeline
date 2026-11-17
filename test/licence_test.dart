import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/licence.dart';

class MemTrial implements TrialStore {
  DateTime? v;
  MemTrial([this.v]);
  @override
  Future<DateTime?> read() async => v;
  @override
  Future<void> write(DateTime start) async => v = start;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('licence_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  final day0 = DateTime(2026, 11, 20, 10);

  Licence make({required DateTime Function() now, MemTrial? store, LicencePost? post}) =>
      Licence(dir: dir.path, now: now, trialStore: store ?? MemTrial(), post: post ?? (a, f) async => (500, <String, dynamic>{}));

  test('trial counts down 7 days, then ends', () async {
    var now = day0;
    final store = MemTrial();
    final l = make(now: () => now, store: store);
    await l.load();
    expect(l.state, LicenceState.trial);
    expect(l.trialDaysLeft, 7);
    expect(store.v, day0);
    now = day0.add(const Duration(days: 2, hours: 1));
    expect(l.trialDaysLeft, 5);
    now = day0.add(const Duration(days: 6, hours: 23));
    expect(l.trialDaysLeft, 1);
    now = day0.add(const Duration(days: 7));
    expect(l.state, LicenceState.expired);
  });

  test('deleting the licence file does not restart the trial', () async {
    var now = day0;
    final store = MemTrial();
    await make(now: () => now, store: store).load();
    File('${dir.path}/licence.json').deleteSync();
    now = day0.add(const Duration(days: 8));
    final again = make(now: () => now, store: store);
    await again.load();
    expect(again.state, LicenceState.expired);
  });

  test('clearing the keychain copy does not restart it either', () async {
    var now = day0;
    await make(now: () => now, store: MemTrial()).load();
    now = day0.add(const Duration(days: 8));
    final again = make(now: () => now, store: MemTrial());
    await again.load();
    expect(again.state, LicenceState.expired);
  });

  test('winding the clock back does not add days', () async {
    var now = day0;
    final store = MemTrial();
    await make(now: () => now, store: store).load();
    now = day0.add(const Duration(days: 6));
    await make(now: () => now, store: store).load();
    now = day0;
    final again = make(now: () => now, store: store);
    await again.load();
    expect(again.trialDaysLeft, 1);
  });

  test('a good key activates, survives restart, and works offline', () async {
    var now = day0.add(const Duration(days: 30));
    final calls = <String>[];
    final l = make(
        now: () => now,
        store: MemTrial(day0),
        post: (a, f) async {
          calls.add(a);
          expect(f['license_key'], 'ABCD-1234-EFGH-5678');
          return (200, <String, dynamic>{
            'activated': true,
            'instance': {'id': 'inst-1'},
            'meta': {'store_id': kLemonStoreId ?? 1, 'product_id': kLemonProductId ?? 2},
          });
        });
    await l.load();
    expect(l.state, LicenceState.expired);
    final r = await l.activate('  ABCD-1234-EFGH-5678 ');
    expect(r.ok, isTrue);
    expect(l.state, LicenceState.licensed);
    expect(l.maskedKey, '••••-••••-••••-5678');

    // Restart with no network at all, long after the last check.
    now = now.add(const Duration(days: 90));
    final offline = make(now: () => now, post: (a, f) async => throw const SocketException('offline'));
    await offline.load();
    await offline.recheck();
    expect(offline.state, LicenceState.licensed);
  });

  test('a refunded key stops working on the next check', () async {
    var now = day0;
    final l = make(
        now: () => now,
        post: (a, f) async => a == 'activate'
            ? (200, <String, dynamic>{'activated': true, 'instance': {'id': 'i'}, 'meta': {'store_id': kLemonStoreId ?? 1, 'product_id': kLemonProductId ?? 2}})
            : (200, <String, dynamic>{'valid': false, 'license_key': {'status': 'disabled'}}));
    await l.load();
    await l.activate('KEY-1');
    now = now.add(const Duration(days: 15));
    await l.recheck();
    expect(l.licensed, isFalse);
  });

  test('a recheck too soon makes no call', () async {
    var calls = 0;
    final l = make(
        now: () => day0,
        post: (a, f) async {
          calls++;
          return (200, <String, dynamic>{'activated': true, 'instance': {'id': 'i'}, 'meta': {'store_id': kLemonStoreId ?? 1, 'product_id': kLemonProductId ?? 2}});
        });
    await l.load();
    await l.activate('KEY-1');
    await l.recheck();
    expect(calls, 1);
  });

  test('plain-English errors', () async {
    final l = make(
        now: () => day0,
        post: (a, f) async => f['license_key'] == 'FULL'
            ? (400, <String, dynamic>{'activated': false, 'error': 'This license key has reached the activation limit.'})
            : (404, <String, dynamic>{'activated': false, 'error': 'license_key not found.'}));
    await l.load();
    expect((await l.activate('')).message, contains('Paste'));
    expect((await l.activate('FULL')).message, contains('3 Macs'));
    expect((await l.activate('NOPE')).message, contains("wasn't recognised"));
    expect(l.licensed, isFalse);
    final offline = make(now: () => day0, post: (a, f) async => throw const SocketException('x'));
    await offline.load();
    expect((await offline.activate('K')).message, contains('online'));
  });

  test('moving the licence off this Mac', () async {
    final seen = <String>[];
    final l = make(
        now: () => day0,
        post: (a, f) async {
          seen.add(a);
          return a == 'activate'
              ? (200, <String, dynamic>{'activated': true, 'instance': {'id': 'i'}, 'meta': {'store_id': kLemonStoreId ?? 1, 'product_id': kLemonProductId ?? 2}})
              : (200, <String, dynamic>{'deactivated': true});
        });
    await l.load();
    await l.activate('KEY-1');
    expect((await l.deactivate()).ok, isTrue);
    expect(l.licensed, isFalse);
    expect(seen, ['activate', 'deactivate']);
  });

  test('a key from another store is refused and released', () async {
    final seen = <String>[];
    final l = make(
        now: () => day0,
        post: (a, f) async {
          seen.add(a);
          return (200, <String, dynamic>{'activated': true, 'instance': {'id': 'i'}, 'meta': {'store_id': -5, 'product_id': -6}});
        });
    await l.load();
    final r = await l.activate('OTHER');
    if (kLemonStoreId == null) return; // can't tell stores apart until the ids are set
    expect(r.ok, isFalse);
    expect(seen, ['activate', 'deactivate']);
  });

  test('release: our Lemon Squeezy store and product are set', () {
    expect(kLemonStoreId, isNotNull, reason: 'Set kLemonStoreId in lib/licence.dart');
    expect(kLemonProductId, isNotNull, reason: 'Set kLemonProductId in lib/licence.dart');
  }, skip: Platform.environment['VIBELINE_RELEASE'] != '1');
}
