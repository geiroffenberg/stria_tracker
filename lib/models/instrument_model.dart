// Instrument data model.
//
// The app supports several instrument *types* (sampler, simple synth, …).
// Each instrument slot stores a type + the parameters relevant to that
// type. UI on the Instrument screen swaps editors based on [type].
//
// We keep the model deliberately flat (plain mutable fields) — easy for
// the UI to read/write directly via setState/notifyListeners, and easy
// to ship across the MethodChannel to the Oboe engine when wiring up
// audio later.

enum InstrumentType { sampler, simpleSynth, karplusStrong, empty }

extension InstrumentTypeLabel on InstrumentType {
  String get label {
    switch (this) {
      case InstrumentType.sampler:
        return 'SAMPLER';
      case InstrumentType.simpleSynth:
        return 'SIMPLE SYNTH';
      case InstrumentType.karplusStrong:
        return 'KARPLUS';
      case InstrumentType.empty:
        return 'EMPTY';
    }
  }

  bool get isEmpty => this == InstrumentType.empty;
}

enum SynthWave { sine, triangle, saw, square, pulse, noise }

extension SynthWaveLabel on SynthWave {
  String get label {
    switch (this) {
      case SynthWave.sine:
        return 'SIN';
      case SynthWave.triangle:
        return 'TRI';
      case SynthWave.saw:
        return 'SAW';
      case SynthWave.square:
        return 'SQR';
      case SynthWave.pulse:
        return 'PUL';
      case SynthWave.noise:
        return 'NSE';
    }
  }
}

enum SynthFilterMode { lowPass, highPass, bandPass }

extension SynthFilterModeLabel on SynthFilterMode {
  String get label {
    switch (this) {
      case SynthFilterMode.lowPass:
        return 'LP';
      case SynthFilterMode.highPass:
        return 'HP';
      case SynthFilterMode.bandPass:
        return 'BP';
    }
  }

  int get index2 {
    switch (this) {
      case SynthFilterMode.lowPass:
        return 0;
      case SynthFilterMode.highPass:
        return 1;
      case SynthFilterMode.bandPass:
        return 2;
    }
  }
}

enum SynthLfoTarget { pitch, filter, amp }

extension SynthLfoTargetLabel on SynthLfoTarget {
  String get label {
    switch (this) {
      case SynthLfoTarget.pitch:
        return 'PITCH';
      case SynthLfoTarget.filter:
        return 'FILTER';
      case SynthLfoTarget.amp:
        return 'AMP';
    }
  }

  int get index2 {
    switch (this) {
      case SynthLfoTarget.pitch:
        return 0;
      case SynthLfoTarget.filter:
        return 1;
      case SynthLfoTarget.amp:
        return 2;
    }
  }
}

/// Parameters for the simple subtractive synth (Koala-style):
///   - 1 oscillator with selectable waveform + detune
///   - low-pass filter (cutoff + resonance)
///   - amp envelope (attack / decay / sustain / release)
///   - glide (portamento) and master volume
///
/// All ranges are 0.0 … 1.0 except where noted, normalised so the UI is
/// uniform and the engine can map them to musical units.
class SimpleSynthParams {
  // ── Oscillator 1 (always on) ──────────────────────────────────────────────
  SynthWave wave;
  double detune; // -1..1 (semitones * 12)
  double osc1Gain; // 0..1
  int osc1Oct; // -2..+2 octave offset
  // ── Oscillator 2 ─────────────────────────────────────────────────────────
  bool osc2On;
  SynthWave osc2Wave;
  double osc2Detune; // -1..1
  double osc2Gain; // 0..1
  double osc2FmDepth; // 0..1 (OSC 2 FM-modulates OSC 1)
  int osc2Oct; // -2..+2 octave offset
  // ── Oscillator 3 ─────────────────────────────────────────────────────────
  bool osc3On;
  SynthWave osc3Wave;
  double osc3Detune; // -1..1
  double osc3Gain; // 0..1
  double osc3FmDepth; // 0..1 (OSC 3 FM-modulates OSC 2)
  int osc3Oct; // -2..+2 octave offset
  // ── Shared ───────────────────────────────────────────────────────────────
  double cutoff; // 0..1
  double resonance; // 0..1
  SynthFilterMode filterMode; // LP / HP / BP
  double filterAttack; // 0..1
  double filterDecay; // 0..1
  double filterSustain; // 0..1
  double filterRelease; // 0..1
  double filterEnvAmt; // 0..1
  double attack; // 0..1 (seconds-ish curve)
  double decay; // 0..1
  double sustain; // 0..1 (level)
  double release; // 0..1
  double glide; // 0..1
  double volume; // 0..1
  double lfoRate; // 0..1 → 0.1..20 Hz
  double lfoDepth; // 0..1
  SynthLfoTarget lfoTarget; // pitch / filter / amp
  double drive; // 0..1

