"""Vibeline music analyser.

Commands (results are printed as one JSON object per line):
  tags <folder> ...    fast scan: title / artist / genre / year / duration for every audio file
  analyze <file> ...   tempo, beat grid, bar phase, key, energy and waveform (cached)
  separate <file> ...  split into vocals / drums / bass / other stems with Demucs (cached)
"""
import json
import os
import sys
import hashlib
from concurrent.futures import ProcessPoolExecutor, as_completed

AUDIO_EXT = {".mp3", ".m4a", ".aac", ".wav", ".aiff", ".aif", ".flac"}
CACHE_DIR = os.path.expanduser("~/Library/Caches/Vibeline/analysis")
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
    if app <= 0:
        return

    def watch():
        while True:
            time.sleep(2)
            try:
                os.kill(app, 0)
            except OSError:
                os._exit(0)

    threading.Thread(target=watch, daemon=True).start()


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


# ---------------------------------------------------------------- tags

def _first(tags, *names):
    for n in names:
        v = tags.get(n)
        if v:
            v = v[0] if isinstance(v, list) else v
            return str(v).strip()
    return ""


def read_tags(path):
    import mutagen
    info = {"path": path, "title": "", "artist": "", "genre": "", "year": 0, "duration": 0.0}
    try:
        f = mutagen.File(path, easy=True)
        if f is not None:
            info["duration"] = float(getattr(f.info, "length", 0.0) or 0.0)
            tags = f.tags or {}
            info["title"] = _first(tags, "title")
            info["artist"] = _first(tags, "artist", "albumartist")
            info["genre"] = _first(tags, "genre")
            date = _first(tags, "date", "originaldate")
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


def cmd_tags(folders):
    seen = set()
    for folder in folders:
        _scan(folder, seen)
    emit({"type": "done"})


def _scan(folder, seen):
    for root, _, files in os.walk(folder):
        for name in sorted(files):
            if name.startswith("."):
                continue
            path = os.path.join(root, name)
            if os.path.splitext(name)[1].lower() in AUDIO_EXT and path not in seen:
                seen.add(path)
                emit({"type": "tags", **read_tags(path)})


# ---------------------------------------------------------------- analysis

def _cache_path(path):
    st = os.stat(path)
    h = hashlib.sha1(f"{path}|{st.st_size}|{int(st.st_mtime)}|{CACHE_VERSION}".encode()).hexdigest()
    return os.path.join(CACHE_DIR, h + ".json")


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
    import essentia.standard as es
    hop = 64
    w, fft, c2p = es.Windowing(type="hann"), es.FFT(), es.CartesianToPolar()
    od = es.OnsetDetection(method="flux")
    env = np.array([od(*c2p(fft(w(fr)))) for fr in es.FrameGenerator(audio, frameSize=1024, hopSize=hop, startFromZero=True)])
    env = np.maximum(env - np.convolve(env, np.ones(61) / 61, "same"), 0)
    b = np.asarray(beats)
    base = ((b * SR - 512) / hop).astype(int)
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


def _beat_this(paths):
    """Beats and downbeats from Beat This! (a modern AI beat tracker), run in
    this process on the GPU. The older tracker got the start of the bar wrong
    on about half of songs, which put vocal lines on the wrong beat."""
    out = {}
    if not paths:
        return out
    try:
        import warnings
        warnings.filterwarnings("ignore")
        import torch
        from beat_this.inference import File2Beats
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        f2b = File2Beats(checkpoint_path="final0", device=device, dbn=False)
    except Exception:
        return out
    for p in paths:
        try:
            beats, downs = f2b(p)
            out[p] = ([float(x) for x in beats], [float(x) for x in downs])
        except Exception:
            pass
    return out


