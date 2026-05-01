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

enum InstrumentType {
  sampler,
  simpleSynth,
  empty,
}

extension InstrumentTypeLabel on InstrumentType {
  String get label {
    switch (this) {
      case InstrumentType.sampler:     return 'SAMPLER';
      case InstrumentType.simpleSynth: return 'SIMPLE SYNTH';
      case InstrumentType.empty:       return 'EMPTY';
    }
  }
  bool get isEmpty => this == InstrumentType.empty;
}

enum SynthWave { sine, triangle, saw, square, pulse, noise }

extension SynthWaveLabel on SynthWave {
  String get label {
    switch (this) {
      case SynthWave.sine:     return 'SIN';
      case SynthWave.triangle: return 'TRI';
      case SynthWave.saw:      return 'SAW';
      case SynthWave.square:   return 'SQR';
      case SynthWave.pulse:    return 'PUL';
      case SynthWave.noise:    return 'NSE';
    }
  }
}

enum SynthFilterMode { lowPass, highPass, bandPass }

extension SynthFilterModeLabel on SynthFilterMode {
  String get label {
    switch (this) {
      case SynthFilterMode.lowPass:  return 'LP';
      case SynthFilterMode.highPass: return 'HP';
      case SynthFilterMode.bandPass: return 'BP';
    }
  }
  int get index2 {
    switch (this) {
      case SynthFilterMode.lowPass:  return 0;
      case SynthFilterMode.highPass: return 1;
      case SynthFilterMode.bandPass: return 2;
    }
  }
}

enum SynthLfoTarget { pitch, filter, amp }

