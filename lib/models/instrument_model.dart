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
}

extension InstrumentTypeLabel on InstrumentType {
  String get label {
    switch (this) {
      case InstrumentType.sampler:     return 'SAMPLER';
      case InstrumentType.simpleSynth: return 'SIMPLE SYNTH';
    }
  }
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

  SimpleSynthParams({
    this.wave      = SynthWave.saw,
    this.detune    = 0.0,
    this.cutoff    = 0.7,
    this.resonance = 0.2,
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
  });
}

class SamplerParams {
  String? sampleName; // user-visible name; null = no sample loaded yet
  double  pitch;      // -1..1
  double  volume;     // 0..1
  bool    loop;
  double  start;      // 0..1
  double  end;        // 0..1

  SamplerParams({
    this.sampleName,
    this.pitch  = 0.0,
    this.volume = 0.9,
    this.loop   = false,
    this.start  = 0.0,
    this.end    = 1.0,
  });
}

class InstrumentModel {
  String name;
  InstrumentType type;
  SimpleSynthParams synth;
  SamplerParams     sampler;

  InstrumentModel({
    required this.name,
    this.type = InstrumentType.simpleSynth,
    SimpleSynthParams? synth,
    SamplerParams?     sampler,
  })  : synth   = synth   ?? SimpleSynthParams(),
        sampler = sampler ?? SamplerParams();

  factory InstrumentModel.empty(int index) => InstrumentModel(
        name: 'INS ${index.toString().padLeft(2, '0')}',
      );
}

/// Total number of instrument slots (matches FF in the tracker grid).
const int kInstrumentSlots = 16;
