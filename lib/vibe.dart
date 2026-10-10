import 'dart:math' as math;

import 'models.dart';

/// What a typed vibe ("Aussie rock crowd, high energy, smooth transitions")
/// means musically.
class VibeProfile {
  double targetBpm = 120;
  double startEnergy = 0.5;
  double peakEnergy = 0.9;
  double endEnergy = 0.75;
  int trackCount = 10;
  double minutes = 11; // how long the set should run
  bool smooth = true; // long blends vs. punchy cuts
  bool mixGenres = false; // reward genre contrast between songs
  bool shazamOnly = false;
  bool aussie = false;
  int? yearFrom;
  int? yearTo;
  final Set<String> genres = {}; // genre families wanted
  String? vocalFamily; // "country vocals over hip hop" -> country
  String? beatFamily; //                                 -> hiphop
  // Master "analog warmth" (tape saturation + vinyl crackle), set by the vibe.
  double drive = 1.2;
  double crackle = 0.3;
  final List<String> description = [];

  /// Energy the set should have at position p (0 = first song, 1 = last).
  double energyAt(double p) {
    if (p < 0.7) return startEnergy + (peakEnergy - startEnergy) * (p / 0.7);
    return peakEnergy + (endEnergy - peakEnergy) * ((p - 0.7) / 0.3);
  }

  String get summary => description.isEmpty ? 'All-rounder mix' : description.join(' · ');
}

/// Broad genre families, from the genre tag in each file.
String genreFamily(String genre) {
  final g = genre.toLowerCase();
  if (g.contains('hip') || g.contains('rap') || g.contains('trap')) return 'hiphop';
  if (g.contains('r&b') || g.contains('soul') || g.contains('funk')) return 'rnb';
  if (g.contains('house') || g.contains('dance') || g.contains('electr') || g.contains('techno') || g.contains('edm')) {
    return 'dance';
  }
  if (g.contains('rock') || g.contains('alternative') || g.contains('metal') || g.contains('punk') || g.contains('indie')) {
    return 'rock';
  }
  if (g.contains('country')) return 'country';
  if (g.contains('reggae') || g.contains('dancehall') || g.contains('afro')) return 'reggae';
  if (g.contains('jazz') || g.contains('blues')) return 'jazz';
  if (g.contains('latin') || g.contains('reggaeton')) return 'latin';
  if (g.contains('pop') || g.contains('singer')) return 'pop';
  return 'other';
}

const _aussieArtists = [
  'men at work', 'inxs', 'ac/dc', 'acdc', 'midnight oil', 'cold chisel', 'jimmy barnes', 'kylie',
  'savage garden', 'crowded house', 'the veronicas', 'sia', 'vance joy', 'tones and i', 'dean lewis',
  '5 seconds of summer', 'gotye', 'jet', 'silverchair', 'powderfinger', 'hilltop hoods', 'flume',
  'peking duk', 'rufus', 'rüfüs', 'keith urban', 'natalie imbruglia', 'icehouse', 'hunters & collectors',
  'the living end', 'wolfmother', 'john farnham', 'kasey chambers', 'daryl braithwaite', 'missy higgins',
  'jessica mauboy', 'guy sebastian', 'delta goodrem', 'the presets', 'cut copy', 'empire of the sun',
  'tame impala', 'the temper trap', 'angus & julia stone', 'king gizzard', 'g flip', 'the kid laroi',
  'troye sivan', 'iggy azalea', 'vera blue', 'ruel', 'masked wolf', 'pnau', 'the avalanches',
  'bee gees', 'little river band', 'air supply', 'australian crawl', 'divinyls', 'mental as anything',
  'hoodoo gurus', 'the church', 'the angels', 'rose tattoo', 'skyhooks', 'the easybeats', 'birds of tokyo',
  'grinspoon', 'spiderbait', 'shannon noll', 'amy shark', 'courtney barnett', 'meg mac', 'paul kelly',
  'thelma plum', 'baker boy', 'alison wonderland', 'what so not', 'hayden james', 'dom dolla', 'fisher',
  'confidence man', 'lime cordiale', 'spacey jane', 'ocean alley', 'sheppard', 'timmy trumpet',
];

bool isAussie(String artist) {
  final a = artist.toLowerCase();
  return _aussieArtists.any((x) => a.contains(x));
}

