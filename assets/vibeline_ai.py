"""Vibeline music analyser.

Commands (results are printed as one JSON object per line):
  tags <folder> ...    fast scan: title / artist / genre / year / duration for every audio file
  analyze <file> ...   tempo, beat grid, bar phase, key, energy and waveform (cached)
  separate <file> ...  split into vocals / drums / bass / other stems with Demucs (cached)
  models / getmodels   which AI models are missing / download them (first run)
"""
import json
import os
import sys
import hashlib
from concurrent.futures import FIRST_COMPLETED, ProcessPoolExecutor, as_completed, wait
from concurrent.futures.process import BrokenProcessPool

AUDIO_EXT = {".mp3", ".m4a", ".aac", ".wav", ".aiff", ".aif", ".flac"}
CACHE_DIR = os.path.expanduser("~/Library/Caches/Vibeline/analysis")
METER_DIR = os.path.expanduser("~/Library/Caches/Vibeline/meter")
STEM_DIR = os.path.expanduser("~/Library/Caches/Vibeline/stems")
STEMS = ("vocals", "drums", "bass", "other")
STEM_VERSION = 1
CACHE_VERSION = 7
SR = 44100

# Camelot wheel lookup: (key, scale) -> code
_CAMELOT = {
    ("A", "minor"): "8A", ("E", "minor"): "9A", ("B", "minor"): "10A", ("F#", "minor"): "11A",
    ("C#", "minor"): "12A", ("G#", "minor"): "1A", ("D#", "minor"): "2A", ("A#", "minor"): "3A",
    ("F", "minor"): "4A", ("C", "minor"): "5A", ("G", "minor"): "6A", ("D", "minor"): "7A",
    ("C", "major"): "8B", ("G", "major"): "9B", ("D", "major"): "10B", ("A", "major"): "11B",
    ("E", "major"): "12B", ("B", "major"): "1B", ("F#", "major"): "2B", ("C#", "major"): "3B",
    ("G#", "major"): "4B", ("D#", "major"): "5B", ("A#", "major"): "6B", ("F", "major"): "7B",
}
_ENHARMONIC = {"Db": "C#", "Eb": "D#", "Gb": "F#", "Ab": "G#", "Bb": "A#"}
_NOTES = ("A", "A#", "B", "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#")  # pitch-class profiles start on A


# ---------------------------------------------------------------------------
# Signal tools. Everything here is the app's own code (numpy), apart from
# decoding (the bundled audio-only FFmpeg, LGPL) and stretching (Signalsmith
# Stretch, MIT), so the app can be sold. These took over from Essentia (AGPL)
# and Pedalboard/Rubber Band (GPL).

def _helper_file(*parts):
    """A file shipped in the app's helper folder (…/Resources/helper), or the
    build copy in ~/NoodlesBuild when running from a development setup."""
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(sys.executable))))
    p = os.path.join(root, *parts)
    if os.path.exists(p):
        return p
    dev = {"bin/ffmpeg": "~/NoodlesBuild/ffmpeg-out/bin/ffmpeg",
           "lib/libnoodles_stretch.dylib": "~/NoodlesBuild/stretch/libnoodles_stretch.dylib"}
    return os.path.expanduser(dev.get("/".join(parts), p))


def load_audio(path, sr=SR, mono=True):
    """A song as float32 samples at `sr`: (n,) mono, or (n, 2) stereo.

    FFmpeg decodes it: the same decoder as before, so beat times stay exactly
    where earlier analyses and split stems put them (Apple's decoder puts most
    MP3s about 12 ms earlier). Damaged frames are skipped; other sample rates
    are converted with soxr."""
    import re
    import subprocess
    import numpy as np
    p = subprocess.run([_helper_file("bin", "ffmpeg"), "-nostdin", "-hide_banner", "-v", "info", "-i", path,
                        "-map", "0:a:0", "-vn", "-ac", "2", "-f", "f32le", "-acodec", "pcm_f32le", "pipe:1"],
                       capture_output=True)
    m = re.search(rb"Audio: [^\n]*?(\d+) Hz", p.stderr)
    if not p.stdout or m is None:
        tail = p.stderr.decode(errors="replace").strip().splitlines()
        raise RuntimeError("can't open this file" + (": " + tail[-1][:160] if tail else ""))
    rate = int(m.group(1))
    x = np.frombuffer(p.stdout, dtype="<f4").reshape(-1, 2)
    if mono:
        x = x.mean(1)
    if rate != sr:
        import soxr
        x = soxr.resample(x, rate, sr, quality="VHQ")
    return np.ascontiguousarray(x, dtype=np.float32)


