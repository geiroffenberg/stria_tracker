import 'dart:math';

import 'cell.dart';

/// Metadata for an interpolated FX value run. Stored as a flat list on
/// [PatternModel] so the UI can draw a visual envelope box + curve overlay
/// spanning the interpolated rows, and the user can re-shape the curve with a
/// gamma slider without touching the baked cell values until confirmed.
class FxEnvelopeRun {
  final int trackIndex;
  final int fxSlotIndex; // 0, 1, or 2
  final int startRow;    // anchor row (has a value, not filled by interp)
  final int endRow;      // anchor row (has a value, not filled by interp)
  final int startValue;  // 0–99
  final int endValue;    // 0–99
  double gamma;          // 1.0 = linear, >1 = slow-start/fast-end, <1 = fast-start

  FxEnvelopeRun({
    required this.trackIndex,
    required this.fxSlotIndex,
    required this.startRow,
    required this.endRow,
    required this.startValue,
    required this.endValue,
    this.gamma = 1.0,
  });

  /// The FX value column for this slot (fx0val / fx1val / fx2val).
  CellColumn get valColumn {
    switch (fxSlotIndex) {
      case 0:
        return CellColumn.fx0val;
      case 1:
        return CellColumn.fx1val;
      case 2:
        return CellColumn.fx2val;
      default:
        return CellColumn.fx0val;
    }
  }

  /// The FX command column for this slot (fx0cmd / fx1cmd / fx2cmd).
  CellColumn get cmdColumn {
    switch (fxSlotIndex) {
      case 0:
        return CellColumn.fx0cmd;
      case 1:
        return CellColumn.fx1cmd;
      case 2:
        return CellColumn.fx2cmd;
      default:
        return CellColumn.fx0cmd;
    }
  }

  /// Compute the gamma-curved interpolated value for a normalised time
  /// [t] ∈ [0, 1], where 0 corresponds to [startRow] and 1 to [endRow].
  int valueAt(double t) {
    final curved = pow(t.clamp(0.0, 1.0), gamma).toDouble();
    return (startValue + (endValue - startValue) * curved).round().clamp(0, 99);
  }

  /// True if [row] is strictly between the anchors (an interior filled row).
  bool containsInteriorRow(int row) => row > startRow && row < endRow;

  /// True if [row] is anywhere in the run, including the anchor endpoints.
  bool containsRow(int row) => row >= startRow && row <= endRow;

  Map<String, dynamic> toJson() => {
    'ti': trackIndex,
    'fs': fxSlotIndex,
    'sr': startRow,
    'er': endRow,
    'sv': startValue,
    'ev': endValue,
    'ga': gamma,
  };

  factory FxEnvelopeRun.fromJson(Map<String, dynamic> j) => FxEnvelopeRun(
    trackIndex: j['ti'] as int,
    fxSlotIndex: j['fs'] as int,
    startRow: j['sr'] as int,
    endRow: j['er'] as int,
    startValue: j['sv'] as int,
    endValue: j['ev'] as int,
    gamma: (j['ga'] as num?)?.toDouble() ?? 1.0,
  );
}
