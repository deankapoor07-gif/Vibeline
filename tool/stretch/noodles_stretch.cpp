// Time-stretch and pitch-shift for D-Jay Noodles' prestretch step, built on
// Signalsmith Stretch (MIT, third_party/). Called from assets/vibeline_ai.py
// through ctypes. Build: tool/stretch/build.sh
//
// The input follows a time map: output sample o plays input position
// map_in(o), linear between map points, so every beat lands where the beat
// map says however the speed changes from beat to beat.
#include "signalsmith-stretch/signalsmith-stretch.h"
#include <algorithm>
#include <cmath>
#include <vector>

using Stretch = signalsmith::stretch::SignalsmithStretch<float>;

namespace {
struct InChan {
	const float *p; long off, len;
	float operator[](int i) const { long j = off + i; return (j >= 0 && j < len) ? p[j] : 0.0f; }
};
struct In {
	const float *const *p; long off, len;
	InChan operator[](int c) const { return {p[c], off, len}; }
};
struct OutChan {
	float *p; long off;
	float &operator[](int i) const { return p[off + i]; }
};
struct Out {
	float *const *p; long off;
	OutChan operator[](int c) const { return {p[c], off}; }
};

struct Map {
	const double *o, *i; int n;
	double at(double x) const {  // input position for output position x
		if (n == 1 || x <= o[0]) return i[0] + (n > 1 ? (x - o[0]) * (i[1] - i[0]) / std::max(1e-9, o[1] - o[0]) : x - o[0]);
		if (x >= o[n - 1]) return i[n - 1] + (x - o[n - 1]) * (i[n - 1] - i[n - 2]) / std::max(1e-9, o[n - 1] - o[n - 2]);
		int k = int(std::upper_bound(o, o + n, x) - o) - 1;
		return i[k] + (x - o[k]) * (i[k + 1] - i[k]) / std::max(1e-9, o[k + 1] - o[k]);
	}
};
}  // namespace

extern "C" {

// Returns 0 on success. in/out are planar (one pointer per channel).
int noodles_stretch(const float *const *in, int channels, long in_len, double sample_rate,
                    const double *map_out, const double *map_in, int map_n,
                    double semitones, int keep_formants, double tonality_hz,
                    float *const *out, long out_len) {
	if (channels < 1 || map_n < 1 || out_len < 1) return 1;
	Stretch s;
	s.presetDefault(channels, float(sample_rate));
	s.setTransposeSemitones(float(semitones), float(tonality_hz / sample_rate));
	if (keep_formants) {
		s.setFormantFactor(1.0f, true);
		s.setFormantBase(float(100.0 / sample_rate));
	}
	Map m{map_out, map_in, map_n};
	double rate0 = (m.at(4096.0) - m.at(0.0)) / 4096.0;
	rate0 = std::max(0.25, std::min(4.0, rate0));
	long pos0 = long(std::lround(m.at(0.0)));
	int seekLen = s.outputSeekLength(float(rate0));
	// After the seek (input pos0 .. pos0+seekLen), the next output sample is input pos0.
	long fed = pos0 + seekLen;
	s.outputSeek(In{in, pos0, in_len}, seekLen);
	long end = std::max(0L, out_len - long(s.intervalSamples()));
	const long block = 256;
	for (long o = 0; o < end;) {
		long next = std::min(end, o + block);
		// As in Signalsmith's own example: the stretcher's internal output
		// position is outputLatency ahead of what it hands back, and it needs
		// input up to inputLatency past the matching input position.
		double inPos = m.at(double(next + s.outputLatency()));
		long want = long(std::lround(inPos)) + s.inputLatency();
		long feed = std::max(0L, want - fed);
		s.process(In{in, fed, in_len}, int(feed), Out{out, o}, int(next - o));
		fed += feed;
		o = next;
	}
	s.flush(Out{out, end}, int(out_len - end));
	return 0;
}

}
