# Stria — User Manual: FX Commands

FX commands are entered in the FX column of a pattern cell. Each command takes a two-digit value (00–99). Multiple FX slots per cell allow stacking commands on the same row.

---

## General FX

| Command | Value (XY) | Description |
|---|---|---|
| `ARP` | XY | Arpeggio. X = first interval (semitones), Y = second interval. Carries through hold rows. |
| `BPM` | 00–99 | Tempo nudge (pattern-global). 00 = reset to pattern's BPM, 01–50 = +1..+50, 51–99 = -49..-1. Stacks onto the current tempo; resets to the pattern's snapshot BPM at pattern start / loop start. |
| `CHA` | 00–99 | Chance. 00 = never play, 99 = always play, 50 = 50% |
| `DEL` | 00–99 | Delay note-on by % of the row duration (00 = start, 99 = end) |
| `GAT` | XY | Gate. X = speed (0–9), Y = depth (0–9). Square-wave volume LFO. Carries through hold rows. |
| `KIL` | 00–99 | Kill note at % through row (00 = immediately, 99 = end of row) |
| `PAN` | 00–99 | Set stereo pan (00 = full left, 50 = centre, 99 = full right). Carries through hold rows. |
| `RAN` | 01–99 | Random active slice — chance % to override the slice with a random one |
| `RET` | XY | Retrigger. X = volume curve mode, Y = number of retrigs per line |
| `RNI` | 01–99 | Random instrument. Randomizes the active instrument slot between current and the specified upper limit. Rerolls on note-on only; carries through hold rows. |
| `REV` | — | Reverse — play sample/slice backwards |
| `SLC` | XY | Slice player. X = play mode (0 = slice only, 1 = play through), Y = slice number (1–9) |
| `SLD` | XY | Slide Down. X = lines to slide over (1–9), Y = semitones down (1–9). Works on hold rows. |
| `SLU` | XY | Slide Up. X = lines to slide over (1–9), Y = semitones up (1–9). Works on hold rows. |
| `SWN` | 00–99 | Swing override (pattern-global). Directly sets the pattern's swing amount for the rest of this playthrough; resets to the pattern's snapshot swing at pattern start / loop start. |
| `SN1` | 00–99 | Send to channel 14. 00 = reset send, 01–99 = send percentage. Carries through hold rows until note-off. |
| `SN2` | 00–99 | Send to channel 15. 00 = reset send, 01–99 = send percentage. Carries through hold rows until note-off. |
| `SN3` | 00–99 | Send to channel 16. 00 = reset send, 01–99 = send percentage. Carries through hold rows until note-off. |
| `TRE` | XY | Tremolo. X = speed (0–9), Y = depth (0–9). Sine-wave volume LFO. Carries through hold rows. |
| `VIB` | XY | Vibrato. X = speed (0–9), Y = depth (0–9). Pitch LFO. Carries through hold rows. |
| `VOL` | 00–99 | Override volume. Carries through hold rows until note-off. |
| `ARC` | XY | Arp mode config. X = mode (1–9), Y = notes per line. 1–3 = linear, 4–6 = bidirectional, 7–9 = random |

### ARP — Arpeggio Detail

The arp cycles through root → root+X → root+Y semitones. Values 0–9 are chromatic semitones:

`0`=unison, `1`=m2, `2`=M2, `3`=m3, `4`=M3, `5`=P4, `6`=tritone, `7`=P5, `8`=m6, `9`=M6

ARP can be placed on a hold row to start arpeggiation mid-note.

### BPM / SWN — Pattern-Global Tempo & Swing Overrides