VibeProfile parseVibe(String text) {
  final v = VibeProfile();
  final t = text.toLowerCase();
  // Whole words only, so 'run' doesn't match 'brunch'.
  bool has(List<String> words) =>
      words.any((w) => RegExp('(?<![a-z0-9])${RegExp.escape(w)}(?![a-z0-9])').hasMatch(t));

  // Energy / tempo.
  if (has(['rave', 'techno', 'edm', 'club', 'banger', 'hype', 'festival', 'peak time'])) {
    v
      ..targetBpm = 127
      ..startEnergy = 0.7
      ..peakEnergy = 1.0
      ..endEnergy = 0.9
      ..smooth = false;
    v.genres.addAll(['dance', 'pop']);
    v.description.add('Club energy');
  } else if (has(['gym', 'workout', 'run', 'training'])) {
    v
      ..targetBpm = 126
      ..startEnergy = 0.75
      ..peakEnergy = 1.0
      ..endEnergy = 0.95
      ..smooth = false;
    v.description.add('Workout pace');
  } else if (has(['chill', 'cafe', 'café', 'lounge', 'relax', 'dinner', 'sunset', 'background', 'study', 'coffee'])) {
    v
      ..targetBpm = 100
      ..startEnergy = 0.3
      ..peakEnergy = 0.55
      ..endEnergy = 0.35
      ..smooth = true;
    v.description.add('Laid-back');
  } else if (has(['party', 'high energy', 'dance floor', 'dancefloor', 'pumping', 'wedding', 'birthday'])) {
    v
      ..targetBpm = 122
      ..startEnergy = 0.6
      ..peakEnergy = 1.0
      ..endEnergy = 0.85;
    v.description.add('Party energy');
  }

  // Genres.
  if (has(['hip hop', 'hip-hop', 'hiphop', 'rap', 'trap'])) {
    v.genres.add('hiphop');
    if (!has(['rave', 'club', 'techno'])) v.targetBpm = 96;
  }
  if (has(['r&b', 'rnb', 'soul', 'funk'])) v.genres.add('rnb');
  if (has(['rock', 'guitar', 'pub'])) v.genres.add('rock');
  if (has(['country', 'cowboy', 'boots'])) v.genres.add('country');
  if (has(['reggae', 'dancehall', 'island', 'afrobeat'])) v.genres.add('reggae');
  if (has(['house', 'dance music', 'electronic'])) v.genres.add('dance');
  if (has(['pop', 'top 40', 'hits', 'chart'])) v.genres.add('pop');
  if (has(['jazz', 'blues'])) v.genres.add('jazz');
  if (has(['latin', 'reggaeton'])) v.genres.add('latin');
  if (v.genres.isNotEmpty) v.description.add(v.genres.map(_familyName).join(' + '));

  // "country vocals over hip hop beats"
  final over = RegExp(r"([a-z&/ -]+?)\s+(?:vocals?|acapellas?|singing|singers?)\s+(?:over|on|with)\s+(?:a\s+|an\s+)?([a-z&/ -]+?)(?:\s+(?:beats?|instrumentals?|music|grooves?))?(?:$|[,.!])")
      .firstMatch(t);
  if (over != null) {
    String? fam(String words) {
      final f = genreFamily(words);
      return f == 'other' ? null : f;
    }
    final vocalWords = over.group(1)!.split(RegExp(r'[, ]+')).where((w) => w.isNotEmpty).toList();
    v.vocalFamily = fam(vocalWords.skip(math.max(0, vocalWords.length - 2)).join(' '));
    v.beatFamily = fam(over.group(2)!);
    if (v.vocalFamily != null && v.beatFamily != null) {
      v.description.add('${_familyName(v.vocalFamily!)} vocals over ${_familyName(v.beatFamily!)} beats');
    }
  }

  if (has(['aussie', 'australia', 'straya', 'oz rock', 'down under'])) {
    v.aussie = true;
    v.description.add('Aussie flavour');
  }

  // Eras.
  final decade = RegExp(r"\b(19)?([5-9]0)'?s\b").firstMatch(t);
  if (decade != null) {
    final d = 1900 + int.parse(decade.group(2)!);
    v
      ..yearFrom = d
      ..yearTo = d + 9;
    v.description.add('${decade.group(2)}s');
  } else if (has(['2000s', 'noughties'])) {
    v
      ..yearFrom = 2000
      ..yearTo = 2009;
    v.description.add('2000s');
  } else if (has(['throwback', 'old school', 'retro', 'classic'])) {
    v.yearTo = 2005;
    v.description.add('Throwbacks');
  } else if (has(['modern', 'new', 'today', 'latest', 'current', 'fresh', 'recent'])) {
    v.yearFrom = 2018;
    v.description.add('Modern');
  }

  // Shape of the mix.
  if (has(['mashup', 'mash-up', 'mix genres', 'all genres', 'different genres', 'eclectic', 'all over', 'mixed bag', 'variety'])) {
    v.mixGenres = true;
    v.description.add('Genre-hopping');
  }
  if (has(['shazam', 'my favourites', 'my favorites', 'songs i like', 'my songs'])) {
    v.shazamOnly = true;
    v.description.add('Your Shazams');
  }
  if (has(['smooth', 'seamless', 'long blends', 'silky'])) v.smooth = true;
  if (has(['punchy', 'quick cuts', 'fast cuts', 'chop', 'hard'])) v.smooth = false;
  // Set length: "short", "long", "4 hours", "4hrs", "90 minutes", "20 songs".
  if (has(['short', 'quick set', 'quick mix'])) v.minutes = 7;
  if (has(['long', 'hour', 'marathon'])) v.minutes = 60;
  if (has(['all night', 'all-nighter'])) v.minutes = 240;
  final hours = RegExp(r'\b(\d+(?:\.\d+)?)\s*(?:h|hr|hrs|hour|hours)\b').firstMatch(t);
  if (hours != null) v.minutes = double.parse(hours.group(1)!) * 60;
  final mins = RegExp(r'\b(\d{1,3})\s*(?:min|mins|minutes)\b').firstMatch(t);
  if (mins != null) v.minutes = double.parse(mins.group(1)!);
  final n = RegExp(r'\b(\d{1,3})\s*(?:songs|tracks|tunes|mashups)\b').firstMatch(t);
  if (n != null) v.minutes = int.parse(n.group(1)!) * 2.2;
  v.minutes = v.minutes.clamp(4, 360);
  v.trackCount = (v.minutes / 2.3).round().clamp(2, 160);
  if (v.minutes >= 60) {
    final h = v.minutes / 60;
    v.description.add('${h == h.roundToDouble() ? h.round() : h.toStringAsFixed(1)}h set');
  }

  final bpm = RegExp(r'\b(\d{2,3})\s*bpm\b').firstMatch(t);
  if (bpm != null) v.targetBpm = int.parse(bpm.group(1)!).toDouble().clamp(70, 180);

  // Warmth character per vibe (Dean's profiles). Drive is applied at half
  // strength above clean, since the mix already runs close to full scale.
  double half(double d) => 1 + (d - 1) * 0.5;
  if (has(['cafe', 'café', 'chill', 'lounge', 'ambient', 'relax', 'background', 'coffee', 'study'])) {
    v
      ..drive = half(1.2)
      ..crackle = 0.7;
  } else if (has(['rave', 'festival', 'techno', 'edm', 'hard', 'pounding'])) {
    v
      ..drive = half(2.2)
      ..crackle = 0.1;
  } else if (v.genres.contains('hiphop') || v.genres.contains('rnb') || has(['urban', 'bounce', 'groove'])) {
    v
      ..drive = half(1.6)
      ..crackle = 0.3;
  } else if (v.genres.contains('rock') || has(['band'])) {
    v
      ..drive = half(1.8)
      ..crackle = 0.5;
  } else {
    v
      ..drive = half(1.4)
      ..crackle = 0.3;
  }

  v.description.add(v.smooth ? 'Smooth blends' : 'Punchy cuts');
  return v;
}