  SimpleSynthParams({
    this.wave = SynthWave.saw,
    this.detune = 0.0,
    this.osc1Gain = 1.0,
    this.osc1Oct = 0,
    this.osc2On = false,
    this.osc2Wave = SynthWave.saw,
    this.osc2Detune = 0.0,
    this.osc2Gain = 0.8,
    this.osc2FmDepth = 0.0,
    this.osc2Oct = 0,
    this.osc3On = false,
    this.osc3Wave = SynthWave.saw,
    this.osc3Detune = 0.0,
    this.osc3Gain = 0.8,
    this.osc3FmDepth = 0.0,
    this.osc3Oct = 0,
    this.cutoff = 0.7,
    this.resonance = 0.2,
    this.filterMode = SynthFilterMode.lowPass,
    this.filterAttack = 0.01,
    this.filterDecay = 0.25,
    this.filterSustain = 0.0,
    this.filterRelease = 0.25,
    this.filterEnvAmt = 0.5,
    this.attack = 0.02,
    this.decay = 0.3,
    this.sustain = 0.8,
    this.release = 0.25,
    this.glide = 0.0,
    this.volume = 0.8,
    this.lfoRate = 0.2,
    this.lfoDepth = 0.0,
    this.lfoTarget = SynthLfoTarget.pitch,
    this.drive = 0.0,
  });

  Map<String, dynamic> toJson() => {
    'wave': wave.index,
    'detune': detune,
    'osc1Gain': osc1Gain,
    'osc1Oct': osc1Oct,
    'osc2On': osc2On,
    'osc2Wave': osc2Wave.index,
    'osc2Detune': osc2Detune,
    'osc2Gain': osc2Gain,
    'osc2FmDepth': osc2FmDepth,
    'osc2Oct': osc2Oct,
    'osc3On': osc3On,
    'osc3Wave': osc3Wave.index,
    'osc3Detune': osc3Detune,
    'osc3Gain': osc3Gain,
    'osc3FmDepth': osc3FmDepth,
    'osc3Oct': osc3Oct,
    'cutoff': cutoff,
    'resonance': resonance,
    'filterMode': filterMode.index,
    'filterAtk': filterAttack,
    'filterDec': filterDecay,
    'filterSus': filterSustain,
    'filterRel': filterRelease,
    'filterAmt': filterEnvAmt,
    'atk': attack,
    'dec': decay,
    'sus': sustain,
    'rel': release,
    'glide': glide,
    'vol': volume,
    'lfoRate': lfoRate,
    'lfoDepth': lfoDepth,
    'lfoTarget': lfoTarget.index,
    'drive': drive,
  };