def analyze_file(path, bt=None):
    cache = _cache_path(path)
    if os.path.exists(cache):
        with open(cache) as fh:
            return json.load(fh)
    if bt is None:
        bt = _beat_this([path]).get(path)

    import numpy as np
    import essentia
    import essentia.standard as es
    essentia.log.warningActive = False
    essentia.log.infoActive = False

    audio = es.MonoLoader(filename=path, sampleRate=SR)()
    duration = len(audio) / SR
    result = {"type": "analysis", "path": path, "duration": duration, "ok": False}
    # Level, tuning and waveform are useful even for sounds with no beat
    # (rain, fire, ambient pads) so they can be used as samples.
    result["loudnessDb"] = round(float(20 * np.log10(np.sqrt(np.mean(audio ** 2)) + 1e-9)), 2)
    try:
        result["tuning"] = round(float(np.median(es.TuningFrequencyExtractor(frameSize=4096, hopSize=4096)(audio))), 2)
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
    else:
        _, ticks, confidence, _, _ = es.RhythmExtractor2013(method="multifeature")(audio)
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
    lp = es.LowPass(cutoffFrequency=150, sampleRate=SR)(audio)
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

    key, scale, key_strength = es.KeyExtractor(profileType="edma", sampleRate=SR)(audio)
    key = _ENHARMONIC.get(key, key)
    camelot = _CAMELOT.get((key, scale), "")

    rms_db = float(20 * np.log10(np.sqrt(np.mean(audio ** 2)) + 1e-9))
    # Concert pitch the recording sits at (Hz, within half a semitone of 440).
    tuning = float(np.median(es.TuningFrequencyExtractor(frameSize=4096, hopSize=4096)(audio)))
    danceability, _ = es.Danceability(sampleRate=SR)(audio)

    # Small waveform for the timeline card.
    n_peaks = 160
    hop = max(1, len(audio) // n_peaks)
    peaks = [float(np.abs(audio[i * hop:(i + 1) * hop]).max()) for i in range(n_peaks)]
    pmax = max(peaks) or 1.0
    waveform = [round(p / pmax, 3) for p in peaks]

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
        "loudnessDb": round(rms_db, 2),
        "tuning": round(tuning, 2),
        "danceability": round(float(danceability), 3),
        "waveform": waveform,
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


def cmd_analyze(paths):
    # Leave cores free for the app and the music.
    workers = max(1, min(4, (os.cpu_count() or 4) // 2))
    misses = [p for p in paths if not os.path.exists(_cache_path(p))]
    bts = _beat_this(misses)
    with ProcessPoolExecutor(max_workers=workers, initializer=_guard) as pool:
        futures = {pool.submit(_safe_analyze, p, bts.get(p)): p for p in paths}
        for fut in as_completed(futures):
            emit(fut.result())
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
        if "gridTight" not in meta:  # stems made before the grid was checked
            meta.update(_grid_check(path, meta["stems"]))
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
    import essentia
    import essentia.standard as es
    from demucs.pretrained import get_model
    from demucs.apply import apply_model
    essentia.log.warningActive = False
    essentia.log.infoActive = False

    global _MODEL
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    if _MODEL is None:
        _MODEL = get_model("htdemucs")
        _MODEL.to(device).eval()

    audio, sr, channels, *_ = es.AudioLoader(filename=path)()
    if sr != SR:
        audio = np.stack([es.Resample(inputSampleRate=sr, outputSampleRate=SR)(audio[:, c].copy()) for c in range(2)], 1)
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
    return {"gridOffset": round(offset, 4), "gridTight": round(tight, 3)}


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
    import essentia
    import essentia.standard as es
    essentia.log.warningActive = False
    out = {}
    for name in ("vocals", "other"):
        try:
            x, sr = sf.read(stems[name], dtype="float32")
            x = x.mean(1) if x.ndim > 1 else x
            loud = x[np.abs(x) > 0.02]  # skip silence
            if len(loud) < sr * 5:
                continue
            tf = es.TuningFrequencyExtractor(frameSize=4096, hopSize=4096)(np.ascontiguousarray(x))
            out[name] = round(float(np.median(tf)), 2)
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


if __name__ == "__main__":
    _guard()
    if len(sys.argv) >= 3 and sys.argv[1] == "tags":
        cmd_tags(sys.argv[2:])
    elif len(sys.argv) >= 3 and sys.argv[1] == "analyze":
        cmd_analyze(sys.argv[2:])
    elif len(sys.argv) >= 3 and sys.argv[1] == "separate":
        cmd_separate(sys.argv[2:])
    else:
        print(__doc__)
        sys.exit(1)