extension SynthLfoTargetLabel on SynthLfoTarget {
  String get label {
    switch (this) {
      case SynthLfoTarget.pitch:  return 'PITCH';
      case SynthLfoTarget.filter: return 'FILTER';
      case SynthLfoTarget.amp:    return 'AMP';
    }
  }
  int get index2 {
    switch (this) {
      case SynthLfoTarget.pitch:  return 0;
      case SynthLfoTarget.filter: return 1;
      case SynthLfoTarget.amp:    return 2;
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
  SynthWave wave;
  double detune;        // -1..1 (semitones * 12)
  double cutoff;        // 0..1
  double resonance;     // 0..1
  SynthFilterMode filterMode; // LP / HP / BP
  double filterAttack;  // 0..1
  double filterDecay;   // 0..1
  double filterSustain; // 0..1
  double filterRelease; // 0..1
  double filterEnvAmt;  // 0..1
  double attack;        // 0..1 (seconds-ish curve)
  double decay;         // 0..1
  double sustain;       // 0..1 (level)
  double release;       // 0..1
  double glide;         // 0..1
  double volume;        // 0..1
  double lfoRate;       // 0..1 → 0.1..20 Hz
  double lfoDepth;      // 0..1
  SynthLfoTarget lfoTarget; // pitch / filter / amp
  double drive;         // 0..1

  SimpleSynthParams({
    this.wave      = SynthWave.saw,
    this.detune    = 0.0,
    this.cutoff    = 0.7,
    this.resonance = 0.2,
    this.filterMode = SynthFilterMode.lowPass,
    this.filterAttack = 0.01,
    this.filterDecay = 0.25,
    this.filterSustain = 0.0,
    this.filterRelease = 0.25,
    this.filterEnvAmt = 0.5,
    this.attack    = 0.02,
    this.decay     = 0.3,
    this.sustain   = 0.8,
    this.release   = 0.25,
    this.glide     = 0.0,
    this.volume    = 0.8,
    this.lfoRate   = 0.2,
    this.lfoDepth  = 0.0,
    this.lfoTarget = SynthLfoTarget.pitch,
    this.drive     = 0.0,
  });

  Map<String, dynamic> toJson() => {
    'wave': wave.index,
    'detune': detune,
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
        cutoff: (j['cutoff'] as num?)?.toDouble() ?? 0.7,
        resonance: (j['resonance'] as num?)?.toDouble() ?? 0.2,
        filterMode:
            SynthFilterMode.values[(j['filterMode'] as int?) ?? 0],
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
        lfoTarget:
            SynthLfoTarget.values[(j['lfoTarget'] as int?) ?? 0],
        drive: (j['drive'] as num?)?.toDouble() ?? 0.0,
      );
}

enum SamplerLoopMode { off, forward, pingPong }

extension SamplerLoopModeLabel on SamplerLoopMode {
  String get label {
    switch (this) {
      case SamplerLoopMode.off:      return 'OFF';
      case SamplerLoopMode.forward:  return 'LOOP';
      case SamplerLoopMode.pingPong: return 'PING';
    }
  }
}

class SamplerParams {
  String? sampleName;
  String? samplePath;
  double  pitch;      // -1..1  (±12 semitones)
  double  volume;     // 0..1
  SamplerLoopMode loopMode;
  double  start;      // 0..1
  double  end;        // 0..1
  double  attack;     // 0..1  (fade-in length, 0 = instant)
  double  release;    // 0..1  (fade-out length, 0 = instant)

  // keep legacy bool getter so existing code using p.loop still compiles
  bool get loop => loopMode != SamplerLoopMode.off;

  SamplerParams({
    this.sampleName,
    this.samplePath,
    this.pitch    = 0.0,
    this.volume   = 0.9,
    this.loopMode = SamplerLoopMode.off,
    this.start    = 0.0,
    this.end      = 1.0,
    this.attack   = 0.0,
    this.release  = 0.05,
  });

  Map<String, dynamic> toJson() => {
    'sampleName': sampleName,
    'samplePath': samplePath,
    'pitch':      pitch,
    'vol':        volume,
    'loopMode':   loopMode.index,
    'start':      start,
    'end':        end,
    'attack':     attack,
    'release':    release,
  };

  factory SamplerParams.fromJson(Map<String, dynamic> j) => SamplerParams(
    sampleName: j['sampleName'] as String?,
    samplePath: j['samplePath'] as String?,
    pitch:    (j['pitch']  as num?)?.toDouble() ?? 0.0,
    volume:   (j['vol']    as num?)?.toDouble() ?? 0.9,
    loopMode: SamplerLoopMode.values[(j['loopMode'] as int?) ??
              (((j['loop'] as bool?) ?? false) ? 1 : 0)],
    start:    (j['start']   as num?)?.toDouble() ?? 0.0,
    end:      (j['end']     as num?)?.toDouble() ?? 1.0,
    attack:   (j['attack']  as num?)?.toDouble() ?? 0.0,
    release:  (j['release'] as num?)?.toDouble() ?? 0.05,
  );
}

class InstrumentModel {
  String name;
  InstrumentType type;
  SimpleSynthParams synth;
  SamplerParams     sampler;

  InstrumentModel({
    required this.name,
    this.type = InstrumentType.empty,
    SimpleSynthParams? synth,
    SamplerParams?     sampler,
  })  : synth   = synth   ?? SimpleSynthParams(),
        sampler = sampler ?? SamplerParams();

  factory InstrumentModel.empty(int index) => InstrumentModel(
        name: 'INS ${index.toString().padLeft(2, '0')}',
      );

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type.index,
    'synth': synth.toJson(),
    'sampler': sampler.toJson(),
  };

  factory InstrumentModel.fromJson(Map<String, dynamic> j) => InstrumentModel(
    name: j['name'] as String,
    // Legacy saves had 0=sampler 1=simpleSynth and no empty concept; default to empty for new slots
    type: InstrumentType.values.length > (j['type'] as int? ?? 2)
        ? InstrumentType.values[(j['type'] as int?) ?? 2]
        : InstrumentType.empty,
    synth: SimpleSynthParams.fromJson(
        (j['synth'] as Map<String, dynamic>?) ?? {}),
    sampler: SamplerParams.fromJson(
        (j['sampler'] as Map<String, dynamic>?) ?? {}),
  );
}

/// Total number of instrument slots (matches FF in the tracker grid).
const int kInstrumentSlots = 64;
