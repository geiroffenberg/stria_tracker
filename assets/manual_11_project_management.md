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

**Export WAV** bounces the full song in real time to a stereo WAV file saved inside the project folder.
