import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/storage_view.dart';

void main() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day, 9);
  final old = DateTime(2026, 3, 2, 9);
  List<StoredItem> items() => [
        StoredItem(StoreKind.songs, '/s/playing', 'Playing Song.mp3', 2000000, today),
        StoredItem(StoreKind.songs, '/s/spare', 'Spare Song.mp3', 3000000, today),
        StoredItem(StoreKind.songs, '/s/old', 'Old Song.mp3', 5000000, old),
        StoredItem(StoreKind.pieces, '/p/a.m4a', 'Set piece', 1000000, old, ['/p/a.m4a', '/p/a.m4a.vox.m4a']),
      ];

  Widget page(List<List<String>> trashed, {bool canRemove = true}) {
    var left = items();
    return MaterialApp(
      home: StoragePage(
        scan: () async => StorageReport(left, 18000000000),
        trash: (p) async {
          trashed.add(p);
          left = left.where((i) => !p.contains(i.path)).toList();
          return p;
        },
        locked: const {'/s/playing'},
        canRemove: canRemove,
        onRemoved: (_) {},
      ),
    );
  }

  testWidgets('groups by type and date, newest first, folded', (t) async {
    await t.pumpWidget(page([]));
    await t.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Mon 2 Mar 2026'), findsOneWidget);
    expect(t.getTopLeft(find.text('Today')).dy, lessThan(t.getTopLeft(find.text('Mon 2 Mar 2026')).dy));
    expect(find.text('Spare Song.mp3'), findsNothing);
    await t.tap(find.text('Today'));
    await t.pumpAndSettle();
    expect(find.text('Spare Song.mp3'), findsOneWidget);
    expect(find.text('in your open set'), findsOneWidget);
  });

  testWidgets('a date tick skips what the open set uses, and removal asks first', (t) async {
    final trashed = <List<String>>[];
    await t.pumpWidget(page(trashed));
    await t.pumpAndSettle();
    await t.tap(find.byType(Checkbox).first); // Today
    await t.pumpAndSettle();
    await t.tap(find.text('Move to Trash'));
    await t.pumpAndSettle();
    expect(trashed, isEmpty);
    await t.tap(find.text('Move to Trash').last);
    await t.pumpAndSettle();
    expect(trashed, [
      ['/s/spare']
    ]);
    expect(find.textContaining('Empty the Trash'), findsOneWidget);
  });

  testWidgets('a piece goes with its companion file', (t) async {
    final trashed = <List<String>>[];
    await t.pumpWidget(page(trashed));
    await t.pumpAndSettle();
    await t.tap(find.text('Set pieces'));
    await t.pumpAndSettle();
    await t.tap(find.byType(Checkbox).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Move to Trash'));
    await t.pumpAndSettle();
    await t.tap(find.text('Move to Trash').last);
    await t.pumpAndSettle();
    expect(trashed.single, ['/p/a.m4a', '/p/a.m4a.vox.m4a']);
  });

  testWidgets('nothing can be ticked while a set is being made', (t) async {
    await t.pumpWidget(page([], canRemove: false));
    await t.pumpAndSettle();
    expect(t.widget<Checkbox>(find.byType(Checkbox).first).onChanged, isNull);
  });
}