  factory SimpleSynthParams.fromJson(Map<String, dynamic> j) =>
      SimpleSynthParams(
        wave: SynthWave.values[(j['wave'] as int?) ?? 2],
        detune: (j['detune'] as num?)?.toDouble() ?? 0.0,
        osc1Gain: (j['osc1Gain'] as num?)?.toDouble() ?? 1.0,
        osc1Oct: (j['osc1Oct'] as int?) ?? 0,
        osc2On: (j['osc2On'] as bool?) ?? false,
        osc2Wave: SynthWave.values[(j['osc2Wave'] as int?) ?? 2],
        osc2Detune: (j['osc2Detune'] as num?)?.toDouble() ?? 0.0,
        osc2Gain: (j['osc2Gain'] as num?)?.toDouble() ?? 0.8,
        osc2FmDepth: (j['osc2FmDepth'] as num?)?.toDouble() ?? 0.0,
        osc2Oct: (j['osc2Oct'] as int?) ?? 0,
        osc3On: (j['osc3On'] as bool?) ?? false,
        osc3Wave: SynthWave.values[(j['osc3Wave'] as int?) ?? 2],
        osc3Detune: (j['osc3Detune'] as num?)?.toDouble() ?? 0.0,
        osc3Gain: (j['osc3Gain'] as num?)?.toDouble() ?? 0.8,
        osc3FmDepth: (j['osc3FmDepth'] as num?)?.toDouble() ?? 0.0,
        osc3Oct: (j['osc3Oct'] as int?) ?? 0,
        cutoff: (j['cutoff'] as num?)?.toDouble() ?? 0.7,
        resonance: (j['resonance'] as num?)?.toDouble() ?? 0.2,
        filterMode: SynthFilterMode.values[(j['filterMode'] as int?) ?? 0],
        filterAttack: (j['filterAtk'] as num?)?.toDouble() ?? 0.01,
        filterDecay: (j['filterDec'] as num?)?.toDouble() ?? 0.25,
        filterSustain: (j['filterSus'] as num?)?.toDouble() ?? 0.0,
        filterRelease: (j['filterRel'] as num?)?.toDouble() ?? 0.25,
        filterEnvAmt: (j['filterAmt'] as num?)?.toDouble() ?? 0.5,
        attack: (j['atk'] as num?)?.toDouble() ?? 0.02,
        decay: (j['dec'] as num?)?.toDouble() ?? 0.3,
        sustain: (j['sus'] as num?)?.toDouble() ?? 0.8,
        release: (j['rel'] as num?)?.toDouble() ?? 0.25,
        glide: (j['glide'] as num?)?.toDouble() ?? 0.0,
        volume: (j['vol'] as num?)?.toDouble() ?? 0.8,
        lfoRate: (j['lfoRate'] as num?)?.toDouble() ?? 0.2,
        lfoDepth: (j['lfoDepth'] as num?)?.toDouble() ?? 0.0,
        lfoTarget: SynthLfoTarget.values[(j['lfoTarget'] as int?) ?? 0],
        drive: (j['drive'] as num?)?.toDouble() ?? 0.0,
      );

  /// Deep copy.
  SimpleSynthParams copy() => SimpleSynthParams(
    wave: wave,
    detune: detune,
    osc1Gain: osc1Gain,
    osc1Oct: osc1Oct,
    osc2On: osc2On,
    osc2Wave: osc2Wave,
    osc2Detune: osc2Detune,
    osc2Gain: osc2Gain,
    osc2FmDepth: osc2FmDepth,
    osc2Oct: osc2Oct,
    osc3On: osc3On,
    osc3Wave: osc3Wave,
    osc3Detune: osc3Detune,
    osc3Gain: osc3Gain,
    osc3FmDepth: osc3FmDepth,
    osc3Oct: osc3Oct,
    cutoff: cutoff,
    resonance: resonance,
    filterMode: filterMode,
    filterAttack: filterAttack,
    filterDecay: filterDecay,
    filterSustain: filterSustain,
    filterRelease: filterRelease,
    filterEnvAmt: filterEnvAmt,
    attack: attack,
    decay: decay,
    sustain: sustain,
    release: release,
    glide: glide,
    volume: volume,
    lfoRate: lfoRate,
    lfoDepth: lfoDepth,
    lfoTarget: lfoTarget,
    drive: drive,
  );

  /// Highest Pxx param index supported for synth instruments.
  static const int maxParamIndex = 21;

