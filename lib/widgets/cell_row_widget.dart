import 'dart:math' show pow;

import 'package:flutter/material.dart';
import '../models/cell.dart';
import '../models/fx_envelope_run.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'cell_widget.dart';

/// One complete row in the tracker grid (row number + all visible columns).
class CellRowWidget extends StatelessWidget {
  final int trackIndex;
  final int row;
  final TrackerCell cell;
  final bool isSelected; // true if ANY column in this row is selected
  final bool isPlayhead;
  final CellPosition? selectedCell;
  final bool collapsed; // if true, show only NOTE and INST columns

  const CellRowWidget({
    super.key,
    required this.trackIndex,
    required this.row,
    required this.cell,
    required this.isSelected,
    required this.isPlayhead,
    required this.selectedCell,
    required this.collapsed,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final isRowSelected = state.isRowInSelection(row);
    final isBeatStart = state.isBeatStart(row);
    final beat = isBeatStart ? state.beatForRow(row) : -1;
    final bg = rowBgColor(row, isSelected, isPlayhead, state.linesPerBeat);
    final rowNumStyle = isBeatStart
        ? kStyleRowNum.copyWith(color: kColAccent)
        : kStyleRowNum.copyWith(color: kColRowNum);

    // Which columns are visible
    final cols = collapsed
        ? [CellColumn.note, CellColumn.instrument]
        : CellColumn.values;

    // Beat subdivision long-press is suppressed when any row in the beat has
    // data (avoids trampling notes, FX, or envelope anchors).
    final beatHasData =
        isBeatStart &&
        (() {
          final beatRowCount = state.linesForBeat(beat);
          for (int r = row; r < row + beatRowCount; r++) {
            for (final t in state.currentPattern.tracks) {
              if (r < t.cells.length && !t.cells[r].isEmpty) return true;
            }
          }
          return false;
        })();

    final rowContainer = Container(
      height: kRowHeight,
      decoration: BoxDecoration(
        color: bg,
        border: !isRowSelected && isBeatStart && row > 0
            ? Border(top: BorderSide(color: kColAccent.withAlpha(60), width: 1))
            : null,
      ),
      child: Row(
        children: [
          // Row number — tap to toggle whole-row selection.
          // Long-press on a beat-start row opens the beat subdivision menu,
          // but only when the row has no data (avoids conflicting with envelopes
          // or any other content the user placed there).
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => state.selectRow(row),
            onLongPress: isBeatStart && !beatHasData
                ? () => _showBeatLinesMenu(context, state, beat)
                : null,
            child: SizedBox(
              width: kWRow,
              height: kRowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    (row + 1).toString().padLeft(2, '0'),
                    style: rowNumStyle,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          // Data columns — FX cmd+val pairs are grouped for envelope overlay.
          ..._buildDataColumns(context, state, cols),
        ],
      ),
    );
    if (isRowSelected) {
      return CustomPaint(
        foregroundPainter: _DottedRowBorderPainter(kColSelection),
        child: rowContainer,
      );
    }
    return rowContainer;
  }

  /// Builds the data column widgets. FX cmd+val column pairs are handled
  /// together so that an envelope run can wrap both in a single decorated box.
  List<Widget> _buildDataColumns(
    BuildContext context,
    AppState state,
    List<CellColumn> cols,
  ) {
    final widgets = <Widget>[];
    final Set<CellColumn> handled = {};

    for (final col in cols) {
      if (handled.contains(col)) continue;

      // Check whether this is an FX cmd column with a matching val column.
      int slotIndex = -1;
      CellColumn? valCol;
      if (col == CellColumn.fx0cmd) {
        slotIndex = 0;
        valCol = CellColumn.fx0val;
      } else if (col == CellColumn.fx1cmd) {
        slotIndex = 1;
        valCol = CellColumn.fx1val;
      } else if (col == CellColumn.fx2cmd) {
        slotIndex = 2;
        valCol = CellColumn.fx2val;
      }

      if (slotIndex >= 0 && valCol != null && cols.contains(valCol)) {
        handled.add(valCol);

        final cmdWidget = SizedBox(
          width: kWFxCmd,
          height: kRowHeight,
          child: CellWidget(
            trackIndex: trackIndex,
            row: row,
            column: col,
            cell: cell,
            isSelected: selectedCell?.row == row && selectedCell?.column == col,
          ),
        );
        final valWidget = SizedBox(
          width: kWFxVal,
          height: kRowHeight,
          child: CellWidget(
            trackIndex: trackIndex,
            row: row,
            column: valCol,
            cell: cell,
            isSelected:
                selectedCell?.row == row && selectedCell?.column == valCol,
          ),
        );

        final run = state.fxEnvelopeAt(trackIndex, slotIndex, row);

        if (run != null) {
          final envelopeColor = columnColor(valCol);
          final totalRows = run.endRow - run.startRow;
          final isFirst = row == run.startRow;
          final isLast = row == run.endRow;
          // Denominator = totalRows + 1 (number of rows in the run, not spans)
          // so t=0 is the very top of startRow and t=1 is the very bottom of
          // endRow, making the curve span the full box height.
          final denom = totalRows + 1;
          final t0 = denom == 0 ? 0.0 : (row - run.startRow) / denom;
          final t1 = denom == 0
              ? 1.0
              : ((row + 1 - run.startRow) / denom).clamp(0.0, 1.0);

          final borderSide = BorderSide(
            color: envelopeColor.withAlpha(204),
            width: 1.5,
          );
          final border = Border(
            top: isFirst ? borderSide : BorderSide.none,
            bottom: isLast ? borderSide : BorderSide.none,
            left: borderSide,
            right: borderSide,
          );

          const pairWidth = kWFxCmd + 2.0 + kWFxVal;
          widgets.add(
            SizedBox(
              width: pairWidth,
              height: kRowHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(border: border),
                child: Stack(
                  children: [
                    Row(
                      children: [
                        cmdWidget,
                        const SizedBox(width: 2),
                        valWidget,
                      ],
                    ),
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _EnvelopeCurvePainter(
                          ascending: run.startValue <= run.endValue,
                          gamma: run.gamma,
                          color: envelopeColor,
                          t0: t0,
                          t1: t1,
                          totalWidth: pairWidth,
                        ),
                      ),
                    ),
                    // Tap/long-press interceptor — sits above the curve and
                    // cell widgets so envelope taps open the envelope menu
                    // instead of the normal cell action bar.
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _showEnvelopeMenu(context, state, run),
                        // Absorb long-press so the track's box-selection
                        // gesture detector doesn't trigger inside a run.
                        onLongPress: () {},
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        } else {
          widgets.add(cmdWidget);
          widgets.add(const SizedBox(width: 2));
          widgets.add(valWidget);
        }

        // Gap after the val column.
        widgets.add(SizedBox(width: _gapAfter(valCol)));
        continue;
      }

      // Default: single column (note, inst, vol, or an fxval without its cmd).
      widgets.add(
        SizedBox(
          width: _colWidth(col),
          height: kRowHeight,
          child: CellWidget(
            trackIndex: trackIndex,
            row: row,
            column: col,
            cell: cell,
            isSelected: selectedCell?.row == row && selectedCell?.column == col,
          ),
        ),
      );
      widgets.add(SizedBox(width: _gapAfter(col)));
    }

    return widgets;
  }

  /// Opens a modal bottom sheet for the envelope run: gamma slider (live
  /// re-bake) and a remove button.
  static Future<void> _showEnvelopeMenu(
    BuildContext context,
    AppState state,
    FxEnvelopeRun run,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgTrackHeader,
      barrierColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final envelopeColor = columnColor(run.valColumn);
            final envelopeFaint = envelopeColor.withAlpha(68);
            final rows = run.endRow - run.startRow;
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  Row(
                    children: [
                      Text(
                        'ENVELOPE  rows ${run.startRow + 1}–${run.endRow + 1}'
                        '  ($rows steps)  '
                        '${run.startValue}→${run.endValue}',
                        style: kStyleBase.copyWith(
                          color: envelopeColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: () => Navigator.pop(sheetCtx),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        splashRadius: 18,
                        icon: Text(
                          '✕',
                          style: kStyleBase.copyWith(
                            color: kColHeader,
                            fontSize: 18,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Gamma row
                  Row(
                    children: [
                      SizedBox(
                        width: 72,
                        child: Text(
                          'γ  ${run.gamma.toStringAsFixed(2)}',
                          style: kStyleBase.copyWith(
                            color: envelopeColor,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 4,
                            activeTrackColor: envelopeColor,
                            inactiveTrackColor: envelopeFaint,
                            thumbColor: envelopeColor,
                            overlayColor: envelopeColor.withAlpha(34),
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 10,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 20,
                            ),
                          ),
                          child: Slider(
                            value: run.gamma.clamp(0.1, 4.0),
                            min: 0.1,
                            max: 4.0,
                            divisions: 39, // 0.1 steps
                            onChanged: (v) {
                              state.updateEnvelopeGamma(run, v);
                              setModalState(() {});
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Hint row
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 8),
                    child: Text(
                      run.gamma < 0.95
                          ? 'Fast start → slow end'
                          : run.gamma > 1.05
                          ? 'Slow start → fast end'
                          : 'Linear',
                      style: kStyleBase.copyWith(
                        color: kColInactive,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  Divider(color: envelopeFaint),
                  const SizedBox(height: 4),
                  // Remove button
                  GestureDetector(
                    onTap: () {
                      state.deleteEnvelope(run);
                      Navigator.of(sheetCtx).pop();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: kColStopBtn.withAlpha(30),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: kColStopBtn.withAlpha(100)),
                      ),
                      child: Text(
                        'REMOVE ENVELOPE',
                        textAlign: TextAlign.center,
                        style: kStyleBase.copyWith(
                          color: kColStopBtn,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  static double _colWidth(CellColumn col) {
    switch (col) {
      case CellColumn.note:
        return kWNote;
      case CellColumn.instrument:
        return kWInst;
      case CellColumn.volume:
        return kWVol;
      case CellColumn.fx0cmd:
      case CellColumn.fx1cmd:
      case CellColumn.fx2cmd:
        return kWFxCmd;
      case CellColumn.fx0val:
      case CellColumn.fx1val:
      case CellColumn.fx2val:
        return kWFxVal;
    }
  }

  static double _gapAfter(CellColumn col) {
    switch (col) {
      case CellColumn.note:
        return kWGap;
      case CellColumn.instrument:
        return kWGap;
      case CellColumn.volume:
        return kWGap;
      case CellColumn.fx0cmd:
        return 2;
      case CellColumn.fx0val:
        return kWGap;
      case CellColumn.fx1cmd:
        return 2;
      case CellColumn.fx1val:
        return kWGap;
      case CellColumn.fx2cmd:
        return 2;
      case CellColumn.fx2val:
        return 0;
    }
  }

  /// Long-press context menu for beat-start rows — lets the user set or clear
  /// the per-beat line count override (1–16, or reset to pattern default).
  /// Uses int where 0 = "reset to default".
  static Future<void> _showBeatLinesMenu(
    BuildContext context,
    AppState state,
    int beat,
  ) async {
    final currentOverride = state.beatLineOverride(beat);
    final defaultLpb = state.linesPerBeat;

    // 0 = reset to default; 1-16 = override.
    final options = <PopupMenuEntry<int>>[
      PopupMenuItem<int>(
        value: 0,
        child: Text(
          'Default ($defaultLpb lines)',
          style: kStyleBase.copyWith(
            color: currentOverride == null ? kColAccent : kColHeader,
            fontWeight: currentOverride == null
                ? FontWeight.bold
                : FontWeight.normal,
          ),
        ),
      ),
      const PopupMenuDivider(),
      for (int n = 1; n <= 16; n++)
        PopupMenuItem<int>(
          value: n,
          child: Text(
            '$n line${n == 1 ? '' : 's'}${n == defaultLpb ? ' (default)' : ''}',
            style: kStyleBase.copyWith(
              color: currentOverride == n ? kColAccent : kColHeader,
              fontWeight: currentOverride == n
                  ? FontWeight.bold
                  : FontWeight.normal,
            ),
          ),
        ),
    ];

    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final Offset offset = box?.localToGlobal(Offset.zero) ?? Offset.zero;
    final RelativeRect position = RelativeRect.fromLTRB(
      offset.dx,
      offset.dy,
      offset.dx + (box?.size.width ?? 80),
      offset.dy + (box?.size.height ?? 24),
    );

    final chosen = await showMenu<int>(
      context: context,
      position: position,
      color: kBgTrackHeader,
      items: options,
    );

    if (!context.mounted || chosen == null) return; // dismissed
    // 0 = reset to default, otherwise set override.
    state.setBeatLineOverride(beat, chosen == 0 ? null : chosen);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Envelope curve painter
// ─────────────────────────────────────────────────────────────────────────────

/// Draws a single row's slice of the gamma-curved envelope as a diagonal line
/// inside the combined cmd+val cell area. The x-axis maps interpolated value
/// Draws one row-slice of a corner-to-corner gamma curve.
/// Ascending (startValue ≤ endValue): top-left → bottom-right.
/// Descending: top-right → bottom-left.
/// The x position at normalised time [t] is:
///   ascending  → pow(t, gamma) * totalWidth
///   descending → (1 - pow(t, gamma)) * totalWidth
class _EnvelopeCurvePainter extends CustomPainter {
  final bool ascending;
  final double gamma;
  final Color color;
  final double t0; // normalised run position at top of this row
  final double t1; // normalised run position at bottom of this row
  final double totalWidth; // kWFxCmd + 2 + kWFxVal

  const _EnvelopeCurvePainter({
    required this.ascending,
    required this.gamma,
    required this.color,
    required this.t0,
    required this.t1,
    required this.totalWidth,
  });

  double _xAt(double t) {
    final curved = pow(t.clamp(0.0, 1.0), gamma).toDouble();
    return ascending ? curved * totalWidth : (1.0 - curved) * totalWidth;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cornerX = ascending ? totalWidth : 0.0;
    const samples = 10; // More samples = smoother curve within each row slice.

    // Build a polyline that samples the gamma curve inside this row so the
    // first/last row are also visibly curved instead of a single straight chord.
    final curvePath = Path();
    for (int i = 0; i <= samples; i++) {
      final u = i / samples;
      final t = t0 + (t1 - t0) * u;
      final y = size.height * u;
      final x = _xAt(t);
      if (i == 0) {
        curvePath.moveTo(x, y);
      } else {
        curvePath.lineTo(x, y);
      }
    }

    // Faint fill between the curve and the destination edge.
    final fillPath = Path.from(curvePath)
      ..lineTo(cornerX, size.height)
      ..lineTo(cornerX, 0)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..color = color.withAlpha(34)
        ..style = PaintingStyle.fill,
    );

    // Solid curve slice.
    canvas.drawPath(
      curvePath,
      Paint()
        ..color = color.withAlpha(204)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_EnvelopeCurvePainter old) =>
      old.ascending != ascending ||
      old.gamma != gamma ||
      old.color != color ||
      old.t0 != t0 ||
      old.t1 != t1;
}

/// Draws a fine dotted border around a row-selected line.
class _DottedRowBorderPainter extends CustomPainter {
  final Color color;
  const _DottedRowBorderPainter(this.color);

  static const double _dot = 2.0;
  static const double _gap = 3.0;

  void _drawDashed(Canvas canvas, Paint paint, Offset start, Offset end) {
    final total = (end - start).distance;
    if (total == 0) return;
    final dir = (end - start) / total;
    double d = 0;
    while (d < total) {
      canvas.drawLine(
        start + dir * d,
        start + dir * (d + _dot).clamp(0.0, total),
        paint,
      );
      d += _dot + _gap;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;
    _drawDashed(canvas, paint, Offset.zero, Offset(size.width, 0));                     // top
    _drawDashed(canvas, paint, Offset(0, size.height), Offset(size.width, size.height)); // bottom
    _drawDashed(canvas, paint, Offset.zero, Offset(0, size.height));                     // left
    _drawDashed(canvas, paint, Offset(size.width, 0), Offset(size.width, size.height));  // right
  }

  @override
  bool shouldRepaint(covariant _DottedRowBorderPainter old) => old.color != color;
}
