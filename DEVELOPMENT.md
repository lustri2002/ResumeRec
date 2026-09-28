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

The public landing is rendered from `docs/index.html`, with `docs/styles.css` and assets in `docs/images`. The deployed site is plain HTML and CSS, with no browser-side JavaScript, package dependencies or external fonts. GitHub Pages uses **GitHub Actions** as its publishing source.

`.github/workflows/website.yml` runs when a release is published, edited, promoted to stable or deleted, when website sources change on `main`, or when manually dispatched. It always checks out the current website from `main` and queries all release pages, including prereleases. `scripts/build-site.py` selects the most recently **published** non-draft release, rather than GitHub’s stable-only `latest` endpoint. An edit to an older release therefore cannot roll the site back.

The build updates all three DMG links, the version/channel label and the release-notes link. It requires exactly one nonempty, fully uploaded `ResumeRec-*-arm64.dmg` and its matching `.dmg.sha256` asset on the selected release. Missing assets or changed template markers fail the build before deployment, leaving the current website live. Only the explicit public asset list is copied; ignored local notes in `docs/` are never uploaded. No commits or personal access tokens are needed for deployment.

### Publish a new app release

1. Create a **draft** release from the app’s tagged source commit; use a `v`-prefixed tag, such as `v0.2.8-beta.3`.
2. Upload the DMG and its matching checksum to the draft and add release notes.
3. Mark it as a prerelease when appropriate, then **publish** it. The website workflow updates the live page automatically after a successful build.
4. Check **Actions → Publish website**. If assets were uploaded after publication, finish uploading them and use **Run workflow** on `main` (or edit the published release) to retry.

The `github-pages` environment permits deployments from `main` and `v*` release tags. Version and download metadata update automatically; changes to macOS requirements, supported architectures, signing/notarization or product copy still need a template edit. README download links lead to the website and release list, so they do not embed an app version.

If app releases are later published by another GitHub Actions workflow using `GITHUB_TOKEN`, explicitly dispatch `website.yml` on `main` after upload: GitHub does not trigger a second workflow from ordinary events created with that token. Releases published through the GitHub UI or a separately authenticated CLI trigger it normally.

### Local preview and checks

From the repository root, use a fresh output directory:

```sh
gh api --paginate --slurp 'repos/lustri2002/ResumeRec/releases?per_page=100' > /tmp/resumerec-releases.json
python3 scripts/build-site.py --releases /tmp/resumerec-releases.json --output dist/site-preview
python3 -m http.server 8765 --bind 127.0.0.1 --directory dist/site-preview
```

Open `http://127.0.0.1:8765`. The source HTML contains build placeholders; preview the rendered output, not `docs/`. To avoid overwriting files, the builder refuses an existing output directory. Choose another output path for the next preview.

Run release-selection, rendering and asset-isolation regressions with:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p 'test_build_site.py' -v
```

Site-only changes do not require rebuilding the macOS app. To republish after an API outage or restore the current source and release data, run `gh workflow run website.yml --ref main`. A failed site deployment does not affect the downloadable app or the previous site.

## Packaging and release

```sh
zsh scripts/build-dmg.sh dist/ResumeRec.app
```

An optional second argument sets the destination DMG path. Existing output files are never overwritten. The script checks architecture/signature, stages the app plus an Applications shortcut and instructions, creates a compressed read-only DMG, verifies it, and writes a SHA-256 file. The build uses the macOS-provided `hdiutil` for compatibility with macOS 26; macOS 27 may print a deprecation notice.

App builds and release uploads are manual; only website publication is automated by GitHub Actions. GitHub Releases hosts the downloadable DMG separately from the source tree. Only publish a package built from the tagged source commit. Include the checksum and release notes, and mark preview versions as pre-releases.

The free beta is ad hoc signed, not Developer ID signed or notarized. Verify a downloaded release on another Mac/account: local packaging checks do not simulate quarantine or first-run privacy permissions.
