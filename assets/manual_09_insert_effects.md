# Stria — User Manual: Insert Effects

Insert effects process the audio of a single channel in real time. Each slot has input gain, output gain, dry/wet, and bypass controls in addition to its own parameters.

---

## Reverb

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

## Delay

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

## Filter

A state-variable filter (SVF) with three modes.

| Parameter | Range | Description |
|---|---|---|
| Mode | LP / HP / BP | Filter type |
| Cutoff | 0–1 | Filter frequency (~20 Hz – 20 kHz) |
| Resonance | 0–1 | Resonant peak at cutoff |

---

## Distortion

A waveshaping distortion with a post-tone filter.

| Parameter | Range | Description |
|---|---|---|
| Drive | 0–1 | Input gain (higher = more clipping) |
| Tone | 0–1 | One-pole low-pass on the output (0 = dark, 1 = bright) |
| Type | Soft-clip / Fold | Waveshaper character |