  /// Display name for synth Pxx param slot [idx] (0=reset, 1–21=params).
  static String paramName(int idx) {
    switch (idx) {
      case 0:
        return 'Reset';
      case 1:
        return 'Volume';
      case 2:
        return 'Attack';
      case 3:
        return 'Decay';
      case 4:
        return 'Sustain';
      case 5:
        return 'Release';
      case 6:
        return 'Cutoff';
      case 7:
        return 'Resonance';
      case 8:
        return 'Drive';
      case 9:
        return 'OSC1 Detune';
      case 10:
        return 'Glide';
      case 11:
        return 'LFO Rate';
      case 12:
        return 'LFO Depth';
      case 13:
        return 'OSC1 Waveform';
      case 14:
        return 'OSC2 Waveform';
      case 15:
        return 'OSC2 Detune';
      case 16:
        return 'OSC2 Gain';
      case 17:
        return 'OSC2 FM';
      case 18:
        return 'OSC3 Waveform';
      case 19:
        return 'OSC3 Detune';
      case 20:
        return 'OSC3 Gain';
      case 21:
        return 'OSC3 FM';
      default:
        return 'P${idx.toString().padLeft(2, '0')}';
    }
  }

  /// One-line description for synth Pxx param slot [idx].
  static String paramDescription(int idx) {
    switch (idx) {
      case 0:
        return 'P00 — reset all synth params to original slider values';
      case 1:
        return 'P01 Volume — instrument level (00=silent, 99=full)';
      case 2:
        return 'P02 Attack — envelope attack (00=instant, 99=slowest)';
      case 3:
        return 'P03 Decay — envelope decay (00=instant, 99=slowest)';
      case 4:
        return 'P04 Sustain — envelope sustain level (00=silent, 99=full)';
      case 5:
        return 'P05 Release — envelope release (00=instant, 99=slowest)';
      case 6:
        return 'P06 Cutoff — filter cutoff (00=closed, 99=open)';
      case 7:
        return 'P07 Resonance — filter resonance (00=none, 99=max)';
      case 8:
        return 'P08 Drive — saturation (00=clean, 99=full drive)';
      case 9:
        return 'P09 OSC1 Detune — pitch offset (00=−12st, 50=centre, 99=+12st)';
      case 10:
        return 'P10 Glide — portamento time (00=instant, 99=slowest)';
      case 11:
        return 'P11 LFO Rate — LFO speed (00=slowest, 99=fastest)';
      case 12:
        return 'P12 LFO Depth — LFO intensity (00=off, 99=max)';
      case 13:
        return 'P13 OSC1 Waveform — 00=sine 01=tri 02=saw 03=sqr 04=pul 05=nse';
      case 14:
        return 'P14 OSC2 Waveform — 00=sine 01=tri 02=saw 03=sqr 04=pul 05=nse';
      case 15:
        return 'P15 OSC2 Detune — pitch offset (00=−12st, 50=centre, 99=+12st)';
      case 16:
        return 'P16 OSC2 Gain — output level (00=silent, 99=full)';
      case 17:
        return 'P17 OSC2 FM — FM depth modulating OSC1 (00=off, 99=full)';
      case 18:
        return 'P18 OSC3 Waveform — 00=sine 01=tri 02=saw 03=sqr 04=pul 05=nse';
      case 19:
        return 'P19 OSC3 Detune — pitch offset (00=−12st, 50=centre, 99=+12st)';
      case 20:
        return 'P20 OSC3 Gain — output level (00=silent, 99=full)';
      case 21:
        return 'P21 OSC3 FM — FM depth modulating OSC2 (00=off, 99=full)';
      default:
        return '';
    }
  }
}

class KarplusStrongParams {
  double decay; // 0..1 -> feedback / sustain length
  double damping; // 0..1 -> low-pass damping / brightness
  double tone; // 0..1 -> excitation hardness / attack color
  double stretch; // 0..1 -> inharmonicity / dispersion
  double pickPosition; // 0..1 -> excitation point along the string
  double attackColor; // 0..1 -> brightness / noisiness of the pick transient
  double body; // 0..1 -> resonant body emphasis
  double drive; // 0..1 -> output saturation

