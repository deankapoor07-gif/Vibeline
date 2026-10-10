# Vibeline

A mashup studio for macOS: type a vibe, and Vibeline builds a set of mashups —
the vocal from one song over the beat of another, across genres and eras —
beat-locked, key-matched, blended into each other, and played live with
instant pitch and volume control.

## What it does

- **Re-Mix AI** — reads your music folder (plus your own files in the Music
  app), favours your Shazams, pairs vocals with beats, splits stems (Demucs),
  matches key (±3 semitones) and tempo, and lays out a set. Long sets ("4 hours")
  build in the background while they play.
- **Mashup cards** — stem lanes with mute/solo, live vocal pitch (semitones +
  fine cents), live vocal/beat volume, tempo (with "Match vocal"), swap
  vocal↔beat, shuffle.
- **Songs panel** — your library ranked by fit; drag a song onto a card's 🎤 or
  🥁 line to replace the vocal or the beat.
- **Sample lane** — drop sounds, loops or acapellas over any mashup.
- **Blend Mode** — classic DJ set of whole songs (Mashup Mode off).
- **432 Hz** — everything retuned to A = 432 Hz by default (switchable).
- **Analog Warmth** — tape saturation and vinyl crackle, flavoured by the vibe.

## How it's built

| Part | Where |
| --- | --- |
| Screen (Flutter) | `lib/main.dart`, `lib/mashup_widgets.dart`, `lib/library_panel.dart` |
| Vibe parsing | `lib/vibe.dart` |
| Mashup engine (pairing, structure, layout, samples) | `lib/mashup.dart` |
| Blend-mode planner | `lib/planner.dart` |
| Sections (render only what changed) | `lib/sections.dart` |
| Tuning (432 Hz) | `lib/tuning.dart` |
| Music analysis + stem splitting (Python) | `assets/vibeline_ai.py` |
| Audio engine: offline renderer + live player (Swift) | `macos/Runner/MainFlutterWindow.swift` |

The analyser runs in its own Python environment at
`~/Library/Application Support/Vibeline/venv` (essentia, numpy, mutagen,
demucs, soundfile). Caches live in `~/Library/Caches/Vibeline`.

## Building

```bash
flutter build macos --release
```

`build/` is a symlink to `~/Library/Caches/Vibeline-build` (apps built inside an
iCloud-synced Documents folder fail code signing).

## Tests

`flutter test` runs the unit tests. Tests named `real_*` use the real music
library and are skipped unless `VIBELINE_REAL=1` is set.
