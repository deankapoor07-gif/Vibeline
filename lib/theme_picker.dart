import 'package:flutter/material.dart';

import 'rig.dart';

/// One click each, so nobody has to guess what the app understands. Anything
/// else can still be typed.
const themeChoices = ['80s', '90s', '2000s', 'Punk', "Rock 'n' roll", 'Halloween', 'Reggae', 'Kiwi', 'Latin', 'Afrobeats'];

const _typeOwn = '\u0000own';

/// Picks the theme of a set from a list, or in your own words. A theme decides
/// who sings; beats can still come from any song.
class ThemePicker extends StatelessWidget {
  final TextEditingController controller;
  final bool locked;
  final VoidCallback onChanged;

  const ThemePicker({super.key, required this.controller, required this.locked, required this.onChanged});

  Future<void> _typeYourOwn(BuildContext context) async {
    final result = await showDialog<String>(context: context, builder: (_) => _OwnThemeDialog(controller.text));
    if (result == null) return;
    controller.text = result.trim();
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = controller.text.trim();
    return PopupMenuButton<String>(
      enabled: !locked,
      tooltip: 'A theme decides who sings. Beats can still come from any song.',
      onSelected: (v) {
        if (v == _typeOwn) {
          _typeYourOwn(context);
          return;
        }
        controller.text = v;
        onChanged();
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: '', height: 32, child: Text('No theme', style: TextStyle(fontSize: 13))),
        for (final t in themeChoices) PopupMenuItem(value: t, height: 32, child: Text(t, style: const TextStyle(fontSize: 13))),
        const PopupMenuDivider(),
        const PopupMenuItem(value: _typeOwn, height: 32, child: Text('Type your own…', style: TextStyle(fontSize: 13))),
      ],
      child: Container(
        height: 32,
        constraints: const BoxConstraints(maxWidth: 190),
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: kRigFace,
          borderRadius: BorderRadius.circular(kRigCorner),
          border: Border.all(color: theme.isEmpty ? Colors.white12 : kRigAmber),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('THEME', style: TextStyle(fontSize: 10, letterSpacing: 1, fontWeight: FontWeight.w700, color: Colors.white54)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              theme.isEmpty ? 'NONE' : theme.toUpperCase(),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: theme.isEmpty ? Colors.white54 : Colors.white),
            ),
          ),
          const Icon(Icons.arrow_drop_down, size: 18, color: Colors.white54),
        ]),
      ),
    );
  }
}

class _OwnThemeDialog extends StatefulWidget {
  final String start;
  const _OwnThemeDialog(this.start);

  @override
  State<_OwnThemeDialog> createState() => _OwnThemeDialogState();
}

class _OwnThemeDialogState extends State<_OwnThemeDialog> {
  late final _typed = TextEditingController(text: widget.start);

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Your own theme', style: TextStyle(fontSize: 15)),
        content: TextField(
          controller: _typed,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'A genre or decade, e.g. soundtrack'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, _typed.text), child: const Text('Use theme')),
        ],
      );
}
