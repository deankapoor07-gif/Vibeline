import 'package:flutter/material.dart';

const mashupExamples = ['Party, mix genres, my Shazams', 'Country vocals over hip hop', 'Festival, 4 hours'];
const blendExamples = ['Party, mix genres, modern, my Shazams', 'Cafe chill, 80s'];

/// What's on the main screen before there's a set: the next step, in everyday
/// words.
class EmptyScreen extends StatelessWidget {
  final bool busy;
  final bool mashup;
  final bool scanned;
  final bool problem;
  final int songCount;
  final String goLabel;
  final Color accent;
  final void Function(String example) onExample;
  final VoidCallback onChooseFolder;
  final VoidCallback onWholeMac;

  const EmptyScreen({
    super.key,
    required this.busy,
    required this.mashup,
    required this.scanned,
    required this.problem,
    required this.songCount,
    required this.goLabel,
    required this.accent,
    required this.onExample,
    required this.onChooseFolder,
    required this.onWholeMac,
  });

  static const _body = TextStyle(fontSize: 14, color: Colors.white70, height: 1.4);

  Widget _page(String title, List<Widget> rest) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title.toUpperCase(), textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, letterSpacing: 2, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                ...rest,
              ],
            ),
          ),
        ),
      );

  Widget _text(String s) => Text(s, textAlign: TextAlign.center, style: _body);

  @override
  Widget build(BuildContext context) {
    if (!scanned) {
      return problem
          ? _page('One thing to fix first', [_text('The message just above says what the app needs.')])
          : _page('Looking for your music…', [_text('This can take a while the first time.')]);
    }
    if (busy) {
      return _page(mashup ? 'Building your set…' : 'Building your mix…', [
        _text(mashup
            ? 'The music starts as soon as the first part is ready, and the rest keeps being made while it plays.'
            : 'The progress is just above.'),
      ]);
    }
    if (songCount == 0) {
      return _page('No songs found', [
        _text('Point the app at your music. If it\'s on a separate drive, check the drive is plugged in.'),
        const SizedBox(height: 16),
        Wrap(alignment: WrapAlignment.center, spacing: 10, runSpacing: 10, children: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.black),
            onPressed: onChooseFolder,
            child: const Text('Choose a folder'),
          ),
          OutlinedButton(onPressed: onWholeMac, child: const Text('Search the whole Mac')),
        ]),
      ]);
    }
    return _page('No set loaded', [
      _text('Press $goLabel to build one from your library.'),
      const SizedBox(height: 16),
      _text('Or start from:'),
      const SizedBox(height: 8),
      Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
        for (final e in mashup ? mashupExamples : blendExamples)
          ActionChip(
            label: Text(e, style: const TextStyle(fontSize: 13, color: Colors.white)),
            side: const BorderSide(color: Colors.white24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
            backgroundColor: const Color(0xFF1A1A22),
            onPressed: () => onExample(e),
          ),
      ]),
      const SizedBox(height: 18),
      Text(
        mashup
            ? 'First set can take several minutes while your songs are analysed and their vocals and beats separated. Known songs load much quicker.'
            : 'First set can take a few minutes while your songs are analysed. Known songs load much quicker.',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, color: Colors.white60, height: 1.4),
      ),
    ]);
  }
}
