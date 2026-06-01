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

### 2.4 Instrument Column (IN)

The IN column controls both *which instrument slot* is active and *whether a note triggers at all*.

| IN value | Effect |
|---|---|
| `--` (empty) | No trigger. The last-used instrument slot is silently carried. Any note in the NOTE column is ignored — the row acts as a hold. |
| `00` | No trigger. If a note is written on this row, the pitch of the currently playing voice is updated immediately — the amplitude envelope is **not** retriggered. If the instrument has **Glide** set, the pitch transition is smoothed. |
| `01`–`99` | Switch to that instrument slot and trigger the note (if one is present in NOTE). |

**Key rule:** a note only fires when IN is `01`–`99`. Every new note-on must carry an explicit instrument number. This makes every trigger unambiguous.

`00` is a compact portamento shorthand: write a destination note with IN = `00` to glide to a new pitch without restarting the envelope.

---

### 2.5 Note Hold vs. Note Off

| NOTE column | IN column | Meaning |
|---|---|---|
| `---` | any | Empty note — the current note keeps playing (hold) |
| `OFF` | any | Send a note-off, silence the track |
| Note (e.g. `C-4`) | `--` (empty) | No trigger — acts as a hold. The note value is ignored. |
| Note | `00` | Pitch-change only — no retrigger; glide applies if set on the instrument |
| Note | `01`–`99` | Full note-on — triggers with the specified instrument slot |

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

### Undo / Redo

The Song screen header contains two arrow buttons — **undo** (left) and **redo** (right) — next to the edit and menu icons.

- Up to **50 undo steps** are stored per session.
- Every song-level mutation is tracked: append pattern, insert pattern, move up/down, duplicate, merge, double, and delete.
- The tooltip on each button shows what action would be undone or redone (e.g. "Undo: delete pattern").
- Undo and redo apply only to the **arrangement** (pattern order, count, structure). Per-pattern note edits have their own separate undo stack accessible from the Pattern screen.

> **Note:** The undo history is session-only — it is cleared when the project is reloaded.

### Menu

The top-right menu provides:

| Item | Description |
|---|---|
| New Song | Clear everything and start fresh |
| Save Song | Write the project to the project folder |
| Load Song | Open a scrollable list of saved projects in a bottom sheet; tap a name to load |
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
| INST | `--` = hold/carry (no trigger); `00` = pitch-change only (no retrigger, glide applies); `01`–`16` = trigger with that instrument slot |
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

#### Filter (HP → LP)

The FILTER section sits below PARAMS in the instrument editor. It inserts a **high-pass filter followed by a low-pass filter in series** on the sampler audio path.

| Control | Description |
|---|---|
| ON / OFF toggle | Master bypass for the filter. When **OFF**, the filter uses zero CPU and the signal passes through unchanged. |
| HP CUT | High-pass cutoff (0 = fully open / no filtering, 100 = fully closed). |
| HP RES | High-pass resonance — adds a peak at the HP cutoff frequency (0 = flat, 100 = maximum). |
| LP CUT | Low-pass cutoff (0 = fully closed, 100 = fully open / no filtering). |
| LP RES | Low-pass resonance — adds a peak at the LP cutoff frequency (0 = flat, 100 = maximum). |

Both stages use a Chamberlin state-variable filter (SVF). The SVF state is reset on each note-on to prevent audible thumps between notes.

Each stage is also individually bypassed at the DSP level when its cutoff is at the fully-open extreme, so leaving HP CUT at 0 or LP CUT at 100 has no CPU cost even when the master toggle is ON.

The filter parameters can be automated per-row using `Pxx` commands — see **Sampler Pxx — Parameter Automation** below.

---

#### Chop Operations

Two buttons are available to extract audio regions into new instrument slots:

| Button | Description |
|---|---|
| CHOP TO NEW SLOT | Extracts the region between **Start** and **End** as a new mono 16-bit WAV file and places it in the next empty instrument slot as a sampler. The new slot is selected automatically. |
| CHOP ALL SLICES TO NEW INSTRUMENTS | Extracts each active slice (SL1–SL9, i.e. any slice with a non-zero marker) into its own WAV file, filling consecutive empty slots in order. The output files are named `<source>_sl1.wav`, `_sl2.wav`, etc. The last created slot is selected when done. |

Both operations convert to mono 16-bit PCM and preserve the source instrument's pitch, volume, attack, and release settings.