  KarplusStrongParams({
    this.decay = 0.55,
    this.damping = 0.62,
    this.tone = 0.50,
    this.stretch = 0.22,
    this.pickPosition = 0.30,
    this.attackColor = 0.48,
    this.body = 0.35,
    this.drive = 0.10,
  });

  Map<String, dynamic> toJson() => {
    'decay': decay,
    'damping': damping,
    'tone': tone,
    'stretch': stretch,
    'pickPosition': pickPosition,
    'attackColor': attackColor,
    'body': body,
    'drive': drive,
  };

  factory KarplusStrongParams.fromJson(Map<String, dynamic> j) =>
      KarplusStrongParams(
        decay: (j['decay'] as num?)?.toDouble() ?? 0.55,
        damping: (j['damping'] as num?)?.toDouble() ?? 0.62,
        tone: (j['tone'] as num?)?.toDouble() ?? 0.50,
        stretch: (j['stretch'] as num?)?.toDouble() ?? 0.22,
        pickPosition: (j['pickPosition'] as num?)?.toDouble() ?? 0.30,
        attackColor: (j['attackColor'] as num?)?.toDouble() ?? 0.48,
        body: (j['body'] as num?)?.toDouble() ?? 0.35,
        drive: (j['drive'] as num?)?.toDouble() ?? 0.10,
      );

  KarplusStrongParams copy() => KarplusStrongParams(
    decay: decay,
    damping: damping,
    tone: tone,
    stretch: stretch,
    pickPosition: pickPosition,
    attackColor: attackColor,
    body: body,
    drive: drive,
  );

  static const int maxParamIndex = 8;

  static String paramName(int idx) {
    switch (idx) {
      case 0:
        return 'Reset';
      case 1:
        return 'Decay';
      case 2:
        return 'Damping';
      case 3:
        return 'Tone';
      case 4:
        return 'Stretch';
      case 5:
        return 'Pick Pos';
      case 6:
        return 'Attack Color';
      case 7:
        return 'Body';
      case 8:
        return 'Drive';
      default:
        return 'P${idx.toString().padLeft(2, '0')}';
    }
  }

  static String paramDescription(int idx) {
    switch (idx) {
      case 0:
        return 'P00 — reset all Karplus params to original slider values';
      case 1:
        return 'P01 Decay — string feedback / sustain length (00=short, 99=long)';
      case 2:
        return 'P02 Damping — brightness and decay filtering (00=dark, 99=bright)';
      case 3:
        return 'P03 Tone — excitation hardness (00=soft, 99=hard)';
      case 4:
        return 'P04 Stretch — inharmonicity / string stiffness (00=clean, 99=stiff)';
      case 5:
        return 'P05 Pick Pos — where the string is excited (00=near bridge, 99=near center)';
      case 6:
        return 'P06 Attack Color — pick transient brightness/noise (00=soft, 99=hard)';
      case 7:
        return 'P07 Body — resonant body emphasis (00=dry, 99=boxy/resonant)';
      case 8:
        return 'P08 Drive — output saturation (00=clean, 99=full drive)';
      default:
        return '';
    }
  }
}

enum SamplerLoopMode { off, forward, pingPong }

extension SamplerLoopModeLabel on SamplerLoopMode {
  String get label {
    switch (this) {
      case SamplerLoopMode.off:
        return 'OFF';
      case SamplerLoopMode.forward:
        return 'LOOP';
      case SamplerLoopMode.pingPong:
        return 'PING';
    }
  }
}

class SamplerParams {
  static const int sliceCount = 9;

  String? sampleName;
  String? samplePath;
  double pitch; // -1..1  (±12 semitones)
  double volume; // 0..1
  SamplerLoopMode loopMode;
  double start; // 0..1
  double end; // 0..1
  double attack; // 0..1  (fade-in length, 0 = instant)
  double release; // 0..1  (fade-out length, 0 = instant)
  List<int> sliceStarts; // 9 x 0..999, where 0 = unused

  // ── Stretch ────────────────────────────────────────────────────────────────
  bool stretchEnabled;    // false = off (passthrough)
  int stretchBeats;       // 1..99
  bool stretchPreservePitch; // true = time-stretch only; false = pitch follows rate

