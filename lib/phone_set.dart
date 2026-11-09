import 'dart:convert';
import 'dart:io';

/// A set sent from the Mac to the iPhone through iCloud Drive: a folder in
/// iCloud Drive › D-Jay Noodles › Sets holding its sections as compressed
/// audio (the vocal layer apart, for the live faders) and this description
/// in set.json, written last.
class PhoneSet {
  static const version = 1;
  static const file = 'set.json';

  final String title;
  final String kind; // 'Mashups' or 'Mix'
  final DateTime created;
  final double duration;
  final List<PhoneSection> sections;
  final Map<String, dynamic> live; // the set's own levels and Auto FX, as on the Mac
  final List<double> grid; // mix time of every beat
  final List<PhonePart> parts; // each mashup or song, in order
  final List<PhoneBeatSpan> beatSpans; // mashups: which beat is carrying the set when
  String folder = ''; // where it is on this device

  PhoneSet({
    required this.title,
    required this.kind,
    required this.created,
    required this.duration,
    required this.sections,
    required this.live,
    required this.grid,
    required this.parts,
    this.beatSpans = const [],
  });

  bool get mashups => kind == 'Mashups';

  Map<String, dynamic> toJson() => {
        'version': version,
        'title': title,
        'kind': kind,
        'created': created.toIso8601String(),
        'duration': duration,
        'sections': [for (final s in sections) s.toJson()],
        'live': live,
        'grid': grid,
        'parts': [for (final p in parts) p.toJson()],
        'beatSpans': [for (final b in beatSpans) b.toJson()],
      };

  factory PhoneSet.fromJson(Map<String, dynamic> j) => PhoneSet(
        title: j['title'] as String? ?? 'Set',
        kind: j['kind'] as String? ?? 'Mix',
        created: DateTime.tryParse(j['created'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        duration: (j['duration'] as num?)?.toDouble() ?? 0,
        sections: [for (final s in (j['sections'] as List? ?? const [])) PhoneSection.fromJson(Map<String, dynamic>.from(s as Map))],
        live: Map<String, dynamic>.from(j['live'] as Map? ?? const {}),
        grid: [for (final g in (j['grid'] as List? ?? const [])) (g as num).toDouble()],
        parts: [for (final p in (j['parts'] as List? ?? const [])) PhonePart.fromJson(Map<String, dynamic>.from(p as Map))],
        beatSpans: [
          for (final b in (j['beatSpans'] as List? ?? const [])) PhoneBeatSpan.fromJson(Map<String, dynamic>.from(b as Map))
        ],
      );

  static PhoneSet? read(String folder) {
    try {
      final f = File('$folder/$file');
      if (!f.existsSync()) return null;
      return PhoneSet.fromJson(Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map))..folder = folder;
    } catch (_) {
      return null;
    }
  }

  /// The player's timeline: each section with its files on this device.
  List<Map<String, dynamic>> rows(String folder) => [
        for (final s in sections)
          {
            'path': '$folder/${s.file}',
            'voxPath': s.vox == null ? null : '$folder/${s.vox}',
            'start': s.start,
            'end': s.end,
          }
      ];

  /// Index of the part playing at [t].
  int partAt(double t) {
    var i = 0;
    for (var k = 0; k < parts.length; k++) {
      if (parts[k].start <= t) i = k;
    }
    return i;
  }
}

class PhoneSection {
  final String file;
  final String? vox;
  final double start, end;
  const PhoneSection(this.file, this.vox, this.start, this.end);

  Map<String, dynamic> toJson() => {'file': file, 'vox': vox, 'start': start, 'end': end};
  factory PhoneSection.fromJson(Map<String, dynamic> j) =>
      PhoneSection(j['file'] as String, j['vox'] as String?, (j['start'] as num).toDouble(), (j['end'] as num).toDouble());
}

/// What's on a deck during a part.
class PhoneDeck {
  final String title, artist, bpm, key, speed, tag;
  const PhoneDeck(this.title, this.artist, {this.bpm = '', this.key = '', this.speed = '', this.tag = ''});

  Map<String, dynamic> toJson() => {'title': title, 'artist': artist, 'bpm': bpm, 'key': key, 'speed': speed, 'tag': tag};
  factory PhoneDeck.fromJson(Map<String, dynamic> j) => PhoneDeck(
        j['title'] as String? ?? '',
        j['artist'] as String? ?? '',
        bpm: j['bpm'] as String? ?? '',
        key: j['key'] as String? ?? '',
        speed: j['speed'] as String? ?? '',
        tag: j['tag'] as String? ?? '',
      );
}

/// One mashup (a vocal over a beat) or one song of a blend, from [start] (when
/// it takes over) to [end] (when it has gone).
class PhonePart {
  final double start, end;
  final PhoneDeck? vocal; // mashups; null for a beat break
  final PhoneDeck? beat; // mashups
  final PhoneDeck? song; // blends
  const PhonePart(this.start, this.end, {this.vocal, this.beat, this.song});

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        if (vocal != null) 'vocal': vocal!.toJson(),
        if (beat != null) 'beat': beat!.toJson(),
        if (song != null) 'song': song!.toJson(),
      };

  factory PhonePart.fromJson(Map<String, dynamic> j) {
    PhoneDeck? d(String k) => j[k] == null ? null : PhoneDeck.fromJson(Map<String, dynamic>.from(j[k] as Map));
    return PhonePart((j['start'] as num).toDouble(), (j['end'] as num).toDouble(), vocal: d('vocal'), beat: d('beat'), song: d('song'));
  }
}

/// From [start], [deck] carries the beat (the anchor, or the next mashup's
/// beat coming in).
class PhoneBeatSpan {
  final double start;
  final PhoneDeck deck;
  final bool home;
  const PhoneBeatSpan(this.start, this.deck, {this.home = false});

  Map<String, dynamic> toJson() => {'start': start, 'deck': deck.toJson(), 'home': home};
  factory PhoneBeatSpan.fromJson(Map<String, dynamic> j) =>
      PhoneBeatSpan((j['start'] as num).toDouble(), PhoneDeck.fromJson(Map<String, dynamic>.from(j['deck'] as Map)), home: j['home'] == true);
}
