# Stria — User Manual

> Work in progress. Sections marked *TBD* need content added as the app evolves.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Core Concepts](#2-core-concepts)
3. [Song Screen](#3-song-screen)
4. [Pattern Screen](#4-pattern-screen)
5. [Instrument Screen](#5-instrument-screen)
6. [Mixer Screen](#6-mixer-screen)
7. [Instruments](#7-instruments)
   - 7.1 [Sampler](#71-sampler)
   - 7.2 [Simple Synth](#72-simple-synth)
   - 7.3 [Karplus-Strong](#73-karplus-strong)
8. [FX Commands](#8-fx-commands)
   - 8.1 [General FX](#81-general-fx)
   - 8.2 [Slice Shorthand Notes (Sampler)](#82-slice-shorthand-notes-sampler)
   - 8.3 [Legacy Slice Select (SLx)](#83-legacy-slice-select-slx)
   - 8.4 [Mixer FX](#84-mixer-fx)
   - 8.5 [Insert FX Commands](#85-insert-fx-commands)
9. [Insert Effects](#9-insert-effects)
   - 9.1 [Reverb](#91-reverb)
   - 9.2 [Delay](#92-delay)
   - 9.3 [Filter](#93-filter)
   - 9.4 [Distortion](#94-distortion)
10. [Transport Bar](#10-transport-bar)
11. [Project Management](#11-project-management)

---

## 1. Overview

Stria is a mobile pattern-based tracker. Music is built from **patterns** — grids of notes and FX commands across up to 16 tracks. Patterns are arranged into a **song**. Each track is driven by an **instrument** (sampler, synth, or Karplus-Strong). A **mixer** provides per-channel volume, pan, mute, solo, and per-slot insert effects.

The app has four main screens accessible via the top navigation bar:

| Tab | Screen |
|---|---|
| SONG | Arrange patterns into a song |
| PATTERN | Edit notes and FX in a pattern |
| INST | Edit the current instrument |
| MIXER | Control levels, routing, and insert effects |

---

## 2. Core Concepts

This section covers the behaviours in Stria that differ from most other trackers. If you are coming from Renoise, FamiTracker, or similar tools, read this first.

---

### 2.1 BPM Is Per-Pattern, Not Global

In most trackers, BPM is a single global value for the whole song. In Stria, **each pattern carries its own BPM**. When the song moves from one pattern to the next, the engine immediately switches to that pattern's tempo.

This means:
- A breakdown section can run at 70 BPM while the main loop runs at 140 BPM — no automation required.
- Tempo changes are structural (arranged in the Song screen) rather than encoded as FX commands.

---

### 2.2 LPB Controls Row Duration, Not Just Visual Resolution

**LPB (Lines Per Beat)** determines how long each row lasts in real time:

$$\text{Row duration} = \frac{60}{\text{BPM} \times \text{LPB}} \text{ seconds}$$

| BPM | LPB | Row duration |
|---|---|---|
| 120 | 4 | 125 ms (16th note at 120 BPM) |
| 120 | 8 | 62.5 ms (32nd note) |
| 120 | 2 | 250 ms (8th note) |
| 120 | 1 | 500 ms (quarter note) |

LPB is **not** just a display setting — changing it literally changes the time each row takes to play. A pattern with 32 rows at LPB=4 lasts the same real-world time as one with 16 rows at LPB=2.

---

### 2.3 LPB Is Also Per-Pattern

Like BPM, **LPB is stored per pattern**. Every pattern can have a different rhythmic subdivision. Common uses:

- A swing/groove pattern at LPB=6 alongside a straight pattern at LPB=4.
- A dense fill pattern at LPB=8 followed by a sparse passage at LPB=2.
- Polyrhythmic structures where each pattern represents a different time feel.

> **Tip:** Because both BPM and LPB are per-pattern, Stria can produce complex metric modulations simply by switching patterns — no tempo automation tracks needed.

---

### 2.4 Instrument Carry

The INST column in the pattern grid does not need to be filled on every row. Once an instrument number is written, it **carries forward** on that track until a new number is explicitly written. This keeps patterns clean.

---

### 2.5 Note Hold vs. Note Off

| Cell content | Meaning |
|---|---|
| `---` | Empty — the current note keeps playing (hold) |
| `OFF` | Send a note-off to the instrument on this track |
| Any note | Trigger a new note (re-triggers the instrument) |

---

### 2.6 FX Carry Behaviour

Some FX commands persist across rows; others fire once and are done:

| Command | Carries? | Notes |
|---|---|---|
| `VIB` | Yes | Vibrato continues until note-off or a new VIB with depth 0 |
| `PAN` | No | Sets pan for that row only (mixer channel retains its own state) |
| `SLC` | No | Fires once at row start |
| `INST` | Yes | Carries to subsequent rows until changed |

> More carry rules will be documented here as the app evolves.

---

### 2.7 Sampler Slice Proxy Notes

On **sampler** tracks, the first 9 chromatic notes of octave 0 (C-0 through G#0) are reserved as single-keystroke slice triggers. They are not available as pitched notes on sampler instruments. Any note from A#0 (MIDI 21) upward plays the full sample at normal pitch.

See [Section 7 — FX Commands / Slice Shorthand](#82-slice-shorthand-notes-sampler) for the full table.

---

## 3. Song Screen

The Song screen is where you build the arrangement of your track.

### Layout

- **Left column** — numbered pattern slots. Tap a slot to select it as the active pattern for editing. Long-press to open the action bar (move up/down, duplicate, delete).
- **Right column** — read-only mini-timeline showing all 16 tracks for every pattern slot. A horizontal line marks the current playback position.

### Pattern Slots

Each slot represents one pattern. The song plays slots from top to bottom in sequence.

### Actions (long-press on a slot)

| Action | Description |
|---|---|
| Move Up / Down | Reorder the slot in the arrangement |
| Duplicate | Insert a copy of the pattern directly below |
| Delete | Remove the slot from the arrangement |

### Menu

The top-right menu provides:

| Item | Description |
|---|---|
| New Song | Clear everything and start fresh |
| Save Song | Write the project to the project folder |
| Load Song | Browse and open a saved project |
| Choose Project Folder | Set the root folder where projects are saved |
| Export WAV | Bounce the full song to a stereo WAV file |
| Change Palette | Cycle the colour theme |

---

## 4. Pattern Screen

The Pattern screen is the main composition view. It shows all tracks for the currently selected pattern as a scrolling grid.

### The Grid

Each **row** is one line of music. Each **column** is one track. The playhead (highlighted row) steps through rows at the speed defined by BPM and LPB.

### Cell Columns

Each track cell contains up to four fields:

```
NOTE   INST   VOL   FX   VAL
C-4    01     75    PAN  50
```

| Field | Description |
|---|---|
| NOTE | The note to play (`C-4`, `D#3`, `OFF`, `---`) |
| INST | Instrument number (01–16). Carries forward if empty |
| VOL | Per-cell volume override (00–99) |
| FX | Effect command (3-letter code) |
| VAL | Effect value (00–99) |

Multiple FX slots per cell are supported.

### Note Entry

- Notes are entered in chromatic order. The note picker scrolls through the 10 available octaves (0–9).
- `OFF` sends a note-off (stops the current note on that track).
- `---` leaves the field empty (the previous note continues to hold).

### Pattern Settings

BPM (tempo) and LPB (Lines Per Beat) are set per pattern. Changing them mid-song is supported — each pattern can have its own tempo.

| Setting | Range | Description |
|---|---|---|
| BPM | 20–300 | Beats per minute |
| LPB | 1–16 | Lines (rows) per beat — controls rhythmic resolution |

### Views

- **Normal view** — all tracks visible, horizontal scroll.
- **Collapsed view** — tracks compressed into a compact overview. *TBD*

---

## 5. Instrument Screen

The Instrument screen lets you edit the instrument assigned to the currently focused track.

### Header

- Shows the current instrument slot number (01–16).
- A type selector lets you switch between **SAMPLER**, **SIMPLE SYNTH**, **KARPLUS**, or **EMPTY**.

Switching type preserves the slot number but resets the instrument parameters.

### Navigation

Tap the instrument number to move between slots. Each pattern track remembers its last-used instrument number.

> Detailed parameters for each instrument type are in **Section 6**.

---

## 6. Mixer Screen

The Mixer screen provides a channel strip for each of the 16 tracks plus a master bus.

### Channel Strip

Each channel strip contains:

| Control | Range | Description |
|---|---|---|
| Volume fader | 0–99 | Channel output level |
| Pan knob | 0–99 (50 = centre) | Stereo position |
| Mute button | on/off | Silence the channel |
| Solo button | on/off | Isolate the channel |

### Insert Effect Slots

Each channel strip has up to **6 insert effect slots** in series. Each slot can hold one of the available effect types (see Section 8).

- Slots process in order: slot 1 → slot 2 → … → slot 6 → master bus.
- An empty slot passes audio through unchanged.
- Slots can be bypassed individually.

### Master Bus

The master strip sits at the far right. It has volume and mute controls and shares the same insert slot system.

---

## 7. Instruments

### 7.1 Sampler

The Sampler plays an audio file loaded from storage.

#### Parameters

| Parameter | Range | Description |
|---|---|---|
| Sample | — | File loaded into this slot |
| Pitch | ±12 st | Global pitch offset for all playback |
| Volume | 0–1 | Base playback level |
| Start | 0–99% | Playback start point |
| End | 0–99% | Playback end point |
| Attack | 0–1 | Fade-in length |
| Release | 0–1 | Fade-out length |
| Loop Mode | Off / Forward / Ping-pong | Looping behaviour |

#### Slices

Up to **9 slice markers** can be placed within the sample. Each marker is a position (0–99%) that divides the sample into regions.

- Slice 1 begins at its marker and ends at slice 2's marker (or the end if slice 2 is unset).
- Slices are addressed in the pattern using slice shorthand notes or the `SLC` FX command (see Section 7).

#### Slice Shorthand Notes (C-0 to G#0)

The first 9 chromatic notes of octave 0 are reserved as slice triggers on sampler tracks:

| Note | Slice |
|---|---|
| C-0 | Slice 1 |
| C#0 | Slice 2 |
| D-0 | Slice 3 |
| D#0 | Slice 4 |
| E-0 | Slice 5 |
| F-0 | Slice 6 |
| F#0 | Slice 7 |
| G-0 | Slice 8 |
| G#0 | Slice 9 |

Writing one of these notes on a sampler track is exactly equivalent to writing `C-4` with `FX: SLC VAL: 0N`. The sample always plays at normal (C4) pitch. To play the whole sample from start to end, use `C-4` or any note above `A#0`.

---

### 7.2 Simple Synth

A subtractive synthesiser with six waveforms, a multi-mode filter, ADSR envelope, LFO, and drive.

#### Waveforms

| Code | Shape |
|---|---|
| SIN | Sine |
| TRI | Triangle |
| SAW | Sawtooth |
| SQR | Square |
| PUL | Pulse |
| NSE | Noise |

#### Amplitude Envelope (ADSR)

| Parameter | Description |
|---|---|
| Attack | Time to reach full level |
| Decay | Time to fall to sustain level |
| Sustain | Level held while note is on |
| Release | Time to fade out after note-off |

#### Filter

| Parameter | Description |
|---|---|
| Mode | LP (low-pass), HP (high-pass), BP (band-pass) |
| Cutoff | Filter frequency (0–1) |
| Resonance | Resonant peak at cutoff (0–1) |
| Env Amount | How much the filter ADSR modulates cutoff |
| Filter ADSR | Separate A/D/S/R controls for filter cutoff movement |

#### LFO

| Parameter | Description |
|---|---|
| Rate | 0.1–20 Hz |
| Depth | Modulation amount (0–1) |
| Target | Pitch, Filter cutoff, or Amplitude |

#### Other

| Parameter | Description |
|---|---|
| Detune | ±12 semitones from root note |
| Drive | Soft saturation/distortion (0–1) |
| Glide | Portamento time between notes |

---

### 7.3 Karplus-Strong

A physical modelling synthesiser that emulates a plucked string by exciting a delay loop with filtered noise.

#### Parameters

| Parameter | Description |
|---|---|
| Decay | How quickly the string loses energy |
| Damping | High-frequency damping (brighter ↔ darker string) |
| Tone | Initial spectral content of the pluck excitation |
| Stretch | Inharmonicity — slight detuning of partials |
| Pick Position | Where along the string the excitation is applied |
| Attack Colour | Character of the initial transient |
| Body | Resonance of a virtual body cavity |
| Drive | Input gain / saturation before the delay loop |

---

## 8. FX Commands

FX commands are entered in the FX column of a pattern cell. Each command takes a two-digit value (00–99). Multiple FX slots per cell allow stacking commands on the same row.

### 8.1 General FX

| Command | Value (XY) | Description |
|---|---|---|
| `ARP` | XY | Arpeggio. X = first interval (semitones), Y = second interval |
| `CHA` | 00–99 | Chance. 00 = never play, 99 = always play, 50 = 50% |
| `DEL` | 00–99 | Delay note-on by % of the row duration (00 = start, 99 = end) |
| `KIL` | 00–99 | Kill note at % through row (00 = immediately, 99 = end of row) |
| `PAN` | 00–99 | Set stereo pan (00 = full left, 50 = centre, 99 = full right) |
| `RAN` | 01–99 | Random active slice — chance % to override the slice with a random one |
| `RET` | XY | Retrigger. X = volume curve mode, Y = number of retrigs per line |
| `REV` | — | Reverse — play sample/slice backwards |
| `VIB` | XY | Vibrato. X = speed (0–9), Y = depth (0–9) |
| `VOL` | 00–99 | Override volume for this row only (does not carry to next row) |
| `SLC` | XY | Slice player. X = play mode (0 = slice only, 1 = play through), Y = slice number (1–9) |
| `ARC` | XY | Octave arp config. X = octave layers, Y = notes per line |

#### ARP — Arpeggio Detail

The arp cycles through root → root+X → root+Y semitones. Values 0–9 are chromatic semitones:

`0`=unison, `1`=m2, `2`=M2, `3`=m3, `4`=M3, `5`=P4, `6`=tritone, `7`=P5, `8`=m6, `9`=M6

#### RET — Retrigger Volume Curves

| X digit | Curve |
|---|---|
| 0 | Flat (same volume each retrig) |
| 1–9 | *TBD — document curve shapes* |

---

### 8.2 Slice Shorthand Notes (Sampler)

On sampler tracks, notes C-0 through G#0 are proxy slice triggers and do not need an FX command. See [Section 6.1](#61-sampler) for the full table.

---

### 8.3 Legacy Slice Select (SLx)

The older `SL0`–`SL9` commands select a slice region by command code rather than value:

| Command | Value | Description |
|---|---|---|
| `SL0` | 00 = play through / 01 = stop at next slice | Select slice 0 (sample start) |
| `SL1`–`SL9` | 00 = play through / 01 = stop | Select slice 1–9 |

> These commands remain supported for compatibility. For new patterns, prefer the `SLC` command or the shorthand notes.

---

### 8.4 Mixer FX

Mixer FX commands automate the mixer from the pattern grid without touching the mixer screen.

| Command | Value | Description |
|---|---|---|
| `M01` | 00=unmute, >00=mute | Master mute |
| `M02` | 00–99 | Master volume |
| `Mx0` | — | Reset channel x to current mixer snapshot |
| `Mx1` | 00–99 | Channel x pan |
| `Mx2` | 00=off, >00=on | Channel x mute |
| `Mx3` | 00=off, >00=on | Channel x solo |
| `Mx4` | 00–99 | Channel x volume |

Where `x` is the channel number: `1`–`9` for tracks 1–9, `A`–`G` for tracks 10–16.

`M00` resets the entire mixer to the current UI snapshot.

---

### 8.5 Insert FX Commands

Insert FX commands automate parameters of an insert effect slot from the pattern.

Format: slot number + function number encoded as a command code.

*TBD — document specific function numbers per effect type.*

---

## 9. Insert Effects

Insert effects process the audio of a single channel in real time. Each slot has input gain, output gain, dry/wet, and bypass controls in addition to its own parameters.

### 9.1 Reverb

A Freeverb-based stereo reverb.

| Parameter | Range | Description |
|---|---|---|
| Room Size | 0–1 | Simulated room size / reverb length |
| Damp | 0–1 | High-frequency absorption (0 = bright, 1 = dark) |
| Width | 0–1 | Stereo width of the reverb tail |
| Dry | 0–1 | Level of the unprocessed signal |
| Wet | 0–1 | Level of the reverb return |
| Freeze | on/off | Hold the reverb tail indefinitely |

---

### 9.2 Delay

A stereo feedback delay with tempo-sync capability and a hi-pass filter on the feedback path.

| Parameter | Range | Description |
|---|---|---|
| Time | 1–2000 ms | Delay time (free mode) |
| Feedback | 0–0.95 | Feedback amount (higher = longer repeats) |
| HP Cutoff | 0–1 | Hi-pass filter on feedback (0 = off) |
| Dry | 0–1 | Dry signal level |
| Wet | 0–1 | Delayed signal level |
| Sync | on/off | Tempo-sync mode *(TBD)* |

---

### 9.3 Filter

A state-variable filter (SVF) with three modes.

| Parameter | Range | Description |
|---|---|---|
| Mode | LP / HP / BP | Filter type |
| Cutoff | 0–1 | Filter frequency (~20 Hz – 20 kHz) |
| Resonance | 0–1 | Resonant peak at cutoff |

---

### 9.4 Distortion

A waveshaping distortion with a post-tone filter.

| Parameter | Range | Description |
|---|---|---|
| Drive | 0–1 | Input gain (higher = more clipping) |
| Tone | 0–1 | One-pole low-pass on the output (0 = dark, 1 = bright) |
| Type | Soft-clip / Fold | Waveshaper character |

---

## 10. Transport Bar

The transport bar sits at the bottom of every screen.

| Control | Description |
|---|---|
| Play / Stop | Start or stop playback |
| Record | *TBD* |
| BPM display | Shows current pattern tempo; tap to edit |
| LPB display | Shows lines per beat; tap to edit |
| Pattern follow | Toggle whether playback follows the song arrangement or loops the current pattern |

---

## 11. Project Management

Projects are stored as folders on device storage.

### Structure

```
<project-folder>/
  <project-name>/
    project.json      — song, patterns, instruments
    *.wav             — any exported or recorded audio files
```

### Saving

Use **Song → Save Song** (or the menu icon). The project is written to `project.json` in the chosen project folder.

### Loading

Use **Song → Load Song** to browse saved projects. The app lists all subfolders that contain a `project.json` (or legacy `song.json`) file.

### Project Folder

Use **Choose Project Folder** to grant the app access to a folder via the Android Storage Access Framework. This permission persists across sessions.

### Export WAV

**Export WAV** bounces the full song in real time to a stereo WAV file saved inside the project folder.

---

*End of manual — version 0.1 draft*
