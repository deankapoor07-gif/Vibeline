import 'package:flutter/material.dart';

import 'deck_view.dart';

/// The kinds of file the app keeps, in the order they're shown.
enum StoreKind {
  songs('Split songs', 'Each song split into vocals and music. If removed, the song is split again the next time it\'s used (about 20 seconds).'),
  pieces('Set pieces', 'Ready-to-play parts of the sets you\'ve made. If removed, they\'re rebuilt whenever a set needs them.'),
  stretched('Clean vocals and beats', 'Vocals and beats fitted to a set\'s tempo and key. If removed, they\'re made again when a set needs them.'),
  mixes('Saved mixes', 'The mixes you saved. These can\'t be remade exactly, so check before removing them.'),
  working('Old working files', 'Left over from earlier versions of the app. Nothing uses these now.');

  final String title, blurb;
  const StoreKind(this.title, this.blurb);
}

/// One thing the app stores: a split song's folder, or a file (with any
/// companion files in [paths]).
class StoredItem {
  final StoreKind kind;
  final String path, name;
  final int size;
  final DateTime added;
  final List<String> paths;
  StoredItem(this.kind, this.path, this.name, this.size, this.added, [List<String>? paths]) : paths = paths ?? [path];
}

class StorageReport {
  final List<StoredItem> items;
  final int freeBytes;
  StorageReport(this.items, this.freeBytes);
}