#### Slices

Up to **9 slice markers** can be placed within the sample (opened via the SLICES section in the instrument editor). Each marker is a position (0–99) that divides the sample into regions. Markers are set with the **RESET ALL** button to clear, or adjusted individually per-slice.

- Slice 1 begins at its marker and ends at slice 2's marker (or the end if slice 2 is unset).
- Inactive slices (value 0) are skipped; adjacent active slices form contiguous regions.
- Slices are addressed in the pattern using slice shorthand notes or the `SLC` FX command (see Section 8).

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

#### Sampler Pxx — Parameter Automation

The `Pxx` command (where `P` stands for *param* and `xx` is a two-digit value 00–99) carries a parameter override into the sampler voice for that row. This works on both note rows and hold rows, letting you sweep sampler parameters over time without retriggering.

| Index | FX command | Parameter | Notes |
|---|---|---|---|
| 00 | `P00` | Reset | Restore all params to the instrument's current slider values |
| 01 | `P01` | Start | Sample playback start position |
| 02 | `P02` | End | Sample playback end position |
| 03 | `P03` | Pitch | Detune — 00 = −12 st, 50 = centre, 99 = +12 st |
| 04 | `P04` | Volume | Instrument level (00 = silent, 99 = full) |
| 05 | `P05` | Attack | Fade-in length (00 = instant, 99 = slowest) |
| 06 | `P06` | Release | Fade-out length (00 = instant, 99 = slowest) |
| 07 | `P07` | Loop | 00 = off, 01 = forward loop, 02 = ping-pong |
| 08 | `P08` | HP Cut | High-pass cutoff (00 = open, 99 = closed). Filter must be ON. |
| 09 | `P09` | HP Res | High-pass resonance (00–99). Filter must be ON. |
| 10 | `P10` | LP Cut | Low-pass cutoff (00 = closed, 99 = open). Filter must be ON. |
| 11 | `P11` | LP Res | Low-pass resonance (00–99). Filter must be ON. |

Carried values persist until the next `Pxx` command for the same parameter, or until `P00` resets them all. Values are updated even when the filter toggle is OFF — flipping it on mid-song immediately picks up the last automated values.

---

### 7.2 Simple Synth

A three-oscillator synthesiser with FM modulation, a multi-mode filter, ADSR envelope, LFO, and drive.

#### Oscillators

The synth has three oscillators. **OSC 1** is always active. **OSC 2** and **OSC 3** each have an on/off toggle in their section header; when off, their controls are dimmed and they produce no sound.

Each oscillator has a selectable waveform:

| Code | Shape |
|---|---|
| SIN | Sine |
| TRI | Triangle |
| SAW | Sawtooth |
| SQR | Square |
| PUL | Pulse (25% duty) |
| NSE | Noise |

| Knob / Button | Description |
|---|---|
| OCT | Octave shift for this oscillator: –2, –1, 0, +1, or +2 octaves relative to the played note. Displayed as a row of five chip buttons. OSC 1 defaults to 0; OSC 2 and OSC 3 also default to 0. Shifting OSC 2 up one octave (+1) gives an exact 2:1 FM ratio with OSC 1, which is useful for classic FM bass and bell timbres. |
| DETUNE | Fine pitch offset from the root note, ±12 semitones |
| GAIN | Output level of this oscillator (0–100%) |
| FM→1 / FM→2 | FM depth — how strongly this oscillator frequency-modulates the previous one (see below) |

#### FM Modulation

FM routing is chained: **OSC 3 → modulates OSC 2 → modulates OSC 1**.

