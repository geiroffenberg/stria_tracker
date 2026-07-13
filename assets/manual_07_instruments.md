# Stria — User Manual: Instruments

---

## 7.1 Sampler

The Sampler plays an audio file loaded from storage.

### Parameters

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

### Filter (HP → LP)

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

The filter parameters can be automated per-row using `Pxx` commands.

### Chop Operations

Two buttons are available to extract audio regions into new instrument slots:

| Button | Description |
|---|---|
| CHOP TO NEW SLOT | Extracts the region between **Start** and **End** as a new mono 16-bit WAV file and places it in the next empty instrument slot as a sampler. The new slot is selected automatically. |
| CHOP ALL SLICES TO NEW INSTRUMENTS | Extracts each active slice (SL1–SL9, i.e. any slice with a non-zero marker) into its own WAV file, filling consecutive empty slots in order. The output files are named `<source>_sl1.wav`, `_sl2.wav`, etc. The last created slot is selected when done. |

Both operations convert to mono 16-bit PCM and preserve the source instrument's pitch, volume, attack, and release settings.

### Slices

Up to **9 slice markers** can be placed within the sample (opened via the SLICES section in the instrument editor). Each marker is a position (0–99) that divides the sample into regions. Markers are set with the **RESET ALL** button to clear, or adjusted individually per-slice.

- Slice 1 begins at its marker and ends at slice 2's marker (or the end if slice 2 is unset).
- Inactive slices (value 0) are skipped; adjacent active slices form contiguous regions.
- Slices are addressed in the pattern using slice shorthand notes or the `SLC` FX command.

### Slice Shorthand Notes (C-0 to G#0)

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

### Sampler Pxx — Parameter Automation

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

## 7.2 Simple Synth

A three-oscillator synthesiser with FM modulation, a multi-mode filter, ADSR envelope, LFO, and drive.

### Oscillators

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
| FM→1 / FM→2 | FM depth — how strongly this oscillator frequency-modulates the previous one |

### FM Modulation

FM routing is chained: **OSC 3 → modulates OSC 2 → modulates OSC 1**.

- The **FM knob on OSC 2** controls how much OSC 2 bends OSC 1's frequency each sample.
- The **FM knob on OSC 3** controls how much OSC 3 bends OSC 2's frequency.
- At **FM = 0** the oscillator acts as a plain additive voice (no modulation). This is the default.
- At **FM = 100%** the carrier frequency can swing up to ±3× its base value, producing rich inharmonic sidebands.
- **GAIN and FM are independent:** set GAIN = 0 to use an oscillator as a pure (inaudible) modulator, or combine both for additive-plus-FM timbres.

### Amplitude Envelope (ADSR)

| Parameter | Description |
|---|---|
| Attack | Time to reach full level |
| Decay | Time to fall to sustain level |
| Sustain | Level held while note is on |
| Release | Time to fade out after note-off |

### Filter

| Parameter | Description |
|---|---|
| Mode | LP (low-pass), HP (high-pass), BP (band-pass) |
| Cutoff | Filter frequency (0–1) |
| Resonance | Resonant peak at cutoff (0–1) |
| Env Amount | How much the filter ADSR modulates cutoff |
| Filter ADSR | Separate A/D/S/R controls for filter cutoff movement |

### LFO

| Parameter | Description |
|---|---|
| Rate | 0.1–20 Hz |
| Depth | Modulation amount (0–1) |
| Target | Pitch, Filter cutoff, or Amplitude |

### Other

| Parameter | Description |
|---|---|
| Detune | ±12 semitones from root note |
| Drive | Soft saturation/distortion (0–1) |
| Glide | Portamento time between notes |

---

## 7.3 Karplus-Strong

A physical modelling synthesiser that emulates a plucked string by exciting a delay loop with filtered noise.

### Parameters

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
