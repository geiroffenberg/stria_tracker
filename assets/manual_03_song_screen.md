# Stria — User Manual: Song Screen

The Song screen is where you build the arrangement of your track.

---

## Layout

- **Left column** — numbered pattern slots. These are **tap-only playhead markers**: tapping a slot jumps playback (or the edit focus) to that pattern. They have no long-press action.
- **Right column** — interactive mini-timeline showing all 16 tracks for every pattern slot. All track-editing gestures (select, move, copy, cut, paste) happen here. A horizontal line marks the current playback position.

## Pattern Slots

Each slot represents one pattern. The song plays slots from top to bottom in sequence. Tap a slot number to focus that pattern for the playhead; no other actions are attached to the row numbers.

## Timeline Track Numbers — Solo

The numbers (1–16) shown above each lane in the right-hand timeline are **tappable solo buttons**. Tapping a track number solos that track — identical to pressing the Solo button in the Mixer screen or the pattern track header. The number turns red while the track is soloed. Tapping it again un-solos it. Solo state is global: it shows in red in all three places (Song timeline, Pattern header, Mixer) simultaneously.

## Track Cell Editing from the Song View

You can select, copy, cut, paste, and delete the contents of any track — or any
**rectangular block of tracks** across several patterns — without leaving the
Song screen.

### Single-cell selection

1. **Tap** a track cell in the timeline. The cell gets a green border, and an
   action bar appears at the bottom of the screen. Tapping never opens the
   Pattern view — it only selects.
2. To open the Pattern view at the currently-selected cell, tap the
   **PATTERN** tab at the top of the screen. The Pattern view opens focused on
   the selected pattern and track. With no selection, PATTERN opens on
   whatever pattern/track are already current.
3. Use the action bar buttons:

| Button | Action |
|---|---|
| CUT | Copy the selection to the clipboard, then clear it |
| COPY | Copy the selection to the clipboard (source unchanged) |
| PASTE | Paste the clipboard, top-left aligned to the current selection |
| INS | Insert a new empty pattern slot immediately after the selection |
| DUP | Duplicate the selected pattern, inserting the copy immediately after it |
| DEL | Clear the selection to empty |
| ✕ | Dismiss the selection |

INS and DUP act on whole **pattern slots** in the arrangement rather than on
cell contents — patterns below the insertion point shift down to make room
(the song holds a fixed 99 slots, so the operation is refused if the last
slot already contains data). DUP also carries over the source pattern's
settings (BPM, beats, swing, LPB, beat overrides, FX envelopes), not just its
notes — equivalent to inserting an empty pattern and then copy/pasting every
cell, but in one step. For a multi-row selection, INS inserts after the
bottom-most selected row and DUP duplicates the pattern at the top of the
selection.

### Multi-cell selection

Once a cell is selected, **long-press another cell** — the selection expands
to cover the full rectangle spanning both cells, in either direction (vertically
across pattern rows, horizontally across tracks, or both). You can keep
long-pressing further cells to move the far corner of the range around.

The action bar operates on the whole selection:

- **CUT / COPY** save the entire rectangular block to a dedicated Song
  clipboard.
- **PASTE** writes the clipboard so its top-left aligns with the top-left of
  the current selection. The pasted area always uses the clipboard's own
  dimensions (a larger selection at the target just marks the start point).
- **DEL** clears every cell in the selection.

If any of the target cells already contain data, PASTE opens a dialog with
**Overwrite** or **Swap** — the choice applies to the whole block (Swap
carries the previous target contents into the clipboard so you can move them
elsewhere with another paste).

After CUT, COPY, PASTE, or DEL the selection is cleared automatically, so the
very next tap starts a fresh selection at the paste target.

### Drag and drop (single cell)

You can also **long-press** a single cell and — without lifting your finger —
drag it onto another track cell. Releasing offers Overwrite / Swap when the
target already has data (same as the multi-cell paste dialog). This shortcut
is only available for single-cell drags; extend a range with a second
long-press to work on multiple cells.

Track numbers (1–16) are fixed and cannot be reordered — tapping a track number toggles solo for that channel instead.

## Undo / Redo

The Song screen header contains two arrow buttons — **undo** (left) and **redo** (right) — next to the edit and menu icons.

- Up to **50 undo steps** are stored per session.
- Every song-level mutation is tracked: append pattern, insert pattern, move up/down, duplicate, merge, double, and delete.
- The tooltip on each button shows what action would be undone or redone (e.g. "Undo: delete pattern").
- Undo and redo apply only to the **arrangement** (pattern order, count, structure). Per-pattern note edits have their own separate undo stack accessible from the Pattern screen.

> **Note:** The undo history is session-only — it is cleared when the project is reloaded.

## Menu

The top-right menu provides:

| Item | Description |
|---|---|
| New Song | Clear everything and start fresh |
| Save Song | Write the project to the project folder |
| Load Song | Open a scrollable list of saved projects in a bottom sheet; tap a name to load |
| Choose Project Folder | Set the root folder where projects are saved |
| Export WAV | Bounce the full song to a stereo WAV file |
| Change Palette | Cycle the colour theme |
