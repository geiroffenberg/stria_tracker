# Stria — User Manual: Song Screen

The Song screen is where you build the arrangement of your track.

---

## Layout

- **Left column** — numbered pattern slots. These are **tap-only playhead markers**: tapping a slot jumps playback (or the edit focus) to that pattern. They have no long-press action.
- **Right column** — interactive mini-timeline showing all 16 tracks for every pattern slot. All track-editing gestures (select, move, copy, cut, paste) happen here. A horizontal line marks the current playback position.

## Pattern Slots

Each slot represents one pattern. The song plays slots from top to bottom in sequence. Tap a slot number to focus that pattern for the playhead; no other actions are attached to the row numbers.

## Timeline Track Numbers — Mute & Solo

The numbers (1–16) shown above each lane in the right-hand timeline (as well as the track header button in Pattern and Collapsed views) provide a responsive **live control** for track mute and solo.

### Gesture Controls

- **Single Tap — Toggle Mute:**
  - Tapping a track toggles **Mute** immediately with zero delay (shows `M` in orange, track silenced).
  - Tapping a muted track un-mutes it back to normal (shows `1–16`).
  - Tapping a **soloed track** is ignored (no-op) so a stray single tap during live performance will never accidentally silence the whole mix.
- **Double Tap — Toggle Solo:**
  - Double-tapping a track quickly (within 300 ms) toggles **Solo** (shows `S` in red, isolating the track).
  - To ensure instant responsiveness on single taps, the first tap mutes the track immediately; when the second tap arrives within 300 ms, the mute is reverted and the track switches to solo.
  - Double-tapping a soloed track un-solos it back to normal.
- **Long Press — Performance Reset:**
  - **Long-press any track number** in the Song timeline to reset **all 16 tracks** to the Normal (un-soloed, unmuted) state. This quickly clears complex live mute/solo setups in one action. The reset is immediate and silent.

### Precedence & Global State

- **Audibility Precedence:** Mute takes precedence over solo — a muted track remains silent even if soloed, and the display shows `M` (not `S`).
- **Global Synchronization:** Solo and mute state is **global**: changes propagate instantly across the Song timeline, Pattern screen header (including collapsed views), and Mixer screen.

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
| PST | Paste the clipboard, top-left aligned to the current selection |
| INS | Insert a new empty pattern slot immediately after the selection |
| DUP | Duplicate the selected pattern, inserting the copy immediately after it |
| GLUE | Glue the selected pattern and the one below into one longer pattern |
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
selection. GLUE appends the pattern below the selection onto it — cells and
FX envelopes included — then shifts everything below up one slot so no hole
is left. It only works when both patterns hold data and share the same BPM,
LPB, swing, and track count, with a combined length of at most 99 beats;
otherwise a message explains why nothing happened.

### Multi-cell selection

Once a cell is selected, **long-press another cell** — the selection expands
to cover the full rectangle spanning both cells, in either direction (vertically
across pattern rows, horizontally across tracks, or both). You can keep
long-pressing further cells to move the far corner of the range around.

The action bar operates on the whole selection:

- **CUT / COPY** save the entire rectangular block to a dedicated Song
  clipboard.
- **PST** writes the clipboard so its top-left aligns with the top-left of
  the current selection. The pasted area always uses the clipboard's own
  dimensions (a larger selection at the target just marks the start point).
- **DEL** clears every cell in the selection.

If any of the target cells already contain data, PST opens a dialog with
**Overwrite** or **Swap** — the choice applies to the whole block (Swap
carries the previous target contents into the clipboard so you can move them
elsewhere with another paste).

After CUT, COPY, PST, GLUE, or DEL the selection is cleared automatically, so the
very next tap starts a fresh selection at the paste target.

### Drag and drop (single cell)

You can also **long-press** a single cell and — without lifting your finger —
drag it onto another track cell. Releasing offers Overwrite / Swap when the
target already has data (same as the multi-cell paste dialog). This shortcut
is only available for single-cell drags; extend a range with a second
long-press to work on multiple cells.

