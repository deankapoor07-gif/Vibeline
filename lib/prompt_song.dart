import 'models.dart';

/// What the vibe box said about a song to build the mix around.
class PromptSong {
  final LibraryTrack? track; // null: asked for a song that isn't in the library
  final String query; // the song as typed
  final String rest; // the rest of the prompt (the vibe)
  const PromptSong(this.track, this.query, this.rest);
}

String _norm(String x) => x
    .toLowerCase()
    .replaceAll(RegExp(r'[(\[].*?[)\]]'), ' ')
    .replaceAll(RegExp(r'\s+-\s+.*$'), ' ') // "Song - Remastered 2011"
    .replaceAll(RegExp(r'\b(feat|ft)\b.*$'), ' ')
    .replaceAll('&', ' and ')
    .replaceAll(RegExp(r"[^a-z0-9 ]"), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

// "startin" ~ "starting", "somethin" ~ "something", "u" ~ "you".
bool _wordsMatch(String a, String b) {
  if (a == b) return true;
  const alias = {'u': 'you', 'ur': 'your', 'n': 'and', 'luv': 'love', 'im': 'i am'};
  if (alias[a] == b || alias[b] == a) return true;
  final (s, l) = a.length <= b.length ? (a, b) : (b, a);
  return s.length >= 4 && l.startsWith(s) && l.length - s.length <= 2;
}

/// How well [query] names [title]: 3 exact, 2 close (same words allowing
/// dropped g's and small endings, the title starting with what was typed, or
/// a big enough piece of it), 0 not this song.
double _titleScore(String query, String title) {
  if (title.isEmpty) return 0;
  if (title == query) return 3;
  if (title.length >= 3 && (title.startsWith('$query ') || query.startsWith('$title '))) return 2;
  final q = query.split(' '), t = title.split(' ');
  // A good chunk of the title: "sugar plum fairy" for "Dance of the Sugar
  // Plum Fairy" (at least two words and half the title).
  if (q.length >= 2 && q.length * 2 >= t.length && ' $title '.contains(' $query ')) return 2;
  if (q.length != t.length) return 0;
  for (var i = 0; i < q.length; i++) {
    if (!_wordsMatch(q[i], t[i])) return 0;
  }
  return 2;
}

// Clearly asking for a song: if it isn't found, say so.
final _strongAsk = RegExp(
    r'^\s*(?:please\s+)?(?:(?:build|make|start|begin|open)\s+(?:a\s+|the\s+|my\s+)?(?:mix|set|mashup)?\s*(?:around|with|from)|'
    r'mix\s+around|start\s+(?:off\s+)?with|begin\s+with|open\s+with|around)\s+(.+)$',
    caseSensitive: false);
// "mix …" / "mashup …" might be a song or a vibe ("mix genres").
final _weakAsk = RegExp(r'^\s*(?:mix|mashup)\s+(.+)$', caseSensitive: false);

/// Finds the song a prompt asks to build the mix around:
/// "mix Slice of Heaven", "start with Thriller by Michael Jackson, party",
/// or just a song title on its own. Returns null when the prompt is only a vibe.
PromptSong? songFromPrompt(String prompt, List<LibraryTrack> tracks) {
  final strong = _strongAsk.firstMatch(prompt);
  final m = strong ?? _weakAsk.firstMatch(prompt);
  // Without "mix …" / "start with …" the whole prompt can still be a title.
  final asked = m != null;
  final body = m != null ? m.group(1)! : prompt;
  final parts = body.split(',');
  var query = _norm(parts.first);
  String? artist;
  final by = RegExp(r'^(.+?) by (.+)$').firstMatch(query);
  if (by != null) {
    query = by.group(1)!.trim();
    artist = by.group(2)!.trim();
  }
  if (query.length < 3) return null;
  // A title typed on its own: two or more words, or one word that's the whole
  // prompt and exactly a title (so "Party, mix genres" stays a vibe).
  final words = query.split(' ').length;
  bool bareOk(double sc) => words >= 2 || (sc >= 3 && parts.length == 1);
  LibraryTrack? best;
  var bestScore = 0.0;
  for (final t in tracks) {
    var sc = _titleScore(query, _norm(t.title));
    if (sc == 0 || (!asked && !bareOk(sc))) continue;
    if (artist != null) sc += _norm(t.artist).contains(artist) ? 1.0 : -1.5;
    if (t.analysis != null) sc += 0.2;
    if (t.shazam) sc += 0.1;
    if (sc > bestScore) {
      bestScore = sc;
      best = t;
    }
  }
  final rest = parts.skip(1).join(',').trim();
  if (best != null && bestScore >= 2) return PromptSong(best, parts.first.trim(), rest);
  return strong != null ? PromptSong(null, parts.first.trim(), rest) : null;
}
