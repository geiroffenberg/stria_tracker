# Stria — User Manual: Project Management

Projects are stored as folders on device storage.

---

## Structure

```
<project-folder>/
  <project-name>/
    project.json      — song, patterns, instruments
    *.wav             — any exported or recorded audio files
```

## Saving

Use **Song → Save Song** (or the menu icon). The project is written to `project.json` in the chosen project folder.

## Loading

Use **Song → Load Song** (menu or save/load panel) to open a scrollable bottom sheet listing all saved projects. Tap a project name to load it. The list shows every subfolder that contains a `project.json` (or legacy `song.json`) file.

## Project Folder

Use **Choose Project Folder** to grant the app access to a folder via the Android Storage Access Framework. This permission persists across sessions.

## Export WAV

**Export WAV** renders the full song offline to a stereo 16-bit WAV file saved inside the project folder, including master processing and the current mute/solo settings.

Like stem export, WAV export streams audio to a temporary file and copies the completed file to your project folder, avoiding whole-song audio transfers through Flutter. The existing effect tail and final fade are preserved. Storage and export-length errors are reported instead of saving an incomplete render.

## Export Stems

Stop playback, then choose **Song menu → Export Stems** and confirm the export rules.

- Each used track routed directly to **Master** gets a separate stereo **32-bit float WAV**. Tracks with no musical data and no incoming routing or parallel sends are skipped. Usage is checked across the exported arrangement (ending at the first empty pattern), not by measuring audio loudness.
- Tracks routed into another track are included in that destination bus, not exported separately. Chained/self routing is not supported.
- Track/bus inserts, volume, pan, automation, sidechains and parallel send returns remain active. All stems render together in one pass.
- **Mute and Solo are ignored**, without changing your mixer settings.
- **Master effects, master volume, master mute and the master safety limiter are excluded.** Recombining the stems therefore recreates the unmastered mix, not necessarily your processed master export.
- Files start together and have the same duration, including a common six-second tail with a fade over the last 250 ms. Longer effect tails are cut off.
- Float WAV preserves levels above 0 dBFS without clipping. Lower levels before playback if your destination cannot handle that headroom.

Each export creates a new `stems_<timestamp>` folder inside the project folder, with files such as `Track_01_Bass.wav`. Existing exports are not overwritten. Keep the export dialog open until rendering and saving finish.