Track numbers (1–16) are fixed and cannot be reordered — tapping or double-tapping a track number controls mute and solo for that channel instead.

## Undo / Redo

The Song screen header contains two arrow buttons — **undo** (left) and **redo** (right) — next to the menu icon.

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
| Edit name | Edit the song name in the header; confirm with the check mark or cancel with the cross |
| Song Plan | Edit a saved playback plan and switch planned playback ON/OFF |
| Choose Project Folder | Set the root folder where projects are saved |
| Export WAV | Bounce the full song to a stereo WAV file |
| Export Stems | Export master-routed track buses as separate stereo float WAV files |
| Change Palette | Open the scrollable colour-theme picker |

There are 30 palettes. Multicolour options include **Graphite**, **Cobalt**,
**Terracotta**, **Aubergine**, **Moss**, **Wine**, **Espresso**, and **Glacier**.
For colourful light backgrounds, try **Porcelain** or **Linen**. Your choice is
saved automatically.

## Song Plan

Open **Song Plan** from the Song screen menu to view the default sequential plan.
The table shows 99 plan steps: each references the matching song row, plays
all its lines once (**Repeat 1**), then continues to the next step.
The columns are **Step**, **Pattern**, **Start**, **End**, **Repeat**, and **Count**.

### Live performance or planned playback

The **ON/OFF** button selects the playback mode and is saved with the song.
New songs and older projects default to **OFF**. Editing a plan does not
automatically enable it.

- **OFF** preserves normal Song View playback, including live row jumps and
  looping islands separated by empty pattern rows. An edited plan is ignored.
- **ON** plays the plan's patterns, line ranges, and repeats. Song View follows
  the plan; Song View row taps cannot override it during playback. A route icon
  beside the song name indicates that planned song playback is
  enabled. Tap this icon to open Song Plan directly.
- Pattern View's own Play still plays the current pattern/range. Song Plan's
  Play uses the enabled plan regardless of which tab was previously active.

While stopped, **tap STEP** to select the starting step without opening an
editor. Tapping another value selects the step and opens its editor. Step 01
is selected initially; the selected row stays highlighted when stopped.
While playing, step selection, plan editing/reset, and ON/OFF changes are
disabled. There are no live jumps between plan steps.

The editable fields are:

- **Pattern** selects a Song View pattern slot (1–99), not a copy of its music.
- **Count** defaults to 1 and includes that many consecutive Song View patterns,
  starting at Pattern. The group must fit within slots 1–99. This does not group
  or skip Song Plan steps.
- **Start** defaults to line 1, using the same numbering as Pattern View.
- **End** defaults to the pattern's last line and follows length changes.
  Enter a lower number to keep a fixed end limit. An end at or above the current
  length follows the last line instead. Saved fixed limits are capped to the
  current length for display without losing the limit if the pattern grows.
- **Repeat** accepts 1–999 and repeats the whole counted pattern group.
  For example, Pattern 05, Count 2, Repeat 4 plays 05 → 06 four times,
  then advances to the next Song Plan step.

Start and End apply separately to every included pattern. Automatic End follows
each pattern's own length; the table and editor show the first pattern's end.
A fixed End is capped separately to each pattern's length. Start must be valid
in every populated pattern reached in the group.

**Apply** changes the plan in memory; **Cancel** discards the dialog edits.
Use **Save Song** in the Song screen menu to save the whole song, including its
plan. Autosave also includes the plan; there is no separate Song Plan save button.
The reset icon restores the automatic sequential default after confirmation.
Plan edits and resets participate in Song View's undo/redo.

### Moving, inserting, and deleting steps

The permanent action bar above the mute row uses the same button style as
Song View. It acts on the selected step and is disabled during playback.
Long press has no assigned action.

- **UP / DOWN** swap the selected step with its neighbour. Selection follows
  the moved step. Moving beyond step 01 or 99 is disabled.