String _familyName(String f) => switch (f) {
      'hiphop' => 'Hip-hop',
      'rnb' => 'R&B',
      'dance' => 'Dance',
      'rock' => 'Rock',
      'country' => 'Country',
      'reggae' => 'Reggae',
      'jazz' => 'Jazz',
      'latin' => 'Latin',
      'pop' => 'Pop',
      _ => f,
    };

/// How well a song fits the vibe, from its tags alone (before analysis).
double tagScore(LibraryTrack t, VibeProfile v, math.Random rng) {
  var s = rng.nextDouble() * 0.6; // freshness: every Re-Mix is a little different
  if (t.shazam) s += v.shazamOnly ? 3 : 0.9;
  final fam = genreFamily(t.genre);
  if (v.genres.isNotEmpty) s += v.genres.contains(fam) ? 1.2 : -0.6;
  if (v.aussie && isAussie(t.artist)) s += 2.0;
  if (t.year > 0) {
    if (v.yearFrom != null && t.year < v.yearFrom!) s -= 1.0 + (v.yearFrom! - t.year) / 10;
    if (v.yearTo != null && t.year > v.yearTo!) s -= 1.0 + (t.year - v.yearTo!) / 10;
  }
  if (fam == 'other' && t.genre.toLowerCase().contains('christmas')) s -= 3;
  if (t.duration < 100 || t.duration > 600) s -= 2;
  return s;
}
