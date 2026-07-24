# Stria — User Manual: FX Commands

FX commands are entered in the FX column of a pattern cell. Each command takes a two-digit value (00–99). Multiple FX slots per cell allow stacking commands on the same row.

---

## General FX

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
| `ARC` | XY | Arp mode config. X = mode (1–9), Y = notes per line. 1–3 = linear, 4–6 = bidirectional, 7–9 = random |

### ARP — Arpeggio Detail

The arp cycles through root → root+X → root+Y semitones. Values 0–9 are chromatic semitones:

`0`=unison, `1`=m2, `2`=M2, `3`=m3, `4`=M3, `5`=P4, `6`=tritone, `7`=P5, `8`=m6, `9`=M6

ARP can be placed on a hold row to start arpeggiation mid-note.

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