Unlike most FX commands (which affect only the track/note they're placed on), `BPM` and `SWN` are **pattern-global**: they affect the whole pattern's timing, no matter which track carries the command. If more than one track has the command on the same row, only the lowest-numbered track's value is used.

Both commands automatically reset to the pattern's own saved value (the value shown on the transport bar / pattern settings) at the **start of playback** and every time the pattern **loops back to its start** — so a BPM/SWN ramp you build up during one pass never bleeds into the next.

**BPM** (`00`–`99`) is a signed nudge relative to whatever tempo is currently in effect, not the pattern's base tempo:

| Value | Meaning |
|---|---|
| `00` | Reset tempo to the pattern's own BPM right now |
| `01`–`50` | Add `+1` to `+50` BPM |
| `51`–`99` | Subtract `1` to `49` BPM (`99`=-1, `98`=-2, `97`=-3 … `51`=-49) |

Because it stacks, several `BPM` commands across a pattern can build a gradual tempo ramp (e.g. speeding up into a drop), and `BPM 00` is a quick way to snap back to the base tempo mid-pattern without waiting for a loop.

**SWN** (`00`–`99`) simply overrides the pattern's swing percentage directly — no +/- encoding, the value you enter *is* the new swing amount until the next `SWN` command, pattern restart, or loop.

### SN1 / SN2 / SN3 — Send Channels

**SN1**, **SN2**, and **SN3** route a track's signal to auxiliary send channels (14, 15, and 16 respectively) for creating send-based effects chains like reverb or delay:

- `SN1` sends to **channel 14**
- `SN2` sends to **channel 15**
- `SN3` sends to **channel 16**

**Value encoding:**

| Value | Meaning |
|---|---|
| `00` | Reset send (stop sending to the auxiliary channel) |
| `01`–`99` | Send percentage (1–99%) of the signal to the auxiliary channel while maintaining the track's normal routing |

**Carry behaviour:**

Unlike most FX commands, `SN1/SN2/SN3` are **sticky**: they persist through subsequent hold rows and only reset when:
- Explicitly reset with `SN1 00`, `SN2 00`, or `SN3 00`
- A note-off (`===`) is encountered
- The pattern loops back to its start

This allows you to apply a send to multiple notes without re-entering the command on every row:

```
Row 1:  C-4 kick       | SN3 60  ← send to channel 16 at 60%
Row 2:  ... hold...    | (send continues automatically)
Row 3:  ... hold...    | (send continues automatically)
Row 4:  === note-off   | (send resets)
Row 5:  C-4 kick       | (no send, back to normal routing)
```

**Common use case:** Place a reverb or delay insert effect on channel 14, 15, or 16, then use `SN1`/`SN2`/`SN3` to send specific instruments or pattern sections to it.

### RET — Retrigger Volume Curves

| X digit | Curve |
|---|---|
| 0 | Flat (same volume each retrig) |
| 1–9 | *TBD — document curve shapes* |

### ARC — Arpeggio Mode & Configuration

ARC controls **how** the arp is played (mode) and **how fast** (speed). The X digit (tens) selects the mode; the Y digit (ones) sets how many notes play per line.

**Modes 1–3 (Linear)** — Play notes forward, one octave per mode:

| Mode | Octaves | Sequence (for ARP `37` = notes 3, 7) | Sound |
|---|---|---|---|
| 1 | 1 | `root, +3, +7` | Simple forward sweep |
| 2 | 2 | `root, +3, +7, root+12, +3+12, +7+12` | Two-octave ascending |
| 3 | 3 | (extends to +24 semitones) | Three-octave rising |

**Modes 4–6 (Bidirectional)** — Play forward, then backward with peak repeat:

| Mode | Octaves | Sequence (for ARP `37` = notes 3, 7) | Sound |
|---|---|---|---|
| 4 | 1 | `root, +3, +7, +7, +3, root` | Swell: up to peak, back down |
| 5 | 2 | (forward then backward, spanning 2 octaves) | Dramatic up-and-down |
| 6 | 3 | (extends across 3 octaves) | Sweeping riser/faller |

**Modes 7–9 (Random)** — Shuffle notes within each octave for organic variation:

| Mode | Octaves | Sequence (for ARP `37` = notes 3, 7) | Sound |
|---|---|---|---|
| 7 | 1 | Random order of `root, +3, +7` each cycle | Unpredictable fills |
| 8 | 2 | Shuffled across 2-octave range | Synth-sweep randomness |
| 9 | 3 | Shuffled across 3-octave range | Deep chaotic motion |

**Speed (Y digit, 0–9)**

The Y digit controls **notes per line**:

- `Y=0` (e.g., `ARC 10`) — play entire cycle each line (sequence length varies by mode)
- `Y=1` (e.g., `ARC 11`) — play 1 note per line, cycle repeats
- `Y=7` (e.g., `ARC 17`) — play 7 notes per line, stacking the cycle

**Examples**

- `ARC 17` — Mode 1 (linear, 1 octave), 7 notes per line. Plays 3-note sequence 2+ times per line.
- `ARC 45` — Mode 4 (bidirectional, 1 octave), 5 notes per line. Plays swell (up-down) 5 times per line.
- `ARC 79` — Mode 7 (random, 1 octave), 9 notes per line. Random notes fill the line.

### RNI — Random Instrument

**RNI** randomizes the active instrument slot on each note-on, allowing you to cycle through a range of different instruments from a single pattern cell. This is useful for adding variation and organic unpredictability without duplicating rows.

**How it works:**

- Place `RNI XY` on a pattern cell (where XY is the **upper limit** of the instrument range, `01`–`99`)
- On a note-on row, RNI picks a random instrument slot between the current instrument and the specified upper limit
- The randomized instrument is used immediately for that note, including all its parameters (pitch, wave, synth parameters, etc.)
- On **hold rows** (rows with `...`), the randomly-chosen instrument carries forward automatically — no re-roll happens
- Only when a new note-on occurs does a new randomization happen

**Example:**

```
Row 1:  C-4 kick (01)  | RNI 03
Row 2:  ... hold...    |
Row 3:  D-4 kick (01)  | RNI 03
```

On row 1, RNI randomly picks one of: instrument 01, 02, or 03. Let's say it picks 02. The note plays with instrument 02's full sound.

On row 2 (hold row), the same instrument (02) continues automatically without re-rolling.

On row 3 (new note-on), RNI re-rolls and might pick 01, 02, or 03 again — different from row 1.

**Common use case:** Assign 3–4 variations of the same drum (e.g. 4 slightly-different kick samples on slots 01–04), place them on a single track with `RNI 04`, and let the pattern randomly cycle through them for natural swing and variation.

### SLU / SLD — Pitch Slide Detail

Slide Up and Slide Down linearly move the pitch over X rows by Y semitones. The slide is sample-accurate within each row.

- `SLU 23` — slide up 3 semitones over 2 rows
- `SLD 14` — slide down 4 semitones over 1 row

Placing SLU/SLD on a **hold row** slides from the currently held pitch, allowing pitch changes without retriggering the note.

### VIB / TRE / GAT — LFO Carry Behaviour

All three LFO commands carry their speed and depth values forward through subsequent hold rows and stop when a note-off is reached. This means:

- Place the command on a **note row** to start the effect from the very beginning of the note.
- Place it on a **hold row** to add it mid-note without retriggering.
- Leave the hold rows bare — the last-set speed and depth stay active automatically.
- A `===` (note-off) resets the carry.

`VIB` and `TRE`/`GAT` are independent and can be combined on the same note: VIB modulates pitch while TRE/GAT modulates amplitude.

### TRE — Tremolo Detail

Tremolo applies a **sine-wave** volume LFO. The volume oscillates smoothly between full and attenuated based on the depth setting.

- X = 0 → very slow (0.1 Hz); X = 9 → fast (≈20 Hz)
- Y = 0 → no effect; Y = 9 → maximum depth (volume dips to silence at the trough)

### GAT — Gate Detail

Gate applies a **square-wave** volume LFO, creating a rhythmic stutter or gating effect. The volume switches abruptly between full and attenuated.

- Same speed (X) and depth (Y) encoding as TRE.
- At high depths, the signal cuts fully in and out — classic trance-gate / sidechain-compression imitation.
- At lower depths, the cuts are partial, producing a pumping texture.

---

## Slice Shorthand Notes (Sampler)

On sampler tracks, notes C-0 through G#0 are proxy slice triggers and do not need an FX command. See the **Instruments** section for the full table.

---

## Legacy Slice Select (SLx)

The older `SL0`–`SL9` commands select a slice region by command code rather than value:

| Command | Value | Description |
|---|---|---|
| `SL0` | 00 = play through / 01 = stop at next slice | Select slice 0 (sample start) |
| `SL1`–`SL9` | 00 = play through / 01 = stop | Select slice 1–9 |

> These commands remain supported for compatibility. For new patterns, prefer the `SLC` command or the shorthand notes.

---

## Mixer FX

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

## Insert FX Commands

Insert FX commands automate parameters of an insert effect slot from the pattern.

Format: slot number + function number encoded as a command code.

*TBD — document specific function numbers per effect type.*
