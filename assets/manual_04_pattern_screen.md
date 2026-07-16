# Stria — User Manual: Pattern Screen

The Pattern screen is the main composition view. It shows all tracks for the currently selected pattern as a scrolling grid.

---

## The Grid

Each **row** is one line of music. Each **column** is one track. The playhead (highlighted row) steps through rows at the speed defined by BPM and LPB.

## Cell Columns

Each track cell contains up to four fields:

```
NOTE   INST   VOL   FX   VAL
C-4    01     75    PAN  50
```

| Field | Description |
|---|---|
| NOTE | The note to play (`C-4`, `D#3`, `OFF`, `---`) |
| INST | `--` = hold/carry (no trigger); `00` = pitch-change only (no retrigger, glide applies); `01`–`16` = trigger with that instrument slot |
| VOL | Per-cell volume override (00–99) |
| FX | Effect command (3-letter code) |
| VAL | Effect value (00–99) |

Multiple FX slots per cell are supported.

## Note Entry

- Notes are entered in chromatic order. The note picker scrolls through the 10 available octaves (0–9).
- `OFF` sends a note-off (stops the current note on that track).
- `---` leaves the field empty (the previous note continues to hold).

## Pattern Settings

BPM (tempo) and LPB (Lines Per Beat) are set per pattern. Changing them mid-song is supported — each pattern can have its own tempo.

| Setting | Range | Description |
|---|---|---|
| BPM | 20–300 | Beats per minute |
| LPB | 1–16 | Lines (rows) per beat — controls rhythmic resolution |

## Pattern Menu

The top-right ⌄ menu (next to the pattern name) provides:

| Item | Description |
|---|---|
| Undo / Redo | Undo or redo the last pattern edit |
| Clear pattern | Erase every cell in the pattern (mixer settings and timing are kept) |
| Reset to defaults | Clear cells and reset BPM, beats, and LPB to defaults |
| Swing | Set a swing percentage (0 = straight, 99 = maximum shuffle) |
| Copy to Sampler | Render the pattern (or selected rows) to a WAV and load it into the first free instrument slot as a sampler |

## Copy Pattern to Sampler

"Copy to Sampler" is a **non-destructive freeze** — it records whatever the engine would play right now and saves it as a new sample.

**How it works:**
1. Select **Copy to Sampler** from the pattern menu.
2. The engine plays the pattern once (non-looping). A progress spinner is shown.
3. The stereo output is captured, encoded as a WAV, and saved to the project samples folder.
4. The file is loaded into the **first empty instrument slot** as a sampler. You are navigated to that slot automatically.
5. A snack bar confirms which slot number was used.

**Respects solo and selection:**
- Solo a track first → only that track's audio is captured.
- Select rows in the pattern first → only that row range is rendered and the WAV will contain exactly those rows.
- Do nothing special → the full mix of all active tracks is captured.

**Use cases:**
- Bounce a complex multi-track pattern down to a single note — place `C-4` with the new instrument number in a track to replay the whole thing at zero CPU cost.
- Resample a track with effects applied for new sound design material.
- Create a melodic loop from a generative or arpeggiated pattern.

The original pattern is never modified.

## Row Selection and Playback Range

When one or more rows are selected (by tapping row numbers in the Pattern screen), pressing **Play** honours the selection:

- **Single row or range selected** — playback starts at the first selected row.
- **Loop enabled** — only the selected rows loop; playback does not wrap to rows outside the selection.
- **No selection** — playback behaves normally (full pattern from the current cursor position).

This makes it easy to audition a fill, check a transition, or loop a specific beat without moving the cursor.

## Views

- **Normal view** — all tracks visible in full detail, with NOTE and IN (instrument) columns visible side-by-side. Horizontal scrolling lets you pan across tracks.

- **Collapsed view** — all tracks compressed into a compact grid showing only NOTE and IN columns, allowing a full overview of the pattern at once. Useful for arranging melodies across multiple tracks.

- **Drum mode** — ultra-compact layout where each track shows only a single instrument pill (IN column). The NOTE column is hidden. This mode is optimized for drum kit programming where each track typically corresponds to one drum sound. **Bonus feature:** when you tap an empty instrument cell in drum mode, it automatically fills with the track number (1-based), so track 1 defaults to instrument 01, track 2 to instrument 02, etc. This speeds up setup for kit-style arrangements where drum sounds are naturally distributed across slots.

### Drum Mode Velocity Control

In drum mode, each drum hit supports three velocity (volume) states, accessed by **single-tapping** a drum pill:

| Tap Sequence | State | Appearance | Volume |
|---|---|---|---|
| 1st tap | Default | Solid pill | Track default |
| 2nd tap | Accent | Gradient (complement → accent) | 99 (loud) |
| 3rd tap | Half | Gradient (accent → complement) | 50 (quiet) |
| 4th tap | Empty | (cleared) | — |

**How to use:**
- Tap the drum pill once: cycles to the next state (Default → Accent → Half → Empty).
- **Double-tap** any state: immediately clears the cell (deletes the note).
- Each state's gradient provides instant visual feedback — bright overlays indicate accent hits.

**Example workflow:**
1. Build a drum pattern with steady hits in **Default** state.
2. Single-tap accent hits to brighten key moments (kick on beat 1, snare on beat 2).
3. Single-tap half hits for ghost notes or quiet ghost snares.
4. The gradient colors auto-adapt to your theme — no manual color tweaking needed.