- **INS** opens the step editor to insert **after** the selected step. Pattern
  starts at the selected step's pattern; all other fields and mutes use their
  defaults. **Apply** inserts and selects the new step, shifting later steps
  down; **Cancel** changes nothing.
- **DEL** asks for confirmation, then removes the selected step and shifts later
  steps up. Selection stays at the same row. The final row becomes a default
  step referencing an empty pattern (preferably pattern 99). Delete is disabled
  if all 99 patterns contain music.

The plan always retains 99 steps. Insert is disabled at step 99, or if the last
step references music or has custom settings: it never silently discards them.
Disabled Insert/Delete buttons explain the restriction in their tooltips.
Move or delete the protected last step first to make room.
Each action is one Song View undo/redo operation, including restoring selection.
All step fields, including count, repeats, line limits, and mutes, move together.
Pattern references do not change, and no pattern notes or live mixer settings
are modified. Save Song and autosave preserve the resulting plan as usual.

If a pattern becomes shorter than a step's start line, that step is shown in
the palette's stop colour. Edit it to choose a valid range; the start is not
silently changed.

Steps referencing empty patterns are dimmed. Other steps retain their normal
colour even after an empty reference. With the plan ON, the first empty
referenced pattern ends the plan run, even inside a counted group (before any
remaining repeats or later steps); an empty Song View slot that the plan
does not reference does not interrupt planned playback. The run also ends
after step 99. Starting on an empty or invalid step displays an error instead
of starting audio.

With the plan ON and **Loop off**, the run stops at its end and allows audio
tails to ring out. With **Loop on**, playback restarts the whole plan at
**step 01**, even if the first run started on another selected step.
Repeat counts apply to each step independently of Loop. Chance notes receive
a fresh decision for each performed occurrence, rather than replaying a
single pre-generated random pass.

The shared transport controls stay visible at the bottom. During planned
playback, exactly the executing step has the palette's playhead background
and an accent stripe, even when several steps reference the same pattern.
With the plan OFF, the marker follows the live Song View slot. Pattern-only
playback does not mark a playing plan step.

### Per-step track mutes

The fixed row above the transport shows **STEP nn MUTES** and 16 track cells.
Each cell shows its track number when not muted by the step, or **M** when muted.
Tap to toggle while stopped. On narrow screens, swipe the row horizontally to
reach all tracks. The row shows the selected step while stopped and follows the
executing step during planned playback, when it is read-only.

Every step starts with no plan mutes. Its mutes apply throughout its counted
pattern group and all repeats; the next step uses its own settings, without
inheriting the previous step's mutes. They only affect playback with the plan
**ON**, and do not alter patterns or the existing live mute/solo settings.
A track is silent if the step mutes it or the live mixer controls silence it;
a track number does not override live mute/solo. Plan mutes are removed when
plan playback stops. They are saved with the song, support undo/redo, and are
cleared by resetting the plan. Older songs load with no plan mutes.

During planned playback, Song View and Pattern View track indicators show **M**
for either an active plan mute or a live mute. Mixer mute buttons also light up
for either source. Plan mute takes display precedence over solo. These indicators
follow the executing step, not the selected step or pattern number, and return
to the live mixer state when playback stops. Taps and reset gestures still
control only live mute/solo; clearing a live mute cannot override a plan mute.

Playback is prepared in bounded batches ahead of the audio engine. If the
next batch cannot be delivered in time, playback stops with a visible error
instead of silently replaying old music.

**Audio export of enabled plans is not available yet.** Turn Song Plan OFF
before exporting WAV or stems; exports then use the normal Song View arrangement.
Pattern-to-sampler rendering remains independent of the song plan.

Songs without a saved plan use the automatic sequential default. The first
edit creates a custom plan stored inside the existing project JSON; no separate
plan file is needed. Older saved steps without Count use Count 1.
Pattern references identify numbered slots, so moving
music between Song View slots changes what those references point to.
