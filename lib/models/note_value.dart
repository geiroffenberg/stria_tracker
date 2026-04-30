/// Represents a note value in a tracker cell.
///
/// scrollIndex layout (used for up/down scroll interaction):
///   0       = empty  "---"
///   1–120   = C-0 to B-9  (12 notes × 10 octaves)
///   121     = OFF   "OFF"
class NoteValue {
  static const _noteNames = [
    'C', 'C#', 'D', 'D#', 'E', 'F',
    'F#', 'G', 'G#', 'A', 'A#', 'B',
  ];

  static const int _minScroll = 0;
  static const int _maxScroll = 121;

  final int scrollIndex;

  const NoteValue._(this.scrollIndex);

  static const NoteValue empty = NoteValue._(0);
  static const NoteValue off   = NoteValue._(121);

  static NoteValue fromScrollIndex(int i) =>
      NoteValue._(i.clamp(_minScroll, _maxScroll));

  bool get isEmpty => scrollIndex == 0;
  bool get isOff   => scrollIndex == 121;
  bool get isNote  => scrollIndex >= 1 && scrollIndex <= 120;

  NoteValue incremented() => fromScrollIndex(scrollIndex + 1);
  NoteValue decremented() => fromScrollIndex(scrollIndex - 1);

  /// Always 3-character string for display.
  String get display {
    if (isEmpty) return '---';
    if (isOff)   return 'OFF';
    final idx    = scrollIndex - 1; // 0–119
    final octave = idx ~/ 12;
    final name   = _noteNames[idx % 12];
    // Natural note: "C-4"; sharp note: "C#4" (already 3 chars)
    return name.length == 1 ? '$name-$octave' : '$name$octave';
  }

  @override
  bool operator ==(Object other) =>
      other is NoteValue && other.scrollIndex == scrollIndex;

  @override
  int get hashCode => scrollIndex.hashCode;
}
