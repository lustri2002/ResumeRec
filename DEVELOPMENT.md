# Development

ResumeRec is a native AppKit/SwiftUI menu-bar app for macOS 26+ on Apple Silicon. There are no third-party runtime dependencies.

## Layout

- `Sources/Pausa`: menu bar, settings, ScreenCaptureKit capture, camera preview, media composition, export and recovery.
- `Sources/PausaCore`: persisted preferences and pure geometry calculations.
- `Tests/PausaCoreTests`: Swift Testing geometry and preference regressions.
- `Resources`: Info.plist, prepared app/menu-bar icons, source artwork and installer instructions.
- `scripts`: local build, asset generation and DMG packaging.

The Swift package/module names and bundle identifier `local.pausa.recorder` retain the project's original name to preserve existing preferences. The product, executable inside the bundle and interface are named ResumeRec.

## Build

```sh
zsh scripts/build-app.sh
```

The default output is `dist/ResumeRec.app`. `PAUSA_BUILD_DIR` overrides the SwiftPM scratch directory; `PAUSA_APP_DIR` chooses a different bundle destination. Never overwrite a bundle that is running or recording. Build to a new path instead.

## Tests

With Xcode selected:

```sh
swift test --disable-xctest
```

Some Command Line Tools installations require the bundled Swift Testing plugin path:

```sh
swift test --disable-xctest \
  -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

After building, these integration checks can run from the bundle:

```sh
dist/ResumeRec.app/Contents/MacOS/ResumeRec --permission-self-test
dist/ResumeRec.app/Contents/MacOS/ResumeRec --drag-self-test
dist/ResumeRec.app/Contents/MacOS/ResumeRec --media-self-test
```

The permission check injects simulated authorization results and uses isolated preferences. The drag/clock check verifies that intermediate movement and clock ticks do not publish or persist unnecessary settings updates. The media test uses synthetic video/audio to check pause removal, webcam composition, audio mixing, native YUV input and rendered-frame reuse. These checks do not replace testing real macOS permission prompts or real capture devices. The model reads screen/device metadata and the media test needs the system GPU/encoder services, so restrictive execution sandboxes may prevent them from running.

## Capture architecture

`RecorderModel` owns recording state and preferences. Each recording interval is a temporary MOV segment, so paused time is removed when the exporter joins the segments. Canvas dimensions remain fixed for the session. ScreenCaptureKit supplies screen/system/microphone audio; AVFoundation supplies the camera. Core Image composites the webcam, and AVAssetWriter/AVAssetExportSession handle encoding and final export.

The camera preview uses AVSampleBufferDisplayLayer. Drag positions are transient and are persisted once when dragging finishes. Overlay updates use a latest-value mailbox. The menu-bar clock updates independently of the SwiftUI settings observation model.

Screen authorization is checked before source discovery. Unavailable access uses inline guidance rather than an error alert over the system permission prompt. Device and source dropdowns refresh on opening.

## Artwork

Prepared assets are included; building the app does not require an image-generation service. [Artwork notes and prompts](Resources/Brand/README.md) document the icon's origin and optional regeneration commands.

## Project website

The public landing page lives in `docs/index.html`, with `docs/styles.css` and assets in `docs/images`. It uses plain HTML and CSS, with no JavaScript, package dependencies or external fonts. GitHub Pages publishes the committed `/docs` directory from `main`; `.nojekyll` disables Jekyll processing. Local development notes are ignored by Git and are not published.

Preview it from the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory docs
```

Open `http://127.0.0.1:8765`. When publishing a release, update the version label, all three DMG links and the release-notes link in `docs/index.html`, plus the README release links. Confirm the assets exist on GitHub before changing links. Check mobile and desktop layouts and the first-launch instructions. Site-only changes do not require rebuilding the macOS app.

## Packaging and release

```sh
zsh scripts/build-dmg.sh dist/ResumeRec.app
```

An optional second argument sets the destination DMG path. Existing output files are never overwritten. The script checks architecture/signature, stages the app plus an Applications shortcut and instructions, creates a compressed read-only DMG, verifies it, and writes a SHA-256 file. The build uses the macOS-provided `hdiutil` for compatibility with macOS 26; macOS 27 may print a deprecation notice.

Builds and uploads are manual; the repository has no paid build service or automatic release workflow. GitHub Releases hosts the downloadable DMG separately from the source tree. Only publish a package built from the tagged source commit. Include the checksum and release notes, and mark preview versions as pre-releases.

The free beta is ad hoc signed, not Developer ID signed or notarized. Verify a downloaded release on another Mac/account: local packaging checks do not simulate quarantine or first-run privacy permissions.