  // ── Filter (HP → LP in series) ────────────────────────────────────────────
  // Bypassed entirely (zero CPU) when filterEnabled = false.
  bool filterEnabled;     // master ON/OFF
  double hpCutoff;        // 0..1 (0 = bypass, 1 = fully closed)
  double hpResonance;     // 0..1
  double lpCutoff;        // 0..1 (0 = fully closed, 1 = bypass / fully open)
  double lpResonance;     // 0..1

  // keep legacy bool getter so existing code using p.loop still compiles
  bool get loop => loopMode != SamplerLoopMode.off;

  SamplerParams({
    this.sampleName,
    this.samplePath,
    this.pitch = 0.0,
    this.volume = 0.9,
    this.loopMode = SamplerLoopMode.off,
    this.start = 0.0,
    this.end = 1.0,
    this.attack = 0.0,
    this.release = 0.05,
    List<int>? sliceStarts,
    this.stretchEnabled = false,
    this.stretchBeats = 4,
    this.stretchPreservePitch = true,
    this.filterEnabled = false,
    this.hpCutoff = 0.0,
    this.hpResonance = 0.0,
    this.lpCutoff = 1.0,
    this.lpResonance = 0.0,
  }) : sliceStarts = _normalizedSliceStarts(sliceStarts);

  static List<int> _normalizedSliceStarts(List<int>? values) {
    final normalized = List<int>.filled(sliceCount, 0);
    int prev = 0;
    final source = values ?? const <int>[];
    for (int i = 0; i < sliceCount; i++) {
      final raw = i < source.length ? source[i] : 0;
      final safe = raw.clamp(0, 999);
      if (safe == 0) {
        normalized[i] = 0;
        continue;
      }
      final minValue = prev == 0 ? 1 : prev;
      final clamped = safe < minValue ? minValue : safe;
      normalized[i] = clamped;
      prev = clamped;
    }
    return normalized;
  }

  void setSliceStart(int index, int value) {
    if (index < 0 || index >= sliceStarts.length) return;
    final next = List<int>.from(sliceStarts);
    int safe = value.clamp(0, 999);
    if (safe > 0) {
      // Clamp only this slider so it cannot cross already-set neighbors.
      int minBound = 1;
      for (int i = index - 1; i >= 0; i--) {
        if (next[i] > 0) {
          minBound = next[i];
          break;
        }
      }
      int maxBound = 999;
      for (int i = index + 1; i < next.length; i++) {
        if (next[i] > 0) {
          maxBound = next[i];
          break;
        }
      }
      safe = safe.clamp(minBound, maxBound);
    }
    next[index] = safe;
    sliceStarts = next;
  }

  int sliceStartValue(int sliceNumber) {
    if (sliceNumber < 1 || sliceNumber > sliceStarts.length) return 0;
    return sliceStarts[sliceNumber - 1];
  }

  double? sliceStartNorm(int sliceNumber) {
    final value = sliceStartValue(sliceNumber);
    if (value <= 0) return null;
    return value / 999.0;
  }

  double sliceEndNorm(int sliceNumber, {bool playThrough = false}) {
    // For SLxx commands, 00 should play through to full sample end,
    // independent of the sampler region end knob.
    if (playThrough) return 1.0;
    final startIndex = sliceNumber.clamp(0, sliceStarts.length);
    for (int i = startIndex; i < sliceStarts.length; i++) {
      final next = sliceStarts[i];
      if (next > 0) return next / 999.0;
    }
    // No next slice found — fall back to the instrument's configured end point
    // so the last slice respects the end knob rather than playing to the raw
    // audio file boundary (which caused looping/run-on for the last slice).
    return end;
  }

