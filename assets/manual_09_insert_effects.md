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

---

## EQ-5

Five independent tone controls, each from -10 to +10 dB:

| Control | Frequency | Shape |
|---|---|---|
| Bass | 60 Hz | Low shelf |
| Warmth | 250 Hz | Bell, Q=1 |
| Presence | 1 kHz | Bell, Q=1 |
| Clarity | 4 kHz | Bell, Q=1 |
| Air | 12 kHz | High shelf |

All five controls now process audio on both tracks and the master. Previously,
Warmth and Clarity were saved but did not affect audio, and the other bands used
approximate frequencies. Existing EQ-5 settings are retained, so older songs
with nonzero settings may sound different after this correction. The separate
three-band EQ is unchanged.

Pattern commands `F[S]3/4/5/8/9` control Bass/Presence/Air/Warmth/Clarity.
Values 00-99 span -10 to +10 dB; 49/50 are near zero.

---

## Flanger

Modulated short delay with bipolar feedback. Controls: Rate, Depth, Delay,
Feedback, Stereo, Dry and Wet.

Pattern commands (`S` is the insert slot, 1-6):

| Command | Control |
|---|---|
| `F[S]2` | Stereo: 00=mono, 01-99=stereo |
| `F[S]3` | Rate |
| `F[S]4` | Depth |
| `F[S]5` | Delay |
| `F[S]8` | Feedback: 00=-95%, 49/50=near zero, 99=+95%; extremes clamped |

Rate, depth and delay use 00-99 for their full parameter range.
As with other inserts, `F[S]0` restores the saved mixer snapshot,
`F[S]1` controls bypass, and `F[S]6/7` control dry/wet levels.

---

## Clipper (formerly Limiter)

The insert previously labelled **Limiter** is now labelled **Clipper** to match
its existing hard-clipping behaviour. Its sound, gain range (0 to +24 dB), pattern
commands and saved-song identifier are unchanged. Older songs load automatically.

The processed (wet) signal clips at -0.1 dBFS. Adding dry signal can exceed this
level. This is not a look-ahead or true-peak limiter. The separate master safety
limiter is unchanged.