- The **FM knob on OSC 2** controls how much OSC 2 bends OSC 1's frequency each sample.
- The **FM knob on OSC 3** controls how much OSC 3 bends OSC 2's frequency.
- At **FM = 0** the oscillator acts as a plain additive voice (no modulation). This is the default.
- At **FM = 100%** the carrier frequency can swing up to ±3× its base value, producing rich inharmonic sidebands.
- **GAIN and FM are independent:** set GAIN = 0 to use an oscillator as a pure (inaudible) modulator, or combine both for additive-plus-FM timbres.

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
| `ARP` | XY | Arpeggio. X = first interval (semitones), Y = second interval. Carries through hold rows. |
| `CHA` | 00–99 | Chance. 00 = never play, 99 = always play, 50 = 50% |
| `DEL` | 00–99 | Delay note-on by % of the row duration (00 = start, 99 = end) |
| `GAT` | XY | Gate. X = speed (0–9), Y = depth (0–9). Square-wave volume LFO. Carries through hold rows. |
| `KIL` | 00–99 | Kill note at % through row (00 = immediately, 99 = end of row) |
| `PAN` | 00–99 | Set stereo pan (00 = full left, 50 = centre, 99 = full right). Carries through hold rows. |
| `RAN` | 01–99 | Random active slice — chance % to override the slice with a random one |
| `RET` | XY | Retrigger. X = volume curve mode, Y = number of retrigs per line |
| `REV` | — | Reverse — play sample/slice backwards |
| `SLC` | XY | Slice player. X = play mode (0 = slice only, 1 = play through), Y = slice number (1–9) |
| `SLD` | XY | Slide Down. X = lines to slide over (1–9), Y = semitones down (1–9). Works on hold rows. |
| `SLU` | XY | Slide Up. X = lines to slide over (1–9), Y = semitones up (1–9). Works on hold rows. |
| `TRE` | XY | Tremolo. X = speed (0–9), Y = depth (0–9). Sine-wave volume LFO. Carries through hold rows. |
| `VIB` | XY | Vibrato. X = speed (0–9), Y = depth (0–9). Pitch LFO. Carries through hold rows. |
| `VOL` | 00–99 | Override volume. Carries through hold rows until note-off. |
| `ARC` | XY | Octave arp config. X = octave layers, Y = notes per line |

#### ARP — Arpeggio Detail

The arp cycles through root → root+X → root+Y semitones. Values 0–9 are chromatic semitones:

`0`=unison, `1`=m2, `2`=M2, `3`=m3, `4`=M3, `5`=P4, `6`=tritone, `7`=P5, `8`=m6, `9`=M6

ARP can be placed on a hold row to start arpeggiation mid-note.

#### RET — Retrigger Volume Curves

| X digit | Curve |
|---|---|
| 0 | Flat (same volume each retrig) |
| 1–9 | *TBD — document curve shapes* |

#### SLU / SLD — Pitch Slide Detail

Slide Up and Slide Down linearly move the pitch over X rows by Y semitones. The slide is sample-accurate within each row.

- `SLU 23` — slide up 3 semitones over 2 rows
- `SLD 14` — slide down 4 semitones over 1 row

Placing SLU/SLD on a **hold row** slides from the currently held pitch, allowing pitch changes without retriggering the note.

#### VIB / TRE / GAT — LFO Carry Behaviour

All three LFO commands carry their speed and depth values forward through subsequent hold rows and stop when a note-off is reached. This means:

- Place the command on a **note row** to start the effect from the very beginning of the note.
- Place it on a **hold row** to add it mid-note without retriggering.
- Leave the hold rows bare — the last-set speed and depth stay active automatically.
- A `===` (note-off) resets the carry.

`VIB` and `TRE`/`GAT` are independent and can be combined on the same note: VIB modulates pitch while TRE/GAT modulates amplitude.

#### TRE — Tremolo Detail

Tremolo applies a **sine-wave** volume LFO. The volume oscillates smoothly between full and attenuated based on the depth setting.

- X = 0 → very slow (0.1 Hz); X = 9 → fast (≈20 Hz)
- Y = 0 → no effect; Y = 9 → maximum depth (volume dips to silence at the trough)

#### GAT — Gate Detail

Gate applies a **square-wave** volume LFO, creating a rhythmic stutter or gating effect. The volume switches abruptly between full and attenuated.

- Same speed (X) and depth (Y) encoding as TRE.
- At high depths, the signal cuts fully in and out — classic trance-gate / sidechain-compression imitation.
- At lower depths, the cuts are partial, producing a pumping texture.

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
| Loop | When active in pattern mode, the pattern loops continuously. Any changes made to notes, instruments, or settings during playback are picked up automatically at the start of the next loop iteration — no stop/restart required. |}

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

Use **Song → Load Song** (menu or save/load panel) to open a scrollable bottom sheet listing all saved projects. Tap a project name to load it. The list shows every subfolder that contains a `project.json` (or legacy `song.json`) file.

### Project Folder

Use **Choose Project Folder** to grant the app access to a folder via the Android Storage Access Framework. This permission persists across sessions.

### Export WAV

**Export WAV** bounces the full song in real time to a stereo WAV file saved inside the project folder.

---

*End of manual — version 0.1 draft*
