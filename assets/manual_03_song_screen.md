# Stria — User Manual: Song Screen

The Song screen is where you build the arrangement of your track.

---

## Layout

- **Left column** — numbered pattern slots. Tap a slot to select it as the active pattern for editing. Long-press to open the action bar (move up/down, duplicate, delete).
- **Right column** — read-only mini-timeline showing all 16 tracks for every pattern slot. A horizontal line marks the current playback position.

## Pattern Slots

Each slot represents one pattern. The song plays slots from top to bottom in sequence.

## Actions (long-press on a slot)

| Action | Description |
|---|---|
| Move Up / Down | Reorder the slot in the arrangement |
| Duplicate | Insert a copy of the pattern directly below |
| Delete | Remove the slot from the arrangement |

## Timeline Track Numbers — Solo

The numbers (1–16) shown above each lane in the right-hand timeline are **tappable solo buttons**. Tapping a track number solos that track — identical to pressing the Solo button in the Mixer screen or the pattern track header. The number turns red while the track is soloed. Tapping it again un-solos it. Solo state is global: it shows in red in all three places (Song timeline, Pattern header, Mixer) simultaneously.

## Track Cell Editing from the Song View

You can copy, cut, paste, and delete the contents of any single track inside any pattern without leaving the Song screen.

1. **Long-press** a track cell in the timeline. The cell gets a green border, and an action bar appears at the bottom of the screen.
2. Use the action bar buttons:

| Button | Action |
|---|---|
| CUT | Copy all rows in that track to the clipboard, then clear them |
| COPY | Copy all rows in that track to the clipboard (track unchanged) |
| PASTE | Paste clipboard contents into the selected track from row 0 |
| DEL | Clear all rows in that track to empty |
| ✕ | Dismiss the selection |

3. To paste into a different track, long-press the target track cell — the selection moves to the new cell. Tap PASTE.

The clipboard is **shared** with the pattern-view row clipboard, so you can copy in the Song screen and paste in the Pattern screen (or vice versa).

Long-pressing another cell while one is already selected simply **replaces the selection** — there is no forced paste.

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
