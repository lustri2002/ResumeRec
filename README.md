<p align="center">
  <img src="Resources/Brand/AppIcon-source.png" width="128" alt="ResumeRec icon">
</p>

# ResumeRec

**A simple macOS screen recorder. Pause, resume, and keep going.**

Record your screen with an optional webcam overlay, system audio and microphone. ResumeRec lives in the menu bar, saves MP4 files directly to your chosen folder, and removes paused time from the final video. No account, editor, tracking or subscription.

**Requirements:** Apple Silicon (M1 or newer), macOS 26 or later. The current release is a beta.

## Download and install

1. Open [Releases](https://github.com/lustri2002/ResumeRec/releases) and download the `.dmg` from the newest beta.
2. Open the DMG and drag **ResumeRec** onto **Applications**.
3. Eject the DMG and open ResumeRec from Applications.
4. Look for the **RR** icon in the menu bar and open **Settings**.

### First launch: macOS security

The free beta is **ad hoc signed and not notarized by Apple**. macOS may block its first launch after download. If you trust this copy, try opening the app, then go to **System Settings → Privacy & Security → Open Anyway**, if available, and confirm the opening. Managed Macs may restrict this option. See [Apple's instructions](https://support.apple.com/en-us/102445).

You can also build the app from source. No paid Apple Developer membership is needed for this project's local ad hoc build.

Release downloads include a `.sha256` file. In the folder containing both downloads, run `shasum -a 256 -c ResumeRec-0.2.8-beta.1-arm64.dmg.sha256` to check the DMG's integrity. A checksum is not a developer identity certificate.

## Start recording

1. In **Output**, choose where recordings should be saved.
2. In **Recording**, choose a display, window or region and enable the audio sources you need.
3. In **Webcam**, optionally enable the camera and customize its shape, size, border and position.
4. Click **Start Recording**. Use the menu bar or configurable shortcuts to **Pause**, **Resume** and **Stop & Save**.

Allow screen recording, camera and microphone access when macOS asks. If screen access is unavailable, follow the instructions in Settings; quit and reopen ResumeRec if macOS requests it. Granting permission does not automatically start a recording.

## Features

- Display, window or region capture, one monitor at a time.
- Pause and resume with the paused time removed from video and audio.
- Optional webcam in the saved video, independent of the local preview.
- Life-size webcam preview on your desktop, with free dragging and eight preset positions.
- Circle, square and rounded rectangle shapes, white border and mirroring.
- Independent system audio and microphone, with device selection.
- Source and device lists refresh automatically when their dropdown opens.
- Source changes while paused, preserving the recording's original video dimensions.
- Optional countdown, keyboard shortcuts and automatically saved settings.
- H.264 or HEVC, configurable resolution, frame rate and capture bitrate.
- Timestamped MP4 files, plus manual recovery of completed temporary segments.
- Compact English settings interface; offline operation with no telemetry.

## Build from source

Install Xcode or Command Line Tools with **Swift 6 and macOS SDK 26 or later**. Build on an Apple Silicon Mac. Swift 5 language mode is configured in the package.

```sh
git clone https://github.com/lustri2002/ResumeRec.git
cd ResumeRec
zsh scripts/build-app.sh
```

Open `dist/ResumeRec.app`. Use the app bundle when testing privacy permissions. The script builds Release and applies a local ad hoc signature; it does not install or launch the app.

To create a DMG:

```sh
zsh scripts/build-dmg.sh dist/ResumeRec.app
```

See [Development](DEVELOPMENT.md) for testing, architecture, build options and packaging details.

## Beta limitations

- Apple Silicon only; one monitor at a time.
- Saving joins segments, re-encodes video and mixes audio. It needs time and additional free disk space. Final export uses the selected codec's highest-quality preset; capture bitrate is not a strict final-file bitrate limit.
- System audio follows the selected ScreenCaptureKit source. There is no separate per-app audio selector.
- A closed or relaunched source window must be selected again.
- Recovery can salvage completed readable segments; a crash may lose the segment being written.
- No automatic updater. Save and quit, then replace the app in Applications when installing an update.
- The development environment is macOS 27. Feedback from macOS 26, external devices, mixed display scaling and different keyboard layouts is welcome.

## Privacy

ResumeRec does not upload recordings, collect analytics or contact an online service. Preferences are stored locally; recordings and temporary session files are saved in your chosen folder. macOS manages device permissions and may perform its own system security checks.

## Feedback and contributions

Report bugs or suggest features in [Issues](https://github.com/lustri2002/ResumeRec/issues). Include your app/macOS versions, Mac chip, recording settings and reproduction steps. Do not attach private recordings unless you intentionally want to share them publicly.

See [Contributing](CONTRIBUTING.md) and [release notes](CHANGELOG.md).

## License

[MIT](LICENSE) — Copyright © 2026 Alessio Lustri.