  Map<String, dynamic> toJson() => {
    'sampleName': sampleName,
    'samplePath': samplePath,
    'pitch': pitch,
    'vol': volume,
    'loopMode': loopMode.index,
    'start': start,
    'end': end,
    'attack': attack,
    'release': release,
    'sliceStarts': sliceStarts,
    'sliceVersion': 2, // 2 = range 0-999; 1 (absent) = legacy 0-99
    'stretchEnabled': stretchEnabled,
    'stretchBeats': stretchBeats,
    'stretchPreservePitch': stretchPreservePitch,
    'filterEnabled': filterEnabled,
    'hpCutoff': hpCutoff,
    'hpResonance': hpResonance,
    'lpCutoff': lpCutoff,
    'lpResonance': lpResonance,
  };

  factory SamplerParams.fromJson(Map<String, dynamic> j) => SamplerParams(
    sampleName: j['sampleName'] as String?,
    samplePath: j['samplePath'] as String?,
    pitch: (j['pitch'] as num?)?.toDouble() ?? 0.0,
    volume: (j['vol'] as num?)?.toDouble() ?? 0.9,
    loopMode:
        SamplerLoopMode.values[(j['loopMode'] as int?) ??
            (((j['loop'] as bool?) ?? false) ? 1 : 0)],
    start: (j['start'] as num?)?.toDouble() ?? 0.0,
    end: (j['end'] as num?)?.toDouble() ?? 1.0,
    attack: (j['attack'] as num?)?.toDouble() ?? 0.0,
    release: (j['release'] as num?)?.toDouble() ?? 0.05,
    sliceStarts: (j['sliceStarts'] as List<dynamic>?)?.map((e) {
      final v = (e as num?)?.toInt() ?? 0;
      // Migrate legacy saves (sliceVersion absent = old 0-99 range → multiply by 10)
      final isLegacy = ((j['sliceVersion'] as int?) ?? 1) < 2;
      return isLegacy ? (v * 10).clamp(0, 999) : v;
    }).toList(),
    stretchEnabled: (j['stretchEnabled'] as bool?) ?? false,
    stretchBeats: (j['stretchBeats'] as int?) ?? 4,
    stretchPreservePitch: (j['stretchPreservePitch'] as bool?) ?? true,
    filterEnabled: (j['filterEnabled'] as bool?) ?? false,
    hpCutoff: (j['hpCutoff'] as num?)?.toDouble() ?? 0.0,
    hpResonance: (j['hpResonance'] as num?)?.toDouble() ?? 0.0,
    lpCutoff: (j['lpCutoff'] as num?)?.toDouble() ?? 1.0,
    lpResonance: (j['lpResonance'] as num?)?.toDouble() ?? 0.0,
  );

  /// Create a deep copy of this sampler configuration.
  SamplerParams copy() => SamplerParams(
    sampleName: sampleName,
    samplePath: samplePath,
    pitch: pitch,
    volume: volume,
    loopMode: loopMode,
    start: start,
    end: end,
    attack: attack,
    release: release,
    sliceStarts: List<int>.from(sliceStarts),
    stretchEnabled: stretchEnabled,
    stretchBeats: stretchBeats,
    stretchPreservePitch: stretchPreservePitch,
    filterEnabled: filterEnabled,
    hpCutoff: hpCutoff,
    hpResonance: hpResonance,
    lpCutoff: lpCutoff,
    lpResonance: lpResonance,
  );

  /// Highest Pxx param index supported for sampler instruments.
  static const int maxParamIndex = 11;

  /// Display name for sampler Pxx param slot [idx] (0=reset, 1–11=params).
  static String paramName(int idx) {
    switch (idx) {
      case 0:
        return 'Reset';
      case 1:
        return 'Start';
      case 2:
        return 'End';
      case 3:
        return 'Pitch';
      case 4:
        return 'Volume';
      case 5:
        return 'Attack';
      case 6:
        return 'Release';
      case 7:
        return 'Loop';
      case 8:
        return 'HP Cut';
      case 9:
        return 'HP Res';
      case 10:
        return 'LP Cut';
      case 11:
        return 'LP Res';
      default:
        return 'P${idx.toString().padLeft(2, '0')}';
    }
  }

