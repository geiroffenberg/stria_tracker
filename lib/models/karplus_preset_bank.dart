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
    ),
  ),
  KarplusStrongPreset(
    name: 'Bright Pluck',
    description: 'Fast, bright and direct for melodic picking lines.',
    build: () => KarplusStrongParams(
      decay: 0.42,
      damping: 0.82,
      tone: 0.78,
      stretch: 0.12,
      pickPosition: 0.12,
      attackColor: 0.86,
      body: 0.24,
      drive: 0.18,
    ),
  ),
  KarplusStrongPreset(
    name: 'Muted Pick',
    description: 'Short, dry and percussive for muted riffs and ghost notes.',
    build: () => KarplusStrongParams(
      decay: 0.26,
      damping: 0.52,
      tone: 0.34,
      stretch: 0.08,
      pickPosition: 0.10,
      attackColor: 0.62,
      body: 0.18,
      drive: 0.14,
    ),
  ),
  KarplusStrongPreset(
    name: 'Nylon',
    description: 'Soft attack and warm body for a gentler plucked-string feel.',
    build: () => KarplusStrongParams(
      decay: 0.48,
      damping: 0.40,
      tone: 0.28,
      stretch: 0.10,
      pickPosition: 0.42,
      attackColor: 0.18,
      body: 0.46,
      drive: 0.02,
    ),
  ),
  KarplusStrongPreset(
    name: 'Warm String',
    description: 'Rounder and longer ringing, closer to a muted string bed.',
    build: () => KarplusStrongParams(
      decay: 0.70,
      damping: 0.38,
      tone: 0.36,
      stretch: 0.30,
      pickPosition: 0.44,
      attackColor: 0.30,
      body: 0.42,
      drive: 0.08,
    ),
  ),
  KarplusStrongPreset(
    name: 'Wood Box',
    description: 'Body-heavy resonant pluck with a woody box resonance.',
    build: () => KarplusStrongParams(
      decay: 0.58,
      damping: 0.46,
      tone: 0.42,
      stretch: 0.18,
      pickPosition: 0.34,
      attackColor: 0.36,
      body: 0.60,
      drive: 0.08,
    ),
  ),
  KarplusStrongPreset(
    name: 'Glass String',
    description: 'Clean bright sustain with more shimmer than wood.',
    build: () => KarplusStrongParams(
      decay: 0.74,
      damping: 0.72,
      tone: 0.64,
      stretch: 0.34,
      pickPosition: 0.20,
      attackColor: 0.66,
      body: 0.20,
      drive: 0.03,
    ),
  ),
  KarplusStrongPreset(
    name: 'Bell',
    description: 'Long sustain with more stiffness for bell-like overtones.',
    build: () => KarplusStrongParams(
      decay: 0.88,
      damping: 0.30,
      tone: 0.34,
      stretch: 0.72,
      pickPosition: 0.62,
      attackColor: 0.40,
      body: 0.22,
      drive: 0.04,
    ),
  ),
  KarplusStrongPreset(
    name: 'Chime',
    description: 'A lighter, cleaner bell with less harsh upper bite.',
    build: () => KarplusStrongParams(
      decay: 0.80,
      damping: 0.44,
      tone: 0.40,
      stretch: 0.42,
      pickPosition: 0.56,
      attackColor: 0.34,
      body: 0.16,
      drive: 0.01,
    ),
  ),
  KarplusStrongPreset(
    name: 'Harp',
    description: 'Open and bright with a touch of string stiffness.',
    build: () => KarplusStrongParams(
      decay: 0.60,
      damping: 0.74,
      tone: 0.58,
      stretch: 0.20,
      pickPosition: 0.26,
      attackColor: 0.58,
      body: 0.38,
      drive: 0.12,
    ),
  ),
  KarplusStrongPreset(
    name: 'Picked Bass',
    description: 'Short low pluck with body and edge for bass duties.',
    build: () => KarplusStrongParams(
      decay: 0.40,
      damping: 0.30,
      tone: 0.40,
      stretch: 0.06,
      pickPosition: 0.14,
      attackColor: 0.54,
      body: 0.54,
      drive: 0.22,
    ),
  ),
  KarplusStrongPreset(
    name: 'Electric Wire',
    description: 'Sharper attack and grit for an electric-string flavor.',
    build: () => KarplusStrongParams(
      decay: 0.52,
      damping: 0.70,
      tone: 0.68,
      stretch: 0.24,
      pickPosition: 0.16,
      attackColor: 0.78,
      body: 0.28,
      drive: 0.34,
    ),
  ),
  KarplusStrongPreset(
    name: 'Dusty Lo-Fi',
    description: 'Dark, thumpy and slightly dirty for worn-out machine tones.',
    build: () => KarplusStrongParams(
      decay: 0.46,
      damping: 0.22,
      tone: 0.24,
      stretch: 0.14,
      pickPosition: 0.38,
      attackColor: 0.44,
      body: 0.50,
      drive: 0.40,
    ),
  ),
];