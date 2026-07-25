import 'instrument_model.dart';

class DrumSynthPreset {
  final String name;
  final String description;
  final DrumSynthParams Function() build;

  const DrumSynthPreset({
    required this.name,
    required this.description,
    required this.build,
  });

  DrumSynthParams createParams() => build();

  void applyTo(DrumSynthParams target) {
    final p = build();
    // Presets also set the piece so picking e.g. "808 Snare" switches the
    // DRUM PIECE selector to Snare rather than leaving a mismatched piece.
    target.piece = p.piece;
    target.pitch = p.pitch;
    target.pitchDecay = p.pitchDecay;
    target.tone = p.tone;
    target.cutoff = p.cutoff;
    target.resonance = p.resonance;
    target.decay = p.decay;
    target.punch = p.punch;
    target.drive = p.drive;
    target.volume = p.volume;
  }
}

final List<DrumSynthPreset> kDrumSynthPresets = <DrumSynthPreset>[
  // ── Kick ─────────────────────────────────────────────────────────────────
  DrumSynthPreset(
    name: '808 Deep',
    description: 'Deep, round sub kick with a long pitch sweep.',
    build: () => DrumSynthParams(
      piece: DrumPiece.kick,
      pitch: 0.35,
      pitchDecay: 0.55,
      tone: 0.15,
      cutoff: 0.60,
      resonance: 0.20,
      decay: 0.75,
      punch: 0.35,
      drive: 0.10,
      volume: 0.90,
    ),
  ),
  DrumSynthPreset(
    name: '909 Punchy',
    description: 'Fast, punchy club kick with a snappy transient.',
    build: () => DrumSynthParams(
      piece: DrumPiece.kick,
      pitch: 0.55,
      pitchDecay: 0.25,
      tone: 0.40,
      cutoff: 0.65,
      resonance: 0.30,
      decay: 0.35,
      punch: 0.65,
      drive: 0.25,
      volume: 0.90,
    ),
  ),
  DrumSynthPreset(
    name: 'Sub Boom',
    description: 'Very low, long sub-bass boom with almost no click.',
    build: () => DrumSynthParams(
      piece: DrumPiece.kick,
      pitch: 0.15,
      pitchDecay: 0.70,
      tone: 0.05,
      cutoff: 0.40,
      resonance: 0.15,
      decay: 0.90,
      punch: 0.20,
      drive: 0.05,
      volume: 0.95,
    ),
  ),
  DrumSynthPreset(
    name: 'Short Tight',
    description: 'Compact, dry kick for fast, busy patterns.',
    build: () => DrumSynthParams(
      piece: DrumPiece.kick,
      pitch: 0.50,
      pitchDecay: 0.15,
      tone: 0.30,
      cutoff: 0.60,
      resonance: 0.25,
      decay: 0.20,
      punch: 0.50,
      drive: 0.15,
      volume: 0.85,
    ),
  ),
  // ── Snare ────────────────────────────────────────────────────────────────
  DrumSynthPreset(
    name: '808 Snare',
    description: 'Classic tonal snare body blended with soft noise.',
    build: () => DrumSynthParams(
      piece: DrumPiece.snare,
      pitch: 0.45,
      pitchDecay: 0.30,
      tone: 0.50,
      cutoff: 0.70,
      resonance: 0.35,
      decay: 0.40,
      punch: 0.40,
      drive: 0.10,
      volume: 0.85,
    ),
  ),
  DrumSynthPreset(
    name: '909 Snappy',
    description: 'Bright, snappy snare with a sharp noise crack.',
    build: () => DrumSynthParams(
      piece: DrumPiece.snare,
      pitch: 0.55,
      pitchDecay: 0.20,
      tone: 0.65,
      cutoff: 0.80,
      resonance: 0.45,
      decay: 0.30,
      punch: 0.70,
      drive: 0.20,
      volume: 0.85,
    ),
  ),
  DrumSynthPreset(
    name: 'Fat Noise',
    description: 'Noise-heavy snare body with a longer tail.',
    build: () => DrumSynthParams(
      piece: DrumPiece.snare,
      pitch: 0.40,
      pitchDecay: 0.25,
      tone: 0.75,
      cutoff: 0.65,
      resonance: 0.30,
      decay: 0.50,
      punch: 0.35,
      drive: 0.15,
      volume: 0.85,
    ),
  ),
  DrumSynthPreset(
    name: 'Rim-ish',
    description: 'Very short, high, click-forward — rimshot-style hit.',
    build: () => DrumSynthParams(
      piece: DrumPiece.snare,
      pitch: 0.65,
      pitchDecay: 0.10,
      tone: 0.55,
      cutoff: 0.85,
      resonance: 0.50,
      decay: 0.15,
      punch: 0.75,
      drive: 0.10,
      volume: 0.80,
    ),
  ),
  // ── Hi-hat ───────────────────────────────────────────────────────────────
  DrumSynthPreset(
    name: 'Closed Tight',
    description: 'Short, tight closed hi-hat.',
    build: () => DrumSynthParams(
      piece: DrumPiece.hat,
      pitch: 0.55,
      pitchDecay: 0.30,
      tone: 0.40,
      cutoff: 0.80,
      resonance: 0.35,
      decay: 0.12,
      punch: 0.40,
      drive: 0.05,
      volume: 0.70,
    ),
  ),
  DrumSynthPreset(
    name: 'Closed Metallic',
    description: 'Closed hat with extra metallic ring.',
    build: () => DrumSynthParams(
      piece: DrumPiece.hat,
      pitch: 0.70,
      pitchDecay: 0.30,
      tone: 0.75,
      cutoff: 0.85,
      resonance: 0.60,
      decay: 0.15,
      punch: 0.30,
      drive: 0.05,
      volume: 0.70,
    ),
  ),
  DrumSynthPreset(
    name: 'Open Loose',
    description: 'Longer, looser open hi-hat.',
    build: () => DrumSynthParams(
      piece: DrumPiece.hat,
      pitch: 0.60,
      pitchDecay: 0.30,
      tone: 0.55,
      cutoff: 0.75,
      resonance: 0.40,
      decay: 0.55,
      punch: 0.20,
      drive: 0.05,
      volume: 0.70,
    ),
  ),
  // ── Tom ──────────────────────────────────────────────────────────────────
  DrumSynthPreset(
    name: 'Low Tom',
    description: 'Deep floor tom with a long pitch sweep.',
    build: () => DrumSynthParams(
      piece: DrumPiece.tom,
      pitch: 0.20,
      pitchDecay: 0.50,
      tone: 0.20,
      cutoff: 0.55,
      resonance: 0.25,
      decay: 0.60,
      punch: 0.30,
      drive: 0.08,
      volume: 0.90,
    ),
  ),
  DrumSynthPreset(
    name: 'Mid Tom',
    description: 'Balanced mid-range tom.',
    build: () => DrumSynthParams(
      piece: DrumPiece.tom,
      pitch: 0.50,
      pitchDecay: 0.40,
      tone: 0.25,
      cutoff: 0.60,
      resonance: 0.25,
      decay: 0.50,
      punch: 0.35,
      drive: 0.08,
      volume: 0.88,
    ),
  ),
  DrumSynthPreset(
    name: 'High Tom',
    description: 'Bright, higher-pitched tom.',
    build: () => DrumSynthParams(
      piece: DrumPiece.tom,
      pitch: 0.80,
      pitchDecay: 0.30,
      tone: 0.30,
      cutoff: 0.65,
      resonance: 0.25,
      decay: 0.40,
      punch: 0.40,
      drive: 0.08,
      volume: 0.85,
    ),
  ),
  // ── Crash ────────────────────────────────────────────────────────────────
  DrumSynthPreset(
    name: 'Short Crash',
    description: 'Bright crash that decays fairly quickly.',
    build: () => DrumSynthParams(
      piece: DrumPiece.crash,
      pitch: 0.60,
      pitchDecay: 0.30,
      tone: 0.60,
      cutoff: 0.85,
      resonance: 0.40,
      decay: 0.50,
      punch: 0.50,
      drive: 0.10,
      volume: 0.80,
    ),
  ),
  DrumSynthPreset(
    name: 'Long Wash',
    description: 'Long, washy crash with a slow decay.',
    build: () => DrumSynthParams(
      piece: DrumPiece.crash,
      pitch: 0.50,
      pitchDecay: 0.30,
      tone: 0.50,
      cutoff: 0.75,
      resonance: 0.35,
      decay: 0.95,
      punch: 0.25,
      drive: 0.05,
      volume: 0.75,
    ),
  ),
  DrumSynthPreset(
    name: 'Bright Splash',
    description: 'High, splashy crash with extra shimmer.',
    build: () => DrumSynthParams(
      piece: DrumPiece.crash,
      pitch: 0.75,
      pitchDecay: 0.30,
      tone: 0.80,
      cutoff: 0.90,
      resonance: 0.55,
      decay: 0.60,
      punch: 0.55,
      drive: 0.10,
      volume: 0.80,
    ),
  ),
];