  /// One-line description for sampler Pxx param slot [idx].
  static String paramDescription(int idx) {
    switch (idx) {
      case 0:
        return 'P00 — reset all sampler params to original slider values';
      case 1:
        return 'P01 Start — sample start position (00=beginning, 99=end)';
      case 2:
        return 'P02 End — sample end position (00=beginning, 99=end)';
      case 3:
        return 'P03 Pitch — detune in semitones (00=−12st, 50=centre, 99=+12st)';
      case 4:
        return 'P04 Volume — instrument level (00=silent, 99=full)';
      case 5:
        return 'P05 Attack — fade-in length (00=instant, 99=slowest)';
      case 6:
        return 'P06 Release — fade-out length (00=instant, 99=slowest)';
      case 7:
        return 'P07 Loop — 00=off, 01=loop forward, 02=ping-pong';
      case 8:
        return 'P08 HP Cut — high-pass cutoff (00=open, 99=closed). Filter must be ON.';
      case 9:
        return 'P09 HP Res — high-pass resonance (00–99). Filter must be ON.';
      case 10:
        return 'P10 LP Cut — low-pass cutoff (00=closed, 99=open). Filter must be ON.';
      case 11:
        return 'P11 LP Res — low-pass resonance (00–99). Filter must be ON.';
      default:
        return '';
    }
  }
}

class InstrumentModel {
  String name;
  InstrumentType type;
  SimpleSynthParams synth;
  KarplusStrongParams karplus;
  SamplerParams sampler;
  late SimpleSynthParams synthStartState;
  late KarplusStrongParams karplusStartState;
  late SamplerParams samplerStartState;

  InstrumentModel({
    required this.name,
    this.type = InstrumentType.empty,
    SimpleSynthParams? synth,
    KarplusStrongParams? karplus,
    SamplerParams? sampler,
    SimpleSynthParams? synthStartState,
    KarplusStrongParams? karplusStartState,
    SamplerParams? samplerStartState,
  }) : synth = synth ?? SimpleSynthParams(),
       karplus = karplus ?? KarplusStrongParams(),
       sampler = sampler ?? SamplerParams() {
    // Initialize start states as copies of the working parameters.
    // When play() is called, these get updated as snapshots.
    this.synthStartState = synthStartState ?? this.synth.copy();
    this.karplusStartState = karplusStartState ?? this.karplus.copy();
    this.samplerStartState = samplerStartState ?? this.sampler.copy();
  }

  factory InstrumentModel.empty(int index) =>
      InstrumentModel(name: 'INS ${index.toString().padLeft(2, '0')}');

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type.index,
    'synth': synth.toJson(),
    'karplus': karplus.toJson(),
    'sampler': sampler.toJson(),
    'synthStartState': synthStartState.toJson(),
    'karplusStartState': karplusStartState.toJson(),
    'samplerStartState': samplerStartState.toJson(),
  };

  factory InstrumentModel.fromJson(Map<String, dynamic> j) => InstrumentModel(
    name: j['name'] as String,
    // Legacy saves had 0=sampler 1=simpleSynth and no empty concept; default to empty for new slots
    type: InstrumentType.values.length > (j['type'] as int? ?? 2)
        ? InstrumentType.values[(j['type'] as int?) ?? 2]
        : InstrumentType.empty,
    synth: SimpleSynthParams.fromJson(
      (j['synth'] as Map<String, dynamic>?) ?? {},
    ),
    karplus: KarplusStrongParams.fromJson(
      (j['karplus'] as Map<String, dynamic>?) ?? {},
    ),
    sampler: SamplerParams.fromJson(
      (j['sampler'] as Map<String, dynamic>?) ?? {},
    ),
    synthStartState: SimpleSynthParams.fromJson(
      (j['synthStartState'] as Map<String, dynamic>?) ?? {},
    ),
    karplusStartState: KarplusStrongParams.fromJson(
      (j['karplusStartState'] as Map<String, dynamic>?) ?? {},
    ),
    samplerStartState: SamplerParams.fromJson(
      (j['samplerStartState'] as Map<String, dynamic>?) ?? {},
    ),
  );
}

/// Total number of instrument slots (matches FF in the tracker grid).
const int kInstrumentSlots = 64;