String sizeLabel(int bytes) {
  if (bytes >= 1e9) return '${(bytes / 1e9).toStringAsFixed(1)} GB';
  if (bytes >= 1e6) return '${(bytes / 1e6).round()} MB';
  return '${(bytes / 1e3).round()} KB';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String dateLabel(DateTime day, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final d = DateTime(day.year, day.month, day.day);
  if (d == today) return 'Today';
  if (d == DateTime(now.year, now.month, now.day - 1)) return 'Yesterday';
  return '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// Everything the app stores, by type and then date added. Nothing is removed
/// unless it's ticked here, and then it goes to the Trash. What the set you
/// have open is using stays locked.
class StoragePage extends StatefulWidget {
  final Future<StorageReport> Function() scan;
  /// Moves paths to the Trash; returns those it moved.
  final Future<List<String>> Function(List<String> paths) trash;
  final Set<String> locked;
  final bool canRemove;
  final void Function(List<String> removed) onRemoved;
  const StoragePage({
    super.key,
    required this.scan,
    required this.trash,
    required this.locked,
    required this.canRemove,
    required this.onRemoved,
  });

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  StorageReport? _report;
  StoreKind _kind = StoreKind.songs;
  final _picked = <String>{}; // StoredItem.path
  final _open = <DateTime>{};
  bool _moving = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await widget.scan();
    if (mounted) setState(() => _report = r);
  }

  bool _isLocked(StoredItem i) => i.paths.any(widget.locked.contains);
  List<StoredItem> _of(StoreKind k) => _report!.items.where((i) => i.kind == k).toList();
  int _size(Iterable<StoredItem> items) => items.fold(0, (a, i) => a + i.size);
  DateTime _day(StoredItem i) => DateTime(i.added.year, i.added.month, i.added.day);

  List<StoredItem> get _pickedItems => _report!.items.where((i) => _picked.contains(i.path)).toList();

  Future<void> _remove() async {
    final items = _pickedItems;
    final saved = items.where((i) => i.kind == StoreKind.mixes).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Move ${items.length} ${items.length == 1 ? 'item' : 'items'} to the Trash?'),
        content: Text('${sizeLabel(_size(items))} in all. '
            '${saved > 0 ? 'That includes $saved saved ${saved == 1 ? 'mix' : 'mixes'}, which can\'t be remade exactly. ' : ''}'
            'You can get them back from the Trash, and the space is freed when you empty it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Move to Trash')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _moving = true);
    final want = [for (final i in items) ...i.paths];
    final moved = await widget.trash(want);
    widget.onRemoved(moved);
    final r = await widget.scan();
    if (!mounted) return;
    setState(() {
      _report = r;
      _picked.clear();
      _moving = false;
      _note = moved.length == want.length
          ? 'Moved to the Trash. Empty the Trash to free the space.'
          : 'Moved what it could; ${want.length - moved.length} couldn\'t be moved.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return Scaffold(
      backgroundColor: kInk,
      appBar: AppBar(
        backgroundColor: kInk,
        surfaceTintColor: Colors.transparent,
        title: const Text('Storage', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        actions: [
          if (r != null)
            Padding(
              padding: const EdgeInsets.only(right: 20),
              child: Center(
                child: Text('${sizeLabel(_size(r.items))} used by the app · ${sizeLabel(r.freeBytes)} free on this Mac',
                    style: const TextStyle(color: Colors.white70, fontSize: 13)),
              ),
            ),
        ],
      ),
      body: r == null
          ? const Center(child: CircularProgressIndicator(color: kPink))
          : Column(children: [
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SizedBox(width: 250, child: _kinds()),
                  const VerticalDivider(width: 1, color: kLine),
                  Expanded(child: _list()),
                ]),
              ),
              _bar(),
            ]),
    );
  }

  Widget _kinds() => ListView(padding: const EdgeInsets.all(10), children: [
        for (final k in StoreKind.values)
          Builder(builder: (_) {
            final items = _of(k);
            final on = k == _kind;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Material(
                color: on ? kPanel : Colors.transparent,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8), side: BorderSide(color: on ? kPink : Colors.transparent)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _kind = k),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(k.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text('${sizeLabel(_size(items))} · ${items.length}',
                          style: const TextStyle(color: Colors.white60, fontSize: 12)),
                    ]),
                  ),
                ),
              ),
            );
          }),
      ]);

  /// Newest first; each date folds open to show what was added that day.
  Widget _list() {
    final items = _of(_kind)..sort((a, b) => b.added.compareTo(a.added));
    final byDay = <DateTime, List<StoredItem>>{};
    for (final i in items) {
      byDay.putIfAbsent(_day(i), () => []).add(i);
    }
    final rows = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Text(_kind.blurb, style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ),
      if (items.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Nothing here.', style: TextStyle(color: Colors.white60)),
        ),
    ];
    for (final e in byDay.entries) {
      rows.add(_dayRow(e.key, e.value));
      if (_open.contains(e.key)) rows.addAll(e.value.map(_itemRow));
    }
    return ListView(children: rows);
  }

  Widget _dayRow(DateTime day, List<StoredItem> items) {
    final free = items.where((i) => !_isLocked(i)).toList();
    final all = free.isNotEmpty && free.every((i) => _picked.contains(i.path));
    final some = free.any((i) => _picked.contains(i.path));
    final open = _open.contains(day);
    return InkWell(
      onTap: () => setState(() => open ? _open.remove(day) : _open.add(day)),
      child: Container(
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: kLine))),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(children: [
          Checkbox(
            tristate: true,
            value: all ? true : (some ? null : false),
            activeColor: kPink,
            onChanged: free.isEmpty || !widget.canRemove
                ? null
                : (_) => setState(() {
                      if (all) {
                        _picked.removeAll(free.map((i) => i.path));
                      } else {
                        _picked.addAll(free.map((i) => i.path));
                      }
                    }),
          ),
          Expanded(child: Text(dateLabel(day, DateTime.now()), style: const TextStyle(fontWeight: FontWeight.w600))),
          Text('${items.length} · ${sizeLabel(_size(items))}', style: const TextStyle(color: Colors.white60, fontSize: 12)),
          Icon(open ? Icons.expand_less : Icons.expand_more, color: Colors.white54),
        ]),
      ),
    );
  }

  Widget _itemRow(StoredItem i) {
    final locked = _isLocked(i);
    return Padding(
      padding: const EdgeInsets.only(left: 28, right: 32),
      child: Row(children: [
        Checkbox(
          value: _picked.contains(i.path),
          activeColor: kPink,
          onChanged: locked || !widget.canRemove
              ? null
              : (v) => setState(() => v == true ? _picked.add(i.path) : _picked.remove(i.path)),
        ),
        Expanded(child: Text(i.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
        if (locked)
          const Padding(
            padding: EdgeInsets.only(right: 10),
            child: Text('in your open set', style: TextStyle(color: kTeal, fontSize: 12)),
          ),
        Text(sizeLabel(i.size), style: const TextStyle(color: Colors.white60, fontSize: 12)),
      ]),
    );
  }

  Widget _bar() {
    final picked = _pickedItems;
    final message = !widget.canRemove
        ? 'You can remove things once your set has finished being made.'
        : picked.isEmpty
            ? (_note ?? 'Nothing is removed unless you tick it. What your open set is using stays locked.')
            : '${picked.length} ticked · ${sizeLabel(_size(picked))}';
    return Container(
      decoration: const BoxDecoration(color: kPanel, border: Border(top: BorderSide(color: kLine))),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        Expanded(child: Text(message, style: const TextStyle(color: Colors.white70, fontSize: 13))),
        if (_moving)
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: kPink))
        else
          FilledButton.icon(
            onPressed: picked.isEmpty ? null : _remove,
            style: FilledButton.styleFrom(backgroundColor: kPink, foregroundColor: kInk),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Move to Trash'),
          ),
      ]),
    );
  }
}
