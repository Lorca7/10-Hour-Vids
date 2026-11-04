# 10 Hour Vids

A simple, standalone macOS app for making long still-image videos for YouTube: one photo plus music or
ambient sound, anywhere from **1 minute to 10 hours** long. Good for sleep music, study streams, rain sounds,
podcasts, and album uploads.

Runs on **macOS Sonoma 14.0 or later** (including 14.6), on both Apple Silicon and Intel Macs. It uses only
Apple's built-in frameworks (SwiftUI and AVFoundation), so there's nothing else to install: no ffmpeg, no
plug-ins.

## What it does

- **Drag and drop a photo** anywhere in the window (JPEG, PNG, HEIC, TIFF and so on). Choose how it fills the
  16:9 frame: *Fit* with a background colour, *Fill* (cropped), or *Fit on a blurred copy* of itself.
- **Set the video length** by typing it (`1:30:00`), picking a quick length (1 min … 10 h), dragging the end
  of the video bar on the timeline, or clicking **Match Length to Audio**.
- **Audio timeline**: drop MP3, M4A/AAC, WAV, AIFF, FLAC, CAF files, or even movie files (their audio is
  used), onto the timeline. Multiple lanes let you overlap tracks to mix them, for example music plus rain.
  - Drag a clip to move it (it snaps to the playhead, other clips, and the video's start and end)
  - Drag a clip's edges to trim it
  - **Split** at the playhead (⌘B), **Delete** (⌫)
  - **Loop** a clip, then drag it as long as you want or click **Loop to End of Video**
  - Volume, fade in, and fade out for each clip, with waveforms that show the fades
  - Undo and redo (⌘Z / ⇧⌘Z), all the way back
- **Preview** with Space (play/pause), ←/→ (±1 s, add ⇧ for ±10 s), Home/End. Click or drag on the ruler to
  scrub.
- **Save and open projects** (⌘S / ⌘O) so you can come back to an edit later.
- **Export for YouTube** (⌘E): an MP4 with H.264 video and AAC 48 kHz stereo audio, at 720p, 1080p, 1440p
  or 4K, and 24/25/30/60 fps. Your Mac won't sleep during an export.

### Why exports are fast

The picture never changes, so the app encodes 10 seconds of the photo **once**. It then writes those
compressed frames again and again for the full length, giving each copy new timestamps. Every copy starts
on a keyframe, so the file plays and uploads like any normal video. Only the audio is encoded for the whole
length, so a 10-hour video takes minutes instead of hours, and the file stays small (about 1–2 GB for 10 hours
at 1080p with 256 kbps audio).

## Install

### Option A: download the built app

**[Download TenHourVids-macOS.zip](https://github.com/Lorca7/10-Hour-Vids/releases/latest/download/TenHourVids-macOS.zip)**
(the latest build from the [Releases page](https://github.com/Lorca7/10-Hour-Vids/releases)).
Each build is compiled and self-tested on macOS 14 by GitHub Actions before it is published.
Unzip it and drag **10 Hour Vids.app** into Applications.

The app is not notarised by Apple, so the first time you open it, **right-click the app, choose Open,
then click Open** in the dialog. If macOS says the app "is damaged", run this once in Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/10 Hour Vids.app"
```

### Option B: build it yourself (about 2 minutes)

You need Apple's free command line tools. Install them with `xcode-select --install`, or install Xcode.

```bash
git clone https://github.com/Lorca7/10-Hour-Vids.git
cd 10-Hour-Vids
./scripts/build-app.sh            # creates dist/10 Hour Vids.app (Apple Silicon + Intel)
open "dist/10 Hour Vids.app"
```

To build only for your own Mac's chip, which is faster, use `ARCHS=arm64 ./scripts/build-app.sh` (or
`ARCHS=x86_64` on Intel). During development you can also just run `swift run`.

## Quick start

1. Drag a photo into the window.
2. Drag your audio files onto the timeline.
3. Set the length, for example by picking **Quick Lengths → 10 hours**, then select your audio clip and click
   **Loop to End of Video**. Add a fade out for a soft ending.
4. Press **⌘E**, pick a resolution, and click **Export…**.
5. Upload the MP4 at [studio.youtube.com](https://studio.youtube.com). Videos longer than 15 minutes need a
   verified YouTube account, and YouTube accepts uploads of up to 12 hours.

## Self-test

The app has a built-in headless test. It checks the editing logic and makes real exports, including a full
10-hour video, then decodes them to confirm the length, resolution, codecs, picture, and audio:

```bash
"dist/10 Hour Vids.app/Contents/MacOS/TenHourVids" --self-test          # quick
"dist/10 Hour Vids.app/Contents/MacOS/TenHourVids" --self-test --long   # also renders 10 hours
```

## Project layout

| File | Purpose |
| --- | --- |
| `Sources/TenHourVids/Models.swift` | Project, clip, and export data plus clip maths (looping, trimming, splitting) |
| `Sources/TenHourVids/EditorModel.swift` | Editing operations, undo, playback, snapping, saving |
| `Sources/TenHourVids/TimelineViews.swift` | Ruler, video bar, audio lanes, waveforms, drag and trim gestures |
| `Sources/TenHourVids/ContentView.swift` | Window layout, preview, inspector, transport bar, export sheet |
| `Sources/TenHourVids/AudioEngine.swift` | Builds the audio mix (AVComposition + fades) and waveform peaks |
| `Sources/TenHourVids/VideoExporter.swift` | The MP4 writer |
| `Sources/TenHourVids/FrameRenderer.swift` | Photo loading and frame composition (fit, fill, blur) |
| `scripts/build-app.sh` | Builds the `.app` bundle |
