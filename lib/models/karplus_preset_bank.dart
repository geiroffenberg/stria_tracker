import 'instrument_model.dart';

class KarplusStrongPreset {
  final String name;
  final String description;
  final KarplusStrongParams Function() build;

  const KarplusStrongPreset({
    required this.name,
    required this.description,
    required this.build,
  });

  KarplusStrongParams createParams() => build();

  void applyTo(KarplusStrongParams target) {
    final p = build();
    target.decay = p.decay;
    target.damping = p.damping;
    target.tone = p.tone;
    target.stretch = p.stretch;
    target.pickPosition = p.pickPosition;
    target.attackColor = p.attackColor;
    target.body = p.body;
    target.drive = p.drive;
    target.volume = p.volume;
    target.filterCutoff = p.filterCutoff;
    target.filterResonance = p.filterResonance;
    target.filterMode = p.filterMode;
    target.filterEnvAmt = p.filterEnvAmt;
    target.ampAttack = p.ampAttack;
    target.ampDecay = p.ampDecay;
    target.ampSustain = p.ampSustain;
    target.ampRelease = p.ampRelease;
  }
}

final List<KarplusStrongPreset> kKarplusStrongPresets = <KarplusStrongPreset>[
  KarplusStrongPreset(
    name: 'Default',
    description: 'Balanced pluck with moderate sustain and a clean string tone.',
    build: () => KarplusStrongParams(
      decay: 0.55,
      damping: 0.62,
      tone: 0.50,
      stretch: 0.22,
      pickPosition: 0.30,
      attackColor: 0.48,
      body: 0.28,
      drive: 0.10,
      volume: 0.90,
      filterCutoff: 0.90,
      filterResonance: 0.05,
      filterMode: SynthFilterMode.lowPass,
      filterEnvAmt: 0.10,
      ampAttack: 0.0,
      ampDecay: 0.0,
      ampSustain: 1.0,
      ampRelease: 0.12,
    ),
  ),
  KarplusStrongPreset(
    name: 'Bright Pluck',
    description:
        'Fast, bright and direct for melodic picking lines — a hint of '
        'attack sparkle and a tight release for clean note separation.',
    build: () => KarplusStrongParams(
      decay: 0.42,
      damping: 0.82,
      tone: 0.78,
      stretch: 0.12,
      pickPosition: 0.12,
      attackColor: 0.86,
      body: 0.24,
      drive: 0.18,
      volume: 0.92,
      filterCutoff: 0.97,
      filterResonance: 0.08,
      filterMode: SynthFilterMode.lowPass,
      filterEnvAmt: 0.15,
      ampAttack: 0.0,
      ampDecay: 0.08,
      ampSustain: 0.85,
      ampRelease: 0.05,
    ),
  ),
  KarplusStrongPreset(
    name: 'Muted Pick',
    description:
        'Short, dry and percussive for muted riffs and ghost notes — the '
        'filter stays dark and the envelope snaps shut almost instantly.',
    build: () => KarplusStrongParams(
      decay: 0.26,
      damping: 0.52,
      tone: 0.34,
      stretch: 0.08,
      pickPosition: 0.10,
      attackColor: 0.62,
      body: 0.18,
      drive: 0.14,
      volume: 0.88,
      filterCutoff: 0.45,
      filterResonance: 0.12,
      filterMode: SynthFilterMode.lowPass,
      filterEnvAmt: 0.05,
      ampAttack: 0.0,
      ampDecay: 0.20,
      ampSustain: 0.35,
      ampRelease: 0.04,
    ),
  ),
  KarplusStrongPreset(
    name: 'Nylon',
    description:
        'Soft attack and warm body for a gentler plucked-string feel — a '
        'rolled-off filter and a soft fade-in smooth out the transient.',
    build: () => KarplusStrongParams(
      decay: 0.48,
      damping: 0.40,
      tone: 0.28,
      stretch: 0.10,
      pickPosition: 0.42,
      attackColor: 0.18,
      body: 0.46,
      drive: 0.02,
      volume: 0.90,
      filterCutoff: 0.55,
      filterResonance: 0.05,
      filterMode: SynthFilterMode.lowPass,
      filterEnvAmt: 0.10,
      ampAttack: 0.04,
      ampDecay: 0.0,
      ampSustain: 1.0,
      ampRelease: 0.22,
    ),
  ),
  KarplusStrongPreset(
    name: 'Warm String',
    description:
        'Rounder and longer ringing, closer to a muted string bed — dark '
        'filter and a long release let notes blend into a soft pad-like tail.',
    build: () => KarplusStrongParams(
      decay: 0.70,
      damping: 0.38,
      tone: 0.36,
      stretch: 0.30,
      pickPosition: 0.44,
      attackColor: 0.30,
      body: 0.42,
      drive: 0.08,
      volume: 0.88,
      filterCutoff: 0.42,
      filterResonance: 0.10,
      filterMode: SynthFilterMode.lowPass,
      filterEnvAmt: 0.08,
      ampAttack: 0.02,
      ampDecay: 0.0,
      ampSustain: 1.0,
      ampRelease: 0.35,
    ),
  ),
  KarplusStrongPreset(
    name: 'Wood Box',
    description:
        'Body-heavy resonant pluck with a woody box resonance — a tuned '
        'bandpass filter emphasizes the box cavity for a distinctly hollow knock.',
    build: () => KarplusStrongParams(
      decay: 0.58,
      damping: 0.46,
      tone: 0.42,
      stretch: 0.18,
      pickPosition: 0.34,
      attackColor: 0.36,
      body: 0.60,
      drive: 0.08,
      volume: 0.90,
      filterCutoff: 0.42,
      filterResonance: 0.32,
      filterMode: SynthFilterMode.bandPass,
      filterEnvAmt: 0.18,
      ampAttack: 0.0,
      ampDecay: 0.12,
      ampSustain: 0.75,
      ampRelease: 0.18,
    ),
  ),
  KarplusStrongPreset(
    name: 'Glass String',
    description:
        'Clean bright sustain with more shimmer than wood — a resonant peak '
        'near the top end rings sympathetically as the note trails off.',
    build: () => KarplusStrongParams(
      decay: 0.74,
      damping: 0.72,
      tone: 0.64,
      stretch: 0.34,
      pickPosition: 0.20,
      attackColor: 0.66,
      body: 0.20,
      drive: 0.03,
      volume: 0.86,
      filterCutoff: 0.88,
      filterResonance: 0.28,
      filterMode: SynthFilterMode.lowPass,
      filterEnvAmt: 0.12,
      ampAttack: 0.0,
      ampDecay: 0.0,
      ampSustain: 1.0,
      ampRelease: 0.30,
    ),
  ),
  KarplusStrongPreset(
    name: 'Bell',
    description:
        'Long sustain with more stiffness for bell-like overtones — a wide '
        'filter sweep opens brightly on the strike, then mellows into a long hum.',
    build: () => KarplusStrongParams(
      decay: 0.88,
      damping: 0.30,
      tone: 0.34,
      stretch: 0.72,
      pickPosition: 0.62,
      attackColor: 0.40,
      body: 0.22,
      drive: 0.04,
      volume: 0.85,
      filterCutoff: 0.30,
      filterResonance: 0.22,
      filterMode: SynthFilterMode.lowPass,
      filterEnvAmt: 0.55,
      ampAttack: 0.0,
      ampDecay: 0.30,
      ampSustain: 0.55,
      ampRelease: 0.45,
    ),
  ),
  KarplusStrongPreset(
    name: 'Chime',
    description:
        'A lighter, cleaner bell with less harsh upper bite — a gentler '
        'filter sweep and shorter bloom keep it airy rather than clangy.',
    build: () => KarplusStrongParams(
      decay: 0.80,
      damping: 0.44,
      tone: 0.40,
      stretch: 0.42,
      pickPosition: 0.56,
      attackColor: 0.34,
      body: 0.16,
      drive: 0.01,
      volume: 0.88,
      filterCutoff: 0.55,
      filterResonance: 0.10,
      filterMode: SynthFilterMode.lowPass,
      filterEnvAmt: 0.30,
      ampAttack: 0.0,
      ampDecay: 0.25,
      ampSustain: 0.65,
      ampRelease: 0.40,
    ),
  ),
  KarplusStrongPreset(
    name: 'Harp',
    description:
        'Open and bright with a touch of string stiffness — notes ring out '
        'gently with a soft, sustained release, like a plucked harp string.',
    build: () => KarplusStrongParams(
      decay: 0.60,
      damping: 0.74,
      tone: 0.58,
      stretch: 0.20,
      pickPosition: 0.26,
      attackColor: 0.58,
      body: 0.38,
      drive: 0.12,
      volume: 0.90,
      filterCutoff: 0.85,
      filterResonance: 0.10,
      filterMode: SynthFilterMode.lowPass,
      filterEnvAmt: 0.20,
      ampAttack: 0.0,
      ampDecay: 0.10,
      ampSustain: 0.85,
      ampRelease: 0.28,
    ),
  ),
  KarplusStrongPreset(
    name: 'Picked Bass',
    description:
        'Short low pluck with body and edge for bass duties — a tight, '
        'filtered low end with a quick attack "pop" and a snappy release '
        'that stays out of the way rhythmically.',
    build: () => KarplusStrongParams(
      decay: 0.40,
      damping: 0.30,
      tone: 0.40,
      stretch: 0.06,
      pickPosition: 0.14,
      attackColor: 0.54,
      body: 0.54,
      drive: 0.22,
      volume: 0.92,
      filterCutoff: 0.38,
      filterResonance: 0.15,
      filterMode: SynthFilterMode.lowPass,
      filterEnvAmt: 0.25,
      ampAttack: 0.0,
      ampDecay: 0.15,
      ampSustain: 0.70,
      ampRelease: 0.08,
    ),
  ),
  KarplusStrongPreset(
    name: 'Electric Wire',
    description:
        'Sharper attack and grit for an electric-string flavor — a resonant '
        'bandpass adds a wiry, slightly nasal edge with a tight response.',
    build: () => KarplusStrongParams(
      decay: 0.52,
      damping: 0.70,
      tone: 0.68,
      stretch: 0.24,
      pickPosition: 0.16,
      attackColor: 0.78,
      body: 0.28,
      drive: 0.34,
      volume: 0.88,
      filterCutoff: 0.65,
      filterResonance: 0.30,
      filterMode: SynthFilterMode.bandPass,
      filterEnvAmt: 0.20,
      ampAttack: 0.0,
      ampDecay: 0.10,
      ampSustain: 0.80,
      ampRelease: 0.10,
    ),
  ),
  KarplusStrongPreset(
    name: 'Dusty Lo-Fi',
    description:
        'Dark, thumpy and slightly dirty for worn-out machine tones — a '
        'heavily closed, static filter keeps it dull with a soft, muffled tail.',
    build: () => KarplusStrongParams(
      decay: 0.46,
      damping: 0.22,
      tone: 0.24,
      stretch: 0.14,
      pickPosition: 0.38,
      attackColor: 0.44,
      body: 0.50,
      drive: 0.40,
      volume: 0.82,
      filterCutoff: 0.30,
      filterResonance: 0.08,
      filterMode: SynthFilterMode.lowPass,
      filterEnvAmt: 0.05,
      ampAttack: 0.0,
      ampDecay: 0.18,
      ampSustain: 0.60,
      ampRelease: 0.12,
    ),
  ),
];