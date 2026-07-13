# Stria — User Manual: Core Concepts

This section covers the behaviours in Stria that differ from most other trackers. If you are coming from Renoise, FamiTracker, or similar tools, read this first.

---

## BPM Is Per-Pattern, Not Global

In most trackers, BPM is a single global value for the whole song. In Stria, **each pattern carries its own BPM**. When the song moves from one pattern to the next, the engine immediately switches to that pattern's tempo.

This means:
- A breakdown section can run at 70 BPM while the main loop runs at 140 BPM — no automation required.
- Tempo changes are structural (arranged in the Song screen) rather than encoded as FX commands.

---

## LPB Controls Row Duration, Not Just Visual Resolution

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

## LPB Is Also Per-Pattern

Like BPM, **LPB is stored per pattern**. Every pattern can have a different rhythmic subdivision. Common uses:

- A swing/groove pattern at LPB=6 alongside a straight pattern at LPB=4.
- A dense fill pattern at LPB=8 followed by a sparse passage at LPB=2.
- Polyrhythmic structures where each pattern represents a different time feel.

> **Tip:** Because both BPM and LPB are per-pattern, Stria can produce complex metric modulations simply by switching patterns — no tempo automation tracks needed.

---

## Instrument Column (IN)

The IN column controls both *which instrument slot* is active and *whether a note triggers at all*.

| IN value | Effect |
|---|---|
| `--` (empty) | No trigger. The last-used instrument slot is silently carried. Any note in the NOTE column is ignored — the row acts as a hold. |
| `00` | No trigger. If a note is written on this row, the pitch of the currently playing voice is updated immediately — the amplitude envelope is **not** retriggered. If the instrument has **Glide** set, the pitch transition is smoothed. |
| `01`–`99` | Switch to that instrument slot and trigger the note (if one is present in NOTE). |

**Key rule:** a note only fires when IN is `01`–`99`. Every new note-on must carry an explicit instrument number. This makes every trigger unambiguous.

`00` is a compact portamento shorthand: write a destination note with IN = `00` to glide to a new pitch without restarting the envelope.

---

## Note Hold vs. Note Off

| NOTE column | IN column | Meaning |
|---|---|---|
| `---` | any | Empty note — the current note keeps playing (hold) |
| `OFF` | any | Send a note-off, silence the track |
| Note (e.g. `C-4`) | `--` (empty) | No trigger — acts as a hold. The note value is ignored. |
| Note | `00` | Pitch-change only — no retrigger; glide applies if set on the instrument |
| Note | `01`–`99` | Full note-on — triggers with the specified instrument slot |

---

## FX Carry Behaviour

Some FX commands persist across rows; others fire once and are done:

| Command | Carries? | Notes |
|---|---|---|
| `VIB` | Yes | Vibrato continues until note-off or a new VIB with depth 0 |
| `PAN` | No | Sets pan for that row only (mixer channel retains its own state) |
| `SLC` | No | Fires once at row start |
| `INST` | Yes | Carries to subsequent rows until changed |

> More carry rules will be documented here as the app evolves.

---

## Sampler Slice Proxy Notes

On **sampler** tracks, the first 9 chromatic notes of octave 0 (C-0 through G#0) are reserved as single-keystroke slice triggers. They are not available as pitched notes on sampler instruments. Any note from A#0 (MIDI 21) upward plays the full sample at normal pitch.

See the **FX Commands** section for the full table.