def _spectra(x, size=4096, hop=4096, window="hann"):
    """Magnitude spectra of successive frames, and each frame's energy."""
    import numpy as np
    n = 1 + (len(x) - size) // hop if len(x) >= size else 0
    if n <= 0:
        return np.zeros((0, size // 2 + 1)), np.zeros(0)
    fr = np.lib.stride_tricks.sliding_window_view(x, size)[::hop][:n]
    if window == "hann":
        w = np.hanning(size + 1)[:-1]
    else:  # Blackman-Harris, 62 dB
        t = 2 * np.pi * np.arange(size) / size
        w = 0.44959 - 0.49364 * np.cos(t) + 0.05677 * np.cos(2 * t)
    w = (w * (2.0 / w.sum())).astype(np.float32)
    return np.abs(np.fft.rfft(fr * w, axis=1)), (fr.astype(np.float64) ** 2).sum(1)


def _peaks(row, sr, size, fmin, fmax, thresh, maxn):
    """(freqs, mags) of one spectrum's peaks within fmin..fmax, refined
    between bins by a parabola; the loudest `maxn` of them."""
    import numpy as np
    binhz = sr / size
    lo, hi = max(1, int(fmin / binhz)), min(len(row) - 2, int(fmax / binhz) + 1)
    r = row[lo - 1:hi + 2]
    c = r[1:-1]
    k = np.nonzero((c > r[:-2]) & (c >= r[2:]) & (c > thresh))[0]
    if len(k) == 0:
        return np.zeros(0), np.zeros(0)
    a, b, g = r[k], c[k], r[k + 2]
    den = a - 2 * b + g
    d = np.where(den != 0, 0.5 * (a - g) / np.where(den != 0, den, 1), 0.0)
    f = (lo + k + d) * binhz
    m = b - 0.25 * (a - g) * d
    ok = (f >= fmin) & (f <= fmax)
    f, m = f[ok], m[ok]
    if len(f) > maxn:
        top = np.argsort(m)[::-1][:maxn]
        f, m = f[top], m[top]
    return f, m


def _pcp(f, m, ref=440.0, harmonics=4, band_split=500.0):
    """12-bin harmonic pitch class profile of one frame (A first): each peak,
    and each note it could be a harmonic of (weighted down 0.6 per harmonic),
    adds its energy to the nearest pitch classes with a cosine-squared
    weight half a semitone wide. Below and above `band_split` count equally."""
    import numpy as np
    bins = np.arange(12)

    def acc(ff, mm):
        h = np.zeros(12)
        if len(ff) == 0:
            return h
        e = mm.astype(np.float64) ** 2
        for k in range(harmonics + 1):
            pc = (12 * np.log2(ff / ((k + 1) * ref))) % 12
            d = (pc[:, None] - bins[None, :] + 6) % 12 - 6
            w = np.where(np.abs(d) <= 0.5, np.cos(np.pi * d) ** 2, 0.0)
            h += (w * e[:, None]).sum(0) * 0.36 ** k
        return h
    if band_split:
        low = f < band_split
        lo, hi = acc(f[low], m[low]), acc(f[~low], m[~low])
        return lo / (lo.max() or 1) + hi / (hi.max() or 1)
    return acc(f, m)


def _pcp_frames(x, sr=SR, harmonics=4, fmin=25, fmax=3500, thresh=1e-4, maxn=60, window="hann", ref=440.0):
    """Pitch class profile of every 4096-sample frame, and the frames' energy."""
    import numpy as np
    mags, energy = _spectra(x, 4096, 4096, window)
    rows = [_pcp(*_peaks(row, sr, 4096, fmin, fmax, thresh, maxn), ref=ref, harmonics=harmonics) for row in mags]
    return (np.nan_to_num(np.array(rows)) if rows else np.zeros((0, 12))), energy


def _tuning(x, sr=SR):
    """The concert pitch (Hz) a recording is tuned to: where its spectral
    peaks sit between equal-tempered notes, from a loudness-weighted
    1-cent histogram over the whole song. (Essentia's version came back as
    exactly 434.19 Hz on about a quarter of songs, a quarter-semitone out.)"""
    import numpy as np
    mags, _ = _spectra(x, 4096, 4096, "hann")
    hist = np.zeros(100)
    for row in mags:
        f, m = _peaks(row, sr, 4096, 80, 6000, 1e-4, 100)
        if len(f):
            dev = (1200 * np.log2(f / 440.0) + 50) % 100  # 50 = in tune with A440
            np.add.at(hist, np.minimum(99, dev.astype(int)), m)
    if not hist.any():
        return 440.0
    smooth = sum(np.roll(hist, k) * w for k, w in ((-2, .25), (-1, .5), (0, 1), (1, .5), (2, .25)))
    cents = int(np.argmax(smooth)) + 0.5 - 50
    return float(440.0 * 2 ** (cents / 1200))


# Key profiles (tonic first), learned from 1,087 songs in Dean's library
# against the key labels Essentia gave them. Tested 13 Nov 2026: the same key
# as Essentia on 70% of songs (82% the same or a Camelot neighbour, where the
# two often both have a case); on 24 well-known songs, 11 right to Essentia's
# 13. Mashups match on the stems' real notes (_stem_chroma), not these labels.
_MAJOR_PROFILE = (1.999, -0.905, 0.598, -0.991, 0.744, 0.218, -1.002, 1.452, -0.965, 0.191, -1.037, -0.303)
_MINOR_PROFILE = (1.936, -0.995, 0.124, 0.513, -0.99, 0.6, -1.195, 1.547, -0.179, -0.862, 0.429, -0.926)


def _key(x, tuning=440.0, sr=SR):
    """(note, "major"/"minor", strength 0..1) from the song's average pitch
    class profile, by correlation with the major and minor key profiles."""
    import numpy as np
    rows, _ = _pcp_frames(x, sr)
    if not len(rows):
        return "C", "major", 0.0
    p = (rows / np.maximum(rows.max(1, keepdims=True), 1e-9)).mean(0)
    best = (-2.0, "C", "major")
    for t in range(12):
        for scale, prof in (("major", _MAJOR_PROFILE), ("minor", _MINOR_PROFILE)):
            c = float(np.corrcoef(p, np.roll(prof, t))[0, 1])
            if c > best[0]:
                best = (c, _NOTES[t], scale)
    return best[1], best[2], max(0.0, best[0])


def _danceability(x, sr=SR):
    """How steadily the music pulses (about 0..3, higher = more danceable):
    detrended fluctuation analysis of the loudness (Streich & Herrera, 2005),
    as 1 / the mean scaling exponent over 0.3..8.8 s windows."""
    import numpy as np
    hop = int(round(0.01 * sr))
    n = len(x) // hop
    if n < 1000:
        return 1.0
    s = np.sqrt((x[:n * hop].reshape(n, hop).astype(np.float64) ** 2).mean(1))
    y = np.cumsum(s - s.mean())
    taus, t = [], 31.0
    while t <= 880:
        taus.append(int(t))
        t *= 1.1
    taus = sorted(set(taus))
    F = []
    for tau in taus:
        k = n // tau
        seg = y[:k * tau].reshape(k, tau)
        xs = np.arange(tau) - (tau - 1) / 2
        slope = (seg * xs).sum(1) / (xs * xs).sum()
        res = seg - seg.mean(1, keepdims=True) - slope[:, None] * xs
        F.append(np.sqrt((res ** 2).mean()) + 1e-12)
    alpha = np.diff(np.log10(F)) / np.diff(np.log10(np.asarray(taus, float) + 3))
    return float(1.0 / max(0.05, alpha.mean()))


def _lowpass(x, fc, sr=SR):
    """Second-order Butterworth low-pass."""
    import numpy as np
    import torch
    import torchaudio.functional as AF
    w0 = 2 * np.pi * fc / sr
    alpha = np.sin(w0) / (2 * 0.7071067811865476)
    c = np.cos(w0)
    b = np.array([(1 - c) / 2, 1 - c, (1 - c) / 2]) / (1 + alpha)
    a = np.array([1 + alpha, -2 * c, 1 - alpha]) / (1 + alpha)
    t = torch.from_numpy(np.ascontiguousarray(x, dtype=np.float32))[None]
    y = AF.lfilter(t, torch.tensor(a, dtype=torch.float32), torch.tensor(b, dtype=torch.float32), clamp=False)
    return y[0].numpy()


def _onset_envelope(x, sr=SR, hop=512):
    """Spectral flux (log magnitude), frames of `hop` samples."""
    import numpy as np
    mags, _ = _spectra(x, 2048, hop, "hann")
    if len(mags) < 3:
        return np.zeros(0)
    lm = np.log1p(100 * mags)
    flux = np.maximum(0, np.diff(lm, axis=0)).sum(1)
    flux = np.concatenate([[0], flux])
    flux = flux - np.convolve(flux, np.ones(31) / 31, "same")
    return np.maximum(flux, 0) / (flux.std() + 1e-9)


def _simple_beats(x, sr=SR):
    """A plain beat tracker for when the AI one can't run: tempo from the
    onset envelope's autocorrelation (favouring about 120 BPM), then the best
    chain of beats by dynamic programming (Ellis, 2007). Returns (beats,
    confidence 0..5)."""
    import numpy as np
    hop = 512
    env = _onset_envelope(x, sr, hop)
    fps = sr / hop
    if len(env) < fps * 10:
        return [], 0.0
    ac = np.correlate(env, env, "full")[len(env) - 1:]
    lags = np.arange(len(ac))
    bpm = 60 * fps / np.maximum(lags, 1)
    ok = (bpm >= 60) & (bpm <= 190)
    prior = np.exp(-0.5 * (np.log2(np.maximum(bpm, 1) / 120) / 0.9) ** 2)
    score = np.where(ok, ac * prior, -np.inf)
    period = int(np.argmax(score))
    conf = float(np.clip(5 * ac[period] / (ac[0] + 1e-9), 0, 5))
    best = np.zeros(len(env))
    back = np.full(len(env), -1)
    lo, hi = int(period * 0.5), int(period * 2)
    for i in range(len(env)):
        a, b = max(0, i - hi), i - lo
        if b > a:
            prev = np.arange(a, b)
            cost = -100 * np.log((i - prev) / period) ** 2
            j = int(np.argmax(best[a:b] + cost))
            if best[a + j] + cost[j] > 0:
                best[i] = env[i] + best[a + j] + cost[j]
                back[i] = a + j
                continue
        best[i] = env[i]
    i = int(np.argmax(best[-period * 2:])) + len(env) - period * 2
    out = []
    while i >= 0:
        out.append(i / fps)
        i = back[i]
    return out[::-1], conf


_STRETCH = None


def _stretch(x, sr, map_out, map_in, out_len, semitones=0.0, keep_formants=False):
    """Signalsmith Stretch over (channels, n) audio, following a time map:
    output sample map_out[k] plays input sample map_in[k], linear between."""
    import ctypes
    import numpy as np
    global _STRETCH
    if _STRETCH is None:
        lib = ctypes.CDLL(_helper_file("lib", "libnoodles_stretch.dylib"))
        P = ctypes.POINTER
        lib.noodles_stretch.argtypes = [P(P(ctypes.c_float)), ctypes.c_int, ctypes.c_long, ctypes.c_double,
                                        P(ctypes.c_double), P(ctypes.c_double), ctypes.c_int,
                                        ctypes.c_double, ctypes.c_int, ctypes.c_double,
                                        P(P(ctypes.c_float)), ctypes.c_long]
        lib.noodles_stretch.restype = ctypes.c_int
        _STRETCH = lib
    x = np.ascontiguousarray(x, dtype=np.float32)
    ch = x.shape[0]
    y = np.zeros((ch, int(out_len)), np.float32)
    FP, DP = ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_double)
    ins = (FP * ch)(*[x[c].ctypes.data_as(FP) for c in range(ch)])
    outs = (FP * ch)(*[y[c].ctypes.data_as(FP) for c in range(ch)])
    mo = np.ascontiguousarray(map_out, dtype=np.float64)
    mi = np.ascontiguousarray(map_in, dtype=np.float64)
    if _STRETCH.noodles_stretch(ins, ch, x.shape[1], float(sr), mo.ctypes.data_as(DP), mi.ctypes.data_as(DP),
                                len(mo), float(semitones), int(bool(keep_formants)), 8000.0, outs, y.shape[1]):
        raise RuntimeError("stretch failed")
    return y


def _quiet_crashes():
    """A damaged song can crash the decoder, which is planned for: the song is
    skipped and everything carries on. Leave quietly, so macOS doesn't put a
    "Python quit unexpectedly" box in front of the user. A plain C exit is used
    because Python's own signal handlers can't run during a crash."""
    import ctypes
    import signal
    libc = ctypes.CDLL(None)
    libc.signal.argtypes = [ctypes.c_int, ctypes.c_void_p]
    libc.signal.restype = ctypes.c_void_p
    leave = ctypes.cast(libc._exit, ctypes.c_void_p).value
    for s in (signal.SIGSEGV, signal.SIGBUS, signal.SIGILL, signal.SIGABRT, signal.SIGFPE):
        libc.signal(int(s), leave)


def _guard():
    """Run politely and never outlive the app: lower priority, and exit as soon
    as Vibeline is closed (otherwise a half-finished stem split would keep the
    Mac busy in the background)."""
    import threading
    import time
    try:
        os.nice(10)
    except Exception:
        pass
    app = int(os.environ.get("VIBELINE_APP_PID", "0") or 0)
    parent = os.getppid()

    def watch():
        while True:
            time.sleep(2)
            # Whoever started this has gone (a crash, say): nothing needs it now.
            if os.getppid() != parent:
                os._exit(0)
            if app > 0:
                try:
                    os.kill(app, 0)
                except OSError:
                    os._exit(0)

    threading.Thread(target=watch, daemon=True).start()


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


# ---------------------------------------------------------------- tags

def read_tags(path):
    from tinytag import TinyTag
    info = {"path": path, "title": "", "artist": "", "genre": "", "year": 0, "duration": 0.0}
    try:
        t = TinyTag.get(path, tags=True, duration=True, image=False)
        info["duration"] = float(t.duration or 0.0)
        info["title"] = (t.title or "").strip()
        info["artist"] = (t.artist or t.albumartist or "").strip()
        info["genre"] = (t.genre or "").strip()
        date = (t.year or "").strip()
        if date[:4].isdigit():
            info["year"] = int(date[:4])
    except Exception:
        pass
    if not info["title"]:
        base = os.path.splitext(os.path.basename(path))[0]
        # "01 Song Name" -> "Song Name"
        parts = base.split(" ", 1)
        info["title"] = parts[1] if len(parts) == 2 and parts[0].isdigit() else base
    return info


TAGS_CACHE = os.path.expanduser("~/Library/Caches/Vibeline/tags.json")


def cmd_tags(folders):
    # Song details are remembered by path, size and date, so searching the
    # whole Mac again only reads files that are new or changed.
    try:
        with open(TAGS_CACHE) as f:
            old = json.load(f)
    except Exception:
        old = {}
    new = {}
    seen = set()
    for folder in folders:
        _scan(folder, seen, old, new)
    # Remember songs on a drive that isn't plugged in right now, so plugging it
    # back in doesn't mean reading every file again.
    for path, entry in old.items():
        if path not in new and path.startswith("/Volumes/"):
            if not os.path.isdir("/".join(path.split("/")[:3])):
                new[path] = entry
    try:
        os.makedirs(os.path.dirname(TAGS_CACHE), exist_ok=True)
        with open(TAGS_CACHE + ".tmp", "w") as f:
            json.dump(new, f)
        os.replace(TAGS_CACHE + ".tmp", TAGS_CACHE)
    except Exception:
        pass
    emit({"type": "done"})


# Folders that never hold your music: system and app innards, code projects,
# photo / video / music-making libraries, and this app's own saved mixes.
SKIP_DIRS = {"Library", "Applications", "System", "node_modules", "build", "venv", ".venv", "site-packages",
             "Pods", "DerivedData", "__pycache__", "Backups.backupdb", "D-Jay Noodles", "Vibeline", "Apple Loops"}
SKIP_PACKAGES = (".app", ".bundle", ".framework", ".plugin", ".photoslibrary", ".imovielibrary", ".logicx",
                 ".band", ".fcpbundle", ".tvlibrary", ".musiclibrary", ".xcodeproj", ".xcworkspace")


PROJECT_FILES = {"pubspec.yaml", "package.json", "Package.swift", "Podfile", "Cargo.toml", "pyproject.toml",
                 "setup.py", "build.gradle", "CMakeLists.txt", "Makefile"}


def _is_project(dirs, files):
    return (".git" in dirs or any(f in PROJECT_FILES for f in files)
            or any(d.endswith((".xcodeproj", ".xcworkspace")) for d in dirs))


def _scan(folder, seen, old, new):
    for root, dirs, files in os.walk(folder):
        # An app or code project (sound effects, test tones, demo renders):
        # not your music. The folder you picked yourself is always searched.
        if root != folder and _is_project(dirs, files):
            dirs[:] = []
            continue
        dirs[:] = [d for d in dirs
                   if not d.startswith(".") and d not in SKIP_DIRS and not d.lower().endswith(SKIP_PACKAGES)]
        for name in sorted(files):
            if name.startswith("."):
                continue
            path = os.path.join(root, name)
            if os.path.splitext(name)[1].lower() in AUDIO_EXT and path not in seen:
                seen.add(path)
                try:
                    st = os.stat(path)
                except OSError:
                    continue
                key = f"{st.st_size}|{int(st.st_mtime)}"
                hit = old.get(path)
                info = hit[1] if hit and hit[0] == key else read_tags(path)
                new[path] = [key, info]
                emit({"type": "tags", **info})


# ---------------------------------------------------------------- analysis

def _drop_bad_tuning(d):
    """Analyses saved before 12 Nov 2026 say exactly 434.19 Hz for about a
    quarter of songs, a fault in the tuning reader used then, not the song's
    real tuning. Treated as unknown, so the song isn't retuned by mistake."""
    if d.get("tuning") == 434.19:
        d.pop("tuning")
    return d


def _cache_path(path):
    st = os.stat(path)
    h = hashlib.sha1(f"{path}|{st.st_size}|{int(st.st_mtime)}|{CACHE_VERSION}".encode()).hexdigest()
    return os.path.join(CACHE_DIR, h + ".json")


def _bar_beats(beats, downs):
    """Beats to a bar: 4 (also 2/2, which lines up with 4/4), 3 (3/4 and 6/8,
    which can't sit on a 4/4 beat), or 0 if the bars don't read clearly."""
    gaps = {}
    n = 0
    for a, b in zip(downs, downs[1:]):
        c = sum(1 for t in beats if a - 0.03 <= t < b - 0.03)
        gaps[c] = gaps.get(c, 0) + 1
        n += 1
    if n < 8:
        return 0
    share = lambda c: gaps.get(c, 0) / n
    if share(3) + share(6) >= 0.7:
        return 3
    if share(4) >= 0.7 or (share(4) >= 0.5 and share(4) + share(2) >= 0.8):
        return 4
    return 0


def _meter_path(path):
    return os.path.join(METER_DIR, os.path.basename(_cache_path(path)))


def _save_meter(path, beats):
    try:
        os.makedirs(METER_DIR, exist_ok=True)
        with open(_meter_path(path), "w") as fh:
            json.dump({"beats": beats}, fh)
    except OSError:
        pass


def _clean_beats(ticks):
    """Drop doubled beats and fill dropped ones so every gap is about one beat."""
    import numpy as np
    t = [float(x) for x in ticks]
    if len(t) < 8:
        return t
    period = float(np.median(np.diff(t)))
    out = [t[0]]
    for x in t[1:]:
        gap = x - out[-1]
        if gap < period * 0.6:
            continue
        missing = int(round(gap / period)) - 1
        for k in range(missing):
            out.append(out[-1] + gap / (missing + 1))
        out.append(x)
    return out


def _refine_phase(audio, beats):
    """Nudge the beat grid onto the actual note attacks.

    The beat tracker's marks can sit up to ~35 ms before or after the hits,
    differently for every song; two songs mixed with different offsets flam.
    Slide the grid to where onset strength (spectral flux) peaks on average."""
    import numpy as np
    hop, size = 64, 1024
    frames = max(0, (len(audio) - size) // hop + 1)
    b = np.asarray(beats)
    base = ((b * SR - 512) / hop).astype(int)
    # Only the moments near a beat count, so only those are worked out (the
    # search below reaches 42 frames each way, and its average 30 further).
    wanted = np.zeros(frames + 1, dtype=np.int8)
    reach = 42 + 31
    for c in base:
        wanted[max(0, c - reach):min(frames, c + reach + 1)] = 1
    edges = np.flatnonzero(np.diff(np.concatenate(([0], wanted))))
    env = np.zeros(frames)
    window = np.hanning(size + 1)[:-1].astype(np.float32)
    for start, stop in zip(edges[::2], edges[1::2]):
        first = max(0, start - 1)  # flux compares with the frame before
        slices = np.lib.stride_tricks.sliding_window_view(audio[first * hop:(stop - 1) * hop + size], size)[::hop]
        mags = np.abs(np.fft.rfft(slices * window, axis=1))
        flux = np.abs(np.diff(mags, axis=0)).sum(axis=1)
        env[first + 1:first + 1 + len(flux)] = flux
    env = np.maximum(env - np.convolve(env, np.ones(61) / 61, "same"), 0)
    best_k, best_v = 0, -1.0
    for k in range(-42, 43):  # about ±60 ms
        idx = base + k
        idx = idx[(idx >= 0) & (idx < len(env))]
        v = float(env[idx].mean()) if len(idx) else 0.0
        if v > best_v:
            best_k, best_v = k, v
    shift = best_k * hop / SR
    return [float(x) + shift for x in beats], shift


def _fit_grid(ticks):
    """Straight-line fit of beat times -> (period, first_beat).

    Beat trackers wobble by a few ms per beat, so a single gap (or the median of
    gaps) is a poor tempo; a regression over the whole song is much steadier."""
    import numpy as np
    t = np.asarray(ticks, dtype=float)
    if len(t) < 8:
        return None
    period = float(np.median(np.diff(t)))
    for _ in range(3):
        idx = np.round((t - t[0]) / period)
        A = np.vstack([idx, np.ones_like(idx)]).T
        (period, offset), *_ = np.linalg.lstsq(A, t, rcond=None)
        resid = t - (idx * period + offset)
        keep = np.abs(resid) < period * 0.25
        if keep.sum() < len(t) * 0.5:
            break
        t = t[keep]
    first = offset % period
    return float(period), float(first), float(np.std(resid) if len(resid) else 0.0)


def _beat_tracker():
    """Beat This! (a modern AI beat tracker), run in this process on the GPU, or
    None if it can't load. The older tracker got the start of the bar wrong on
    about half of songs, which put vocal lines on the wrong beat."""
    try:
        import warnings
        warnings.filterwarnings("ignore")
        import torch
        from beat_this.inference import Audio2Beats
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        return Audio2Beats(checkpoint_path="final0", device=device, dbn=False)
    except Exception:
        return None


def _worker_start():
    """Every worker process: polite, tied to the app, and quiet if a song crashes it."""
    _guard()
    _quiet_crashes()


def _decode_to_file(path, out):
    """Runs in its own process: a damaged file can crash the decoder outright."""
    import numpy as np
    np.save(out, load_audio(path))


class _Decoder:
    """Opens songs one at a time in a separate process, so a damaged file costs
    only that song rather than bringing down everything being analysed."""

    def __init__(self):
        self._pool = None

    def read(self, path):
        import numpy as np
        import tempfile
        if self._pool is None:
            self._pool = ProcessPoolExecutor(max_workers=1, initializer=_worker_start)
        fd, out = tempfile.mkstemp(prefix="noodles-decode-", suffix=".npy")
        os.close(fd)
        try:
            self._pool.submit(_decode_to_file, path, out).result()
            return np.load(out)
        except BrokenProcessPool:
            self._pool.shutdown(wait=False)
            self._pool = None
            return None
        except Exception:
            return None
        finally:
            try:
                os.remove(out)
            except OSError:
                pass

    def close(self):
        if self._pool is not None:
            self._pool.shutdown(wait=False)
            self._pool = None


def _track_beats(tracker, decoder, path):
    """(beats, downbeats) for one song, or None if it can't be tracked."""
    if tracker is None:
        return None
    try:
        # Decoded the same way as the rest of the analysis: left to itself the
        # beat tracker can't open m4a files and some mp3s.
        audio = decoder.read(path)
        if audio is None:
            return None
        beats, downs = tracker(audio, SR)
        return [float(x) for x in beats], [float(x) for x in downs]
    except Exception:
        return None


def _beat_this(paths):
    tracker = _beat_tracker() if paths else None
    decoder = _Decoder()
    out = {}
    for p in paths:
        bt = _track_beats(tracker, decoder, p)
        if bt is not None:
            out[p] = bt
    decoder.close()
    return out


def analyze_file(path, bt=None):
    cache = _cache_path(path)
    if os.path.exists(cache):
        with open(cache) as fh:
            return _drop_bad_tuning(json.load(fh))
    if bt is None:
        bt = _beat_this([path]).get(path)

    import numpy as np

    audio = load_audio(path)
    duration = len(audio) / SR
    result = {"type": "analysis", "path": path, "duration": duration, "ok": False}
    # Level, tuning and waveform are useful even for sounds with no beat
    # (rain, fire, ambient pads) so they can be used as samples.
    result["loudnessDb"] = round(float(20 * np.log10(np.sqrt(np.mean(audio ** 2)) + 1e-9)), 2)
    try:
        result["tuning"] = round(_tuning(audio), 2)
    except Exception:
        pass
    _hop = max(1, len(audio) // 160)
    _peaks = [float(np.abs(audio[i * _hop:(i + 1) * _hop]).max()) if len(audio[i * _hop:(i + 1) * _hop]) else 0.0
              for i in range(160)]
    _pm = max(_peaks) or 1.0
    result["waveform"] = [round(p / _pm, 3) for p in _peaks]
    if duration < 30:
        result["error"] = "too short"
        return result

    downbeats = []
    if bt and len(bt[0]) >= 16:
        ticks, downbeats = bt
        confidence = 3.0
        _save_meter(path, _bar_beats(ticks, downbeats))
    else:
        ticks, confidence = _simple_beats(audio)
    beats = _clean_beats(list(ticks))
    beats, phase_shift = _refine_phase(audio, beats)
    grid = _fit_grid(beats)
    if grid is None:
        result["error"] = "no beat"
        return result
    period, _, jitter = grid
    bpm = 60.0 / period
    beats = np.asarray(beats)
    n_beats = len(beats) - 1

    # Per-beat loudness, full band and low band (kick/bass).
    lp = _lowpass(audio, 150)
    beat_rms, beat_low = [], []
    for i in range(n_beats):
        a, b = int(beats[i] * SR), int(beats[i + 1] * SR)
        seg, segl = audio[a:b], lp[a:b]
        beat_rms.append(float(np.sqrt(np.mean(seg ** 2))) if len(seg) else 0.0)
        beat_low.append(float(np.sqrt(np.mean(segl ** 2))) if len(segl) else 0.0)
    beat_rms = np.asarray(beat_rms)
    beat_low = np.asarray(beat_low)

    # Bar phase: song sections change on a downbeat, so pick the phase (0..3)
    # where the biggest jumps in loudness land, with a nudge toward strong kicks.
    rise = np.maximum(0, np.diff(beat_rms, prepend=beat_rms[0]))
    scores = [rise[p::4].sum() + 0.25 * beat_low[p::4].mean() for p in range(4)]
    phase = int(np.argmax(scores))
    if downbeats:
        # Where Beat This! hears each bar start, as a beat index; the most
        # common position (mod 4) is the bar phase.
        votes = [0, 0, 0, 0]
        for d in downbeats:
            i = int(np.argmin(np.abs(beats - d)))
            if abs(beats[i] - d) < 0.08:
                votes[i % 4] += 1
        if sum(votes) >= 4:
            phase = int(np.argmax(votes))

    # Per-bar energy (0..1 relative to the song's loudest bar).
    bars = [float(beat_rms[i:i + 4].mean()) for i in range(phase, n_beats - 3, 4)]
    bars = np.asarray(bars) if bars else np.asarray([0.0])
    bar_energy = (bars / (bars.max() + 1e-9)).round(3).tolist()

    # First and last bar with real music (skip silence / fade tails).
    loud = [i for i, e in enumerate(bar_energy) if e > 0.25]
    first_bar = loud[0] if loud else 0
    last_bar = loud[-1] if loud else len(bar_energy) - 1

    key, scale, key_strength = _key(audio, result.get("tuning", 440.0))
    camelot = _CAMELOT.get((key, scale), "")

    danceability = _danceability(audio)

    result.update({
        "ok": True,
        "bpm": round(bpm, 3),
        "beatConfidence": float(confidence),
        "gridJitter": round(jitter, 4),
        "beats": [round(float(b), 4) for b in beats],
        "barPhase": phase,
        "phaseShift": round(phase_shift, 4),
        "barEnergy": bar_energy,
        "firstBar": first_bar,
        "lastBar": last_bar,
        "key": f"{key} {scale}",
        "camelot": camelot,
        "keyStrength": float(key_strength),
        "danceability": round(float(danceability), 3),
    })
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(cache, "w") as fh:
        json.dump(result, fh)
    return result


def _safe_analyze(path, bt=None):
    try:
        return analyze_file(path, bt)
    except Exception as e:  # keep going on bad files
        return {"type": "analysis", "path": path, "ok": False, "error": str(e)}


def _unreadable(decoder, path):
    """True if a song crashes or fails the decoder, so it's kept away from the
    workers, which would otherwise hit the same damage."""
    return decoder.read(path) is None


def _on_this_mac(path):
    """False for a song whose drive is unplugged, or that macOS has moved to
    iCloud. Reading one of those waits on a download, which can stall a whole
    set and fill a nearly full disk."""
    try:
        return not os.stat(path).st_flags & 0x40000000  # SF_DATALESS
    except OSError:
        return False


def _in_icloud(path):
    try:
        return bool(os.stat(path).st_flags & 0x40000000)  # SF_DATALESS
    except OSError:
        return False


def cmd_known(paths):
    """Hands back songs already analysed, without opening any audio, so a set
    can start straight away from them. Also says which are only in iCloud."""
    for p in paths:
        if not _on_this_mac(p):
            if _in_icloud(p):
                emit({"type": "in_icloud", "path": p})
            continue
        try:
            with open(_cache_path(p)) as fh:
                emit(_drop_bad_tuning(json.load(fh)))
        except (OSError, ValueError):
            pass
    emit({"type": "done"})


def cmd_meter(paths):
    """Says how many beats each song has to a bar, remembering the answer. Songs
    it can't open get no answer, so they're not judged on a failed read."""
    tracker = None
    decoder = None
    try:
        for p in paths:
            if not _on_this_mac(p):
                continue
            try:
                with open(_meter_path(p)) as fh:
                    emit({"type": "meter", "path": p, "beats": json.load(fh)["beats"]})
                continue
            except (OSError, ValueError, KeyError):
                pass
            if tracker is None:
                tracker = _beat_tracker()
                decoder = _Decoder()
            bt = _track_beats(tracker, decoder, p)
            if bt is None:
                continue
            beats = _bar_beats(*bt)
            _save_meter(p, beats)
            emit({"type": "meter", "path": p, "beats": beats})
    finally:
        if decoder is not None:
            decoder.close()
    emit({"type": "done"})


def cmd_analyze(paths):
    # Leave cores free for the app and the music.
    workers = max(1, min(4, (os.cpu_count() or 4) // 2))
    # Fewer when working in the background while a set plays.
    workers = min(workers, int(os.environ.get("VIBELINE_WORKERS") or workers))
    ready = []
    for p in paths:
        if _on_this_mac(p):
            ready.append(p)
        else:
            emit({"type": "analysis", "path": p, "ok": False, "error": "not on this Mac right now"})
    cached = [p for p in ready if os.path.exists(_cache_path(p))]
    known = set(cached)
    misses = [p for p in ready if p not in known]
    tracker = _beat_tracker() if misses else None
    decoder = _Decoder()
    # One song at a time from start to finish, reporting each as it's done, so
    # the count on screen keeps moving and stopping early loses nothing.
    pool = ProcessPoolExecutor(max_workers=workers, initializer=_worker_start)
    pending = {}  # future -> (song, its beats, the pool it's in)
    retry = []  # songs that were in a pool when something crashed it

    def submit(p, bt):
        nonlocal pool
        try:
            pending[pool.submit(_safe_analyze, p, bt)] = (p, bt, pool)
        except BrokenProcessPool:
            retry.append((p, bt))

    def report_until(most):
        nonlocal pool
        while len(pending) > most:
            done, _ = wait(pending, return_when=FIRST_COMPLETED)
            for fut in done:
                p, bt, owner = pending.pop(fut)
                try:
                    emit(fut.result())
                except BrokenProcessPool:
                    # A damaged file crashed a worker, and there's no telling
                    # which: each song it was with gets another go by itself.
                    retry.append((p, bt))
                    if owner is pool:
                        pool.shutdown(wait=False)
                        pool = ProcessPoolExecutor(max_workers=workers, initializer=_worker_start)

    try:
        for p in cached:
            submit(p, None)
        for p in misses:
            report_until(workers * 2)
            bt = _track_beats(tracker, decoder, p)
            if tracker is not None and bt is None and _unreadable(decoder, p):
                emit({"type": "analysis", "path": p, "ok": False, "error": "couldn't read this file"})
                continue
            submit(p, bt)
        report_until(0)
        for p, bt in retry:
            alone = ProcessPoolExecutor(max_workers=1, initializer=_worker_start)
            try:
                emit(alone.submit(_safe_analyze, p, bt).result())
            except BrokenProcessPool:
                emit({"type": "analysis", "path": p, "ok": False, "error": "couldn't read this file"})
            finally:
                alone.shutdown(wait=False)
    finally:
        decoder.close()
        pool.shutdown(wait=False)
    emit({"type": "done"})


# ---------------------------------------------------------------- stems

def _stem_dir(path):
    st = os.stat(path)
    h = hashlib.sha1(f"{path}|{st.st_size}|{int(st.st_mtime)}|stems{STEM_VERSION}".encode()).hexdigest()
    return os.path.join(STEM_DIR, h)


_MODEL = None


def separate_file(path):
    """Demucs (htdemucs) 4-stem split. Audio is decoded with the same decoder
    as the analyser (sample-exact with Apple's), so stems line up with beats."""
    out_dir = _stem_dir(path)
    meta_path = os.path.join(out_dir, "stems.json")
    if os.path.exists(meta_path):
        with open(meta_path) as fh:
            meta = json.load(fh)
        changed = False
        if "tuning" not in meta:  # stems made before tuning was measured
            meta["tuning"] = _stem_tuning(meta["stems"])
            changed = True
        if "levels" not in meta:  # stems made before levels were measured
            meta["levels"] = _stem_levels(meta["stems"])
            changed = True
        if "beatShift" not in meta:  # stems made before the grid was checked beat by beat
            meta.update(_grid_check(path, meta["stems"]))
            changed = True
        if "chroma" not in meta:  # stems made before their notes were measured
            meta["chroma"] = _stem_chroma(meta["stems"])
            changed = True
        if "curves" not in meta:  # stems made before drum/bass curves were measured
            meta["curves"] = _stem_curves(meta["stems"])
            changed = True
        if meta.get("beatsVersion") != CACHE_VERSION:  # analysis (beat grid) changed
            meta.update(_vocal_beats(path, meta["stems"]))
            meta["beatsVersion"] = CACHE_VERSION
            changed = True
        if changed:
            with open(meta_path, "w") as fh:
                json.dump(meta, fh)
        return meta

    import numpy as np
    import torch
    import soundfile as sf
    from demucs.pretrained import get_model
    from demucs.apply import apply_model

    global _MODEL
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    if _MODEL is None:
        _MODEL = get_model("htdemucs")
        _MODEL.to(device).eval()

    audio = load_audio(path, mono=False)
    wav = torch.tensor(np.ascontiguousarray(audio.T), dtype=torch.float32)
    ref = wav.mean(0)
    mean, std = ref.mean(), ref.std() + 1e-8
    with torch.no_grad():
        sources = apply_model(_MODEL, ((wav - mean) / std)[None].to(device),
                              device=device, split=True, overlap=0.25, progress=False)[0]
    sources = (sources * std + mean).cpu().numpy()
    if device == "mps":
        torch.mps.empty_cache()  # long runs otherwise exhaust GPU memory

    os.makedirs(out_dir, exist_ok=True)
    result = {"type": "stems", "path": path, "ok": True, "stems": {}}
    for i, name in enumerate(_MODEL.sources):
        if name not in STEMS:
            continue
        f = os.path.join(out_dir, f"{name}.flac")
        sf.write(f, sources[i].T, SR, subtype="PCM_16")
        result["stems"][name] = f

    result["beatsVersion"] = CACHE_VERSION
    # How much singing there is on each beat (0..1), using the analysed grid.
    vocals = sources[list(_MODEL.sources).index("vocals")].mean(0)
    full = audio.mean(1)
    analysis = analyze_file(path)
    if analysis.get("ok"):
        beats = analysis["beats"]
        v_rms, f_rms = [], []
        for a, b in zip(beats[:-1], beats[1:]):
            i0, i1 = int(a * SR), int(b * SR)
            v_rms.append(float(np.sqrt(np.mean(vocals[i0:i1] ** 2))) if i1 > i0 else 0.0)
            f_rms.append(float(np.sqrt(np.mean(full[i0:i1] ** 2))) if i1 > i0 else 0.0)
        v = np.asarray(v_rms)
        top = np.percentile(v, 95) + 1e-9
        result["vocalBeats"] = np.clip(v / top, 0, 1).round(3).tolist()
        # Share of the song's level that is vocals: tells real vocal songs from instrumentals.
        result["vocalShare"] = round(float(np.median(v / (np.asarray(f_rms) + 1e-9))), 3)
    result["tuning"] = _stem_tuning(result["stems"])
    result["levels"] = _stem_levels(result["stems"])
    result.update(_grid_check(path, result["stems"]))
    result["chroma"] = _stem_chroma(result["stems"])
    result["curves"] = _stem_curves(result["stems"])
    with open(meta_path, "w") as fh:
        json.dump(result, fh)
    return result


def _vocal_beats(path, stems):
    """Singing level per analysed beat, recomputed from the saved vocal stem."""
    import numpy as np
    import soundfile as sf
    out = {}
    analysis = analyze_file(path)
    if not analysis.get("ok"):
        return out
    v, _ = sf.read(stems["vocals"], dtype="float32")
    v = v.mean(1) if v.ndim > 1 else v
    beats = analysis["beats"]
    rms = []
    for a, b in zip(beats[:-1], beats[1:]):
        i0, i1 = int(a * SR), int(b * SR)
        rms.append(float(np.sqrt(np.mean(v[i0:i1] ** 2))) if i1 > i0 else 0.0)
    r = np.asarray(rms)
    out["vocalBeats"] = np.clip(r / (np.percentile(r, 95) + 1e-9), 0, 1).round(3).tolist()
    return out


def _grid_check(path, stems):
    """Where the drums really hit relative to the analysed beats: the median
    offset of the strong hits (seconds, negative = drums early), and the share
    of them within 25 ms of the grid (how tight the drumming is)."""
    import numpy as np
    import soundfile as sf
    analysis = analyze_file(path)
    beats = np.asarray(analysis.get("beats") or []) if analysis.get("ok") else np.asarray([])
    if len(beats) < 32 or "drums" not in stems:
        return {"gridOffset": 0.0, "gridTight": 1.0}
    x, sr = sf.read(stems["drums"], dtype="float32")
    if x.ndim > 1:
        x = x.mean(1)
    hop = 64
    n = len(x) // hop
    frames = x[: n * hop].reshape(n, hop)
    energy = np.log1p(1000 * (np.diff(frames, axis=1) ** 2).sum(1))
    flux = np.maximum(0, np.diff(energy, prepend=energy[0]))
    fps = sr / hop
    w = int(0.09 * fps)
    offs, strength = [], []
    for b in beats:
        c = int(b * fps)
        if c - w < 0 or c + w >= len(flux):
            continue
        seg = flux[c - w : c + w + 1]
        if seg.max() <= 0:
            continue
        offs.append((seg.argmax() - w) / fps)
        strength.append(seg.max())
    if len(offs) < 16:
        return {"gridOffset": 0.0, "gridTight": 1.0}
    offs, strength = np.asarray(offs), np.asarray(strength)
    strong = offs[strength > np.median(strength)]
    offset = float(np.clip(np.median(strong), -0.03, 0.03))
    tight = float(np.mean(np.abs(strong) < 0.025))
    return {"gridOffset": round(offset, 4), "gridTight": round(tight, 3), "beatShift": _beat_shift(beats, flux, fps, w)}


def _beat_shift(beats, flux, fps, w):
    """Where the drums really hit, beat by beat: [time, offset] pairs, each
    the median offset of the strong hits within 8 beats either side. A band
    (or the beat tracker) that drifts partway through a song stays pinned to
    its own drums, not just to the song's overall offset."""
    import numpy as np
    floor = np.median(flux[flux > 0]) * 3 if np.any(flux > 0) else 0
    offs = np.full(len(beats), np.nan)
    for i, b in enumerate(beats):
        c = int(b * fps)
        if c - w < 0 or c + w >= len(flux):
            continue
        seg = flux[c - w : c + w + 1]
        if seg.max() > floor:
            offs[i] = (seg.argmax() - w) / fps
    out = []
    for i, b in enumerate(beats):
        near = offs[max(0, i - 8) : i + 9]
        near = near[~np.isnan(near)]
        if len(near) >= 6:
            out.append([round(float(b), 3), round(float(np.clip(np.median(near), -0.08, 0.08)), 4)])
    return out


def _stem_chroma(stems):
    """Which notes the song really uses: the share of each of the 12 pitch
    classes (C first) in the singing (loudest half of the vocal, i.e. while
    singing) and in the music (bass and other), from a harmonic pitch class
    profile. Pairs are key-matched on these real notes: the key label of the
    whole song is wrong often enough (relative and related keys get mixed up)
    that about one in five label-approved pairs clashed."""
    import numpy as np
    sr = 22050

    def profile(paths, sung_only):
        tot = np.zeros(12)
        for p in paths:
            x = load_audio(p, sr=sr)
            r, e = _pcp_frames(x, sr, harmonics=8, fmin=60, fmax=3500, thresh=1e-5, maxn=60, window="bh62")
            if not len(r):
                continue
            r = r / np.maximum(r.sum(1, keepdims=True), 1e-12)  # each frame sums to 1
            if sung_only:
                r = r[e > np.percentile(e, 50)]
            tot += r.sum(0)
        t = tot / (tot.sum() or 1)
        return np.roll(t, 9).round(4).tolist()  # HPCP starts on A; C first

    try:
        return {"vocals": profile([stems["vocals"]], True), "music": profile([stems["bass"], stems["other"]], False)}
    except Exception:
        return {}


def _stem_levels(stems):
    """How loud the singing is (while singing) and how loud the instrumental
    (drums + bass + other) is, in dB, so vocals can sit at the right level
    over someone else's beat."""
    import numpy as np
    import soundfile as sf
    out = {}
    try:
        def load(name):
            x, _ = sf.read(stems[name], dtype="float32")
            return x.mean(1) if x.ndim > 1 else x
        hop = 4410  # 0.1 s blocks
        def block_rms(x):
            n = len(x) // hop
            return np.sqrt(np.mean(x[: n * hop].reshape(n, hop) ** 2, axis=1) + 1e-12)
        v = block_rms(load("vocals"))
        inst = block_rms(load("drums") + load("bass") + load("other"))
        n = min(len(v), len(inst))
        v, inst = v[:n], inst[:n]
        singing = v > np.percentile(v, 95) * 0.25  # blocks where someone is singing
        if singing.sum() > 20:
            out["vocals"] = round(float(20 * np.log10(np.mean(v[singing]))), 2)
        loud = inst > np.percentile(inst, 90) * 0.2
        if loud.sum() > 20:
            out["instrumental"] = round(float(20 * np.log10(np.mean(inst[loud]))), 2)
    except Exception:
        pass
    return out


def _stem_curves(stems):
    """Level of the drums, the bass and the whole instrumental every half
    second (dB), so a beat can be taken from where its drums and bass keep
    playing, and sections can be matched for loudness. The instrumental is
    weighted like the ear hears it (K-weighting: quiet below 40 Hz, a lift
    above 1.5 kHz), so a bass-heavy beat doesn't measure louder than it sounds."""
    import numpy as np
    import soundfile as sf
    out = {"hop": 0.5}
    try:
        def load(name):
            x, sr = sf.read(stems[name], dtype="float32")
            return (x.mean(1) if x.ndim > 1 else x), sr
        drums, sr = load("drums")
        bass, _ = load("bass")
        other, _ = load("other")
        n = int(sr * out["hop"])
        k = min(len(drums), len(bass), len(other)) // n
        def db(x):
            return np.round(10 * np.log10(np.mean(x[: k * n].reshape(k, n) ** 2, axis=1) + 1e-10), 1)
        out["drums"] = db(drums).tolist()
        out["bass"] = db(bass).tolist()
        blocks = (drums[: k * n] + bass[: k * n] + other[: k * n]).reshape(k, n)
        f = np.fft.rfftfreq(n, 1 / sr)
        shelf = 10 ** (4 / (1 + (1500 / np.maximum(f, 1)) ** 2) / 10)  # +4 dB (power) above ~1.5 kHz
        hp = f ** 4 / (f ** 4 + 38.0 ** 4)
        w = shelf * hp
        power = (np.abs(np.fft.rfft(blocks, axis=1)) ** 2 * w).sum(1) * 2 / (n * n)
        out["inst"] = np.round(10 * np.log10(power + 1e-10), 1).tolist()
    except Exception:
        pass
    return out


def _stem_tuning(stems):
    """Concert-pitch reference (Hz, 440 = standard) of the singer and of the
    melody, so a vocal can be nudged by cents to sit in tune with a beat."""
    import numpy as np
    import soundfile as sf
    out = {}
    for name in ("vocals", "other"):
        try:
            x, sr = sf.read(stems[name], dtype="float32")
            x = x.mean(1) if x.ndim > 1 else x
            loud = x[np.abs(x) > 0.02]  # skip silence
            if len(loud) < sr * 5:
                continue
            out[name] = round(_tuning(np.ascontiguousarray(x), sr), 2)
        except Exception:
            pass
    return out


def cmd_separate(paths):
    # One model on the GPU, songs one after another.
    for p in paths:
        try:
            emit(separate_file(p))
        except Exception as e:
            emit({"type": "stems", "path": p, "ok": False, "error": str(e)})
    emit({"type": "done"})


_ROF = None


def _mel_roformer():
    """The Mel-Band RoFormer vocal model, inference only: (model, demix). A
    cleaner vocal than Demucs (less of the "watery" sound). Trimmed from Kimberley
    Jensen's Mel-Band-Roformer-Vocal-Model, itself from lucidrains' BS-RoFormer
    (both MIT; (c) Kimberley Jensen, Phil Wang). The weights load in safe mode."""
    global _ROF
    if _ROF is not None:
        return _ROF
    import numpy as np
    import torch
    from torch import nn
    import torch.nn.functional as F
    from einops import rearrange, pack, unpack, repeat, reduce
    from huggingface_hub import hf_hub_download
    from rotary_embedding_torch import RotaryEmbedding

    def _hz2mel(f):
        f = np.asanyarray(f, dtype=np.float64); sp = 200.0 / 3
        return np.where(f >= 1000, 1000 / sp + np.log(np.maximum(f, 1e-9) / 1000) / (np.log(6.4) / 27), f / sp)
    def _mel2hz(m):
        m = np.asanyarray(m, dtype=np.float64); sp = 200.0 / 3; b = 1000 / sp
        return np.where(m >= b, 1000 * np.exp((m - b) * (np.log(6.4) / 27)), m * sp)
    def mel_bank(sr, n_fft, n_mels):
        fft = np.fft.rfftfreq(n_fft, 1 / sr)
        mel = _mel2hz(np.linspace(_hz2mel(0.0), _hz2mel(sr / 2), n_mels + 2))
        d = np.diff(mel); ramps = np.subtract.outer(mel, fft)
        w = np.zeros((n_mels, len(fft)), np.float32)
        for i in range(n_mels):
            w[i] = np.maximum(0, np.minimum(-ramps[i] / d[i], ramps[i + 2] / d[i + 1]))
        return w * (2.0 / (mel[2:] - mel[:-2]))[:, None].astype(np.float32)

    class RMSNorm(nn.Module):
        def __init__(s, dim):
            super().__init__(); s.scale = dim ** 0.5; s.gamma = nn.Parameter(torch.ones(dim))
        def forward(s, x): return F.normalize(x, dim=-1) * s.scale * s.gamma
    class FeedForward(nn.Module):
        def __init__(s, dim, mult=4):
            super().__init__(); i = dim * mult
            s.net = nn.Sequential(RMSNorm(dim), nn.Linear(dim, i), nn.GELU(), nn.Dropout(0.), nn.Linear(i, dim), nn.Dropout(0.))
        def forward(s, x): return s.net(x)
    class Attention(nn.Module):
        def __init__(s, dim, heads, dim_head, rotary):
            super().__init__(); s.heads = heads; i = heads * dim_head; s.rotary_embed = rotary
            s.norm = RMSNorm(dim); s.to_qkv = nn.Linear(dim, i * 3, bias=False); s.to_gates = nn.Linear(dim, heads)
            s.to_out = nn.Sequential(nn.Linear(i, dim, bias=False), nn.Dropout(0.))
        def forward(s, x):
            x = s.norm(x)
            q, k, v = rearrange(s.to_qkv(x), 'b n (qkv h d) -> qkv b h n d', qkv=3, h=s.heads)
            q = s.rotary_embed.rotate_queries_or_keys(q); k = s.rotary_embed.rotate_queries_or_keys(k)
            out = F.scaled_dot_product_attention(q, k, v)
            out = out * rearrange(s.to_gates(x), 'b n h -> b h n 1').sigmoid()
            return s.to_out(rearrange(out, 'b h n d -> b n (h d)'))
    class Transformer(nn.Module):
        def __init__(s, dim, depth, heads, dim_head, rotary):
            super().__init__()
            s.layers = nn.ModuleList([nn.ModuleList([Attention(dim, heads, dim_head, rotary), FeedForward(dim)]) for _ in range(depth)])
            s.norm = RMSNorm(dim)
        def forward(s, x):
            for a, f in s.layers:
                x = a(x) + x; x = f(x) + x
            return s.norm(x)
    class BandSplit(nn.Module):
        def __init__(s, dim, ins):
            super().__init__(); s.dim_inputs = ins
            s.to_features = nn.ModuleList([nn.Sequential(RMSNorm(d), nn.Linear(d, dim)) for d in ins])
        def forward(s, x):
            return torch.stack([f(p) for p, f in zip(x.split(s.dim_inputs, dim=-1), s.to_features)], dim=-2)
    def _mlp(i, o, h, depth):
        dims = (i, *((h,) * depth), o); net = []
        for n, (a, b) in enumerate(zip(dims[:-1], dims[1:])):
            net.append(nn.Linear(a, b))
            if n < len(dims) - 2: net.append(nn.Tanh())
        return nn.Sequential(*net)
    class MaskEstimator(nn.Module):
        def __init__(s, dim, ins, depth):
            super().__init__()
            s.to_freqs = nn.ModuleList([nn.Sequential(_mlp(dim, d * 2, dim * 4, depth), nn.GLU(dim=-1)) for d in ins])
        def forward(s, x):
            return torch.cat([m(b) for b, m in zip(x.unbind(dim=-2), s.to_freqs)], dim=-1)
    class MelBandRoformer(nn.Module):
        def __init__(s, dim=384, depth=6, heads=8, dim_head=64, bands=60, sr=44100, n_fft=2048, hop=441):
            super().__init__()
            tr, fr = RotaryEmbedding(dim=dim_head), RotaryEmbedding(dim=dim_head)
            s.layers = nn.ModuleList([nn.ModuleList([Transformer(dim, 1, heads, dim_head, tr), Transformer(dim, 1, heads, dim_head, fr)]) for _ in range(depth)])
            s.n_fft, s.hop = n_fft, hop
            b = torch.from_numpy(mel_bank(sr, n_fft, bands)); b[0][0] = 1.; b[-1, -1] = 1.
            fpb = b > 0; assert fpb.any(dim=0).all()
            idx = repeat(torch.arange(n_fft // 2 + 1), 'f -> b f', b=bands)[fpb]
            idx = rearrange(repeat(idx, 'f -> f s', s=2) * 2 + torch.arange(2), 'f s -> (f s)')
            s.register_buffer('freq_indices', idx, persistent=False)
            s.register_buffer('num_bands_per_freq', reduce(fpb, 'b f -> f', 'sum'), persistent=False)
            ins = tuple(2 * f * 2 for f in reduce(fpb, 'b f -> b', 'sum').tolist())
            s.band_split = BandSplit(dim, ins)
            s.mask_estimators = nn.ModuleList([MaskEstimator(dim, ins, 2)])
        def forward(s, audio):
            # The STFT and complex masking run on the CPU (MPS lacks some complex ops); the network on the GPU.
            dev = next(s.parameters()).device; n = audio.shape[-1]; b = audio.shape[0]
            win = torch.hann_window(s.n_fft); kw = dict(n_fft=s.n_fft, hop_length=s.hop, win_length=s.n_fft)
            spec = torch.stft(rearrange(audio.cpu(), 'b s t -> (b s) t'), **kw, window=win, return_complex=True)
            re = rearrange(torch.view_as_real(spec), '(b s) f t c -> b (f s) t c', s=2)
            idx = s.freq_indices.cpu()
            x = rearrange(re[torch.arange(b)[..., None], idx].to(dev), 'b f t c -> b t (f c)')
            x = s.band_split(x)
            for tt, ft in s.layers:
                x = rearrange(x, 'b t f d -> b f t d'); x, ps = pack([x], '* t d'); x = tt(x); x, = unpack(x, ps, '* t d')
                x = rearrange(x, 'b f t d -> b t f d'); x, ps = pack([x], '* f d'); x = ft(x); x, = unpack(x, ps, '* f d')
            m = rearrange(s.mask_estimators[0](x), 'b t (f c) -> b f t c', c=2).cpu()
            c = torch.view_as_complex(re); m = torch.view_as_complex(m.contiguous()).type(c.dtype)
            si = repeat(idx, 'f -> b f t', b=b, t=c.shape[-1])
            summed = torch.zeros_like(c).scatter_add_(1, si, m)
            den = repeat(s.num_bands_per_freq.cpu(), 'f -> (f r) 1', r=2)
            c = c * (summed / den.clamp(min=1e-8))
            out = torch.istft(rearrange(c, 'b (f s) t -> (b s) f t', s=2), **kw, window=win, length=n)
            return rearrange(out, '(b s) t -> b s t', s=2)

    def demix(model, mix, chunk=352800, overlap=2, batch=1):
        """Vocals of a stereo float tensor [2, n]: overlapping chunks, cross-faded."""
        C, step, fade = chunk, int(chunk / overlap), chunk // 10; border = C - step
        long = mix.shape[1] > 2 * border
        if long: mix = F.pad(mix, (border, border), mode='reflect')
        w = torch.ones(C); w[-fade:] *= torch.linspace(1, 0, fade); w[:fade] *= torch.linspace(0, 1, fade)
        res = torch.zeros_like(mix); cnt = torch.zeros_like(mix); dev = next(model.parameters()).device; n = mix.shape[1]
        with torch.no_grad():
            for i in range(0, n, step):
                part = mix[:, i:i + C]; L = part.shape[-1]
                if L < C:
                    part = F.pad(part, (0, C - L), mode='reflect') if L > C // 2 + 1 else F.pad(part, (0, C - L))
                x = model(part[None].to(dev))[0].cpu()
                win = w.clone()
                if i == 0: win[:fade] = 1
                elif i + C >= n: win[-fade:] = 1
                res[..., i:i + L] += x[..., :L] * win[:L]; cnt[..., i:i + L] += win[:L]
        out = torch.nan_to_num(res / cnt)
        return out[..., border:-border] if long else out

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    ckpt = hf_hub_download("KimberleyJSN/melbandroformer", "MelBandRoformer.ckpt", local_files_only=True)
    model = MelBandRoformer()
    model.load_state_dict(torch.load(ckpt, map_location="cpu", weights_only=True))
    _ROF = (model.to(device).eval(), demix)
    return _ROF


def _clean_vocal(stem_path, a, b):
    """The vocal of samples a..b of a song, from the RoFormer model. Sample-aligned
    with (and as loud as) its Demucs vocal stem, whose folder says which song it is."""
    import numpy as np
    import torch
    with open(os.path.join(os.path.dirname(stem_path), "stems.json")) as fh:
        path = json.load(fh)["path"]
    audio = load_audio(path, mono=False)  # decoded as when the stems were split
    model, demix = _mel_roformer()
    pad = 2 * SR  # context either side, so the first and last notes are judged in full
    a0, b0 = max(0, a - pad), min(len(audio), b + pad)
    wav = torch.tensor(np.ascontiguousarray(audio[a0:b0].T), dtype=torch.float32)
    if torch.backends.mps.is_available():
        # (16-bit maths and less overlap: a third of the time, the same clarity.)
        with torch.autocast("mps", dtype=torch.float16):
            y = demix(model, wav, overlap=1.25)
        torch.mps.empty_cache()
    else:
        y = demix(model, wav, overlap=1.25)
    y = y.float().numpy().T[a - a0 : b - a0]
    return np.pad(y, ((0, max(0, b - a - len(y))), (0, 0)))


def prestretch(job):
    """One vocal (or beat: its stems summed), made studio-clean ahead of time
    with Signalsmith Stretch: stretched so each beat lands where the beat map
    says (measured within about 1 ms), and tuned, keeping the singer's
    formants. Job: {input, warp: [[mixTime, songTime], ...], cents, out}. The
    output starts at warp[0]'s mix time and plays at normal speed with no
    further processing."""
    import numpy as np
    import soundfile as sf
    warp = job["warp"]
    x, sr = sf.read(job["input"], dtype="float32", always_2d=True)
    for extra in job.get("mix", []):  # a beat's other stems, summed into one
        e, _ = sf.read(extra, dtype="float32", always_2d=True)
        if len(e) > len(x):
            x = np.pad(x, ((0, len(e) - len(x)), (0, 0)))
        x[: len(e)] += e
    s0, s1 = warp[0][1], warp[-1][1]
    pad = max(0, int(round(-s0 * sr)))  # the map starts before the song: silence
    a, b = max(0, int(round(s0 * sr))), min(len(x), int(round(s1 * sr)))
    body = _clean_vocal(job["input"], a, b) if job.get("clean") else x[a:b]
    seg = np.concatenate([np.zeros((pad, x.shape[1]), np.float32), body])
    # The time map, in samples: mix time from the first point -> song time
    # from s0 (seg starts at s0). Points that don't move forward are dropped.
    m0 = warp[0][0]
    mo, mi = [], []
    for m, t in warp:
        o, i = (m - m0) * sr, (t - s0) * sr
        if not mo or (o > mo[-1] and i > mi[-1]):
            mo.append(o)
            mi.append(i)
    # A beat (stems summed) skips the voice-only formant keeping, is saved
    # 6 dB down so the sum can't clip (the player adds it back), and in 16 bits
    # like its stems (half the disk space).
    beat = bool(job.get("beat"))
    want = int(round((warp[-1][0] - warp[0][0]) * sr))
    y = _stretch(seg.T, sr, mo, mi, want, job["cents"] / 100.0, keep_formants=not beat)
    # Pitch shifting with formants kept can change the level a little: keep
    # it as loud as it went in, so the vocal levels worked out earlier hold.
    rin, rout = float(np.sqrt(np.mean(seg ** 2))), float(np.sqrt(np.mean(y ** 2)))
    if rin > 1e-6 and rout > 1e-6:
        y = y * float(np.clip(rin / rout, 0.5, 2.0))
    os.makedirs(os.path.dirname(job["out"]), exist_ok=True)
    tmp = job["out"] + ".part.flac"
    if beat:
        y = y * 0.5
    sf.write(tmp, y.T, sr, subtype="PCM_16" if beat else "PCM_24")
    os.replace(tmp, job["out"])
    return {"type": "prestretch", "out": job["out"], "ok": True, "seconds": want / sr}


def cmd_prestretch(job_files):
    for f in job_files:
        try:
            with open(f) as fh:
                job = json.load(fh)
            emit(prestretch(job))
        except Exception as e:
            emit({"type": "prestretch", "job": f, "ok": False, "error": str(e)})
        finally:
            try:
                os.remove(f)
            except OSError:
                pass
    emit({"type": "done"})


def _model_status():
    """Which AI models are on this Mac yet: [(name, size_mb, have)]."""
    import torch.hub
    hub = os.path.join(torch.hub.get_dir(), "checkpoints")
    from huggingface_hub import try_to_load_from_cache
    rof = try_to_load_from_cache("KimberleyJSN/melbandroformer", "MelBandRoformer.ckpt")
    return [
        ("beats", 81, os.path.exists(os.path.join(hub, "beat_this-final0.ckpt"))),
        ("stems", 84, all(isinstance(f, str) and os.path.exists(f) for f in (
            try_to_load_from_cache("adefossez/HTDemucs", "htdemucs.yaml"),
            try_to_load_from_cache("adefossez/HTDemucs", "955717e8.safetensors")))),
        ("vocals", 913, isinstance(rof, str) and os.path.exists(rof)),
    ]


def cmd_models(fetch):
    """Reports the AI models this Mac has, and with fetch downloads the missing
    ones (about 1 GB the first time; they're kept in the usual model caches)."""
    import warnings
    warnings.filterwarnings("ignore")
    status = _model_status()
    missing = [(n, mb) for n, mb, have in status if not have]
    emit({"type": "models", "missing": [n for n, _ in missing], "mb": sum(mb for _, mb in missing)})
    if not fetch:
        emit({"type": "done"})
        return
    for name, mb in missing:
        emit({"type": "model", "name": name, "mb": mb, "state": "start"})
        try:
            if name == "beats":
                import torch
                from beat_this.inference import Audio2Beats
                Audio2Beats(checkpoint_path="final0", device="cpu", dbn=False)
            elif name == "stems":
                from demucs.pretrained import get_model
                get_model("htdemucs")
            else:
                from huggingface_hub import hf_hub_download
                hf_hub_download("KimberleyJSN/melbandroformer", "MelBandRoformer.ckpt")
        except Exception as e:
            emit({"type": "error", "name": name, "message": str(e)})
            sys.exit(1)
        emit({"type": "model", "name": name, "mb": mb, "state": "done"})
    emit({"type": "done"})


def _expand_args(args):
    """The app hands over very long song lists as one "@file" (a JSON list),
    because macOS limits how much can go on a command line."""
    if len(args) == 1 and args[0].startswith("@"):
        with open(args[0][1:], encoding="utf-8") as fh:
            return json.load(fh)
    return args


if __name__ == "__main__":
    _guard()
    if len(sys.argv) >= 3 and sys.argv[1] == "tags":
        cmd_tags(_expand_args(sys.argv[2:]))
    elif len(sys.argv) >= 3 and sys.argv[1] == "known":
        cmd_known(_expand_args(sys.argv[2:]))
    elif len(sys.argv) >= 3 and sys.argv[1] == "analyze":
        cmd_analyze(_expand_args(sys.argv[2:]))
    elif len(sys.argv) >= 3 and sys.argv[1] == "meter":
        cmd_meter(_expand_args(sys.argv[2:]))
    elif len(sys.argv) >= 3 and sys.argv[1] == "separate":
        cmd_separate(_expand_args(sys.argv[2:]))
    elif len(sys.argv) >= 3 and sys.argv[1] == "prestretch":
        cmd_prestretch(_expand_args(sys.argv[2:]))
    elif len(sys.argv) >= 2 and sys.argv[1] in ("models", "getmodels"):
        cmd_models(sys.argv[1] == "getmodels")
    else:
        print(__doc__)
        sys.exit(1)
