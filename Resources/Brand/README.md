# ResumeRec artwork

Approved direction: two readable R letters, a red recording dot inside the first R and a white play triangle inside the second, on a charcoal macOS app tile.

## Files

- [Approved master PNG](AppIcon-source.png)
- [macOS icon](../AppIcon.icns)
- [Monochrome master PNG](MenuBar-source.png)
- [Menu bar, 1×](../MenuBarTemplate.png) and [2×](../MenuBarTemplate@2x.png)
- [Size proof](Icon-size-proof.png)

Artwork was generated/edited with the built-in imagegen tool. The original generated files were retained. App icon conversion uses sips and iconutil; menu template packaging uses AppKit to trim transparent margins, preserve alpha and export 1×/2× representations. No recording or screenshot is used for the proof.

Regenerate the icon formats with `zsh scripts/build-icons.sh`. Regenerate the menu assets and proof with `swift scripts/prepare-menu-icon.swift Resources`. Run from the project directory. The app build copies the prepared files into the bundle before signing.

## Final app-icon edit prompt

Precise icon edit. Preserve this exact charcoal rounded-square app tile, its size, lighting, transparent exterior, centered bold white RR typography, spacing and the coral-red recording dot centered in the first R counter. Only make these changes: (1) the diagonal leg of the SECOND R must match the FIRST R's normal leg exactly in shape, length and baseline, so these are two identical readable forward-facing uppercase R letters; remove the unusual shortened diagonal terminal. (2) Inside the dark upper counter of the SECOND R, center a small solid white right-pointing play triangle, optically balanced with the red REC dot in the first R. The triangle should be the same visual scale as the red dot, with ample dark clearance on all sides, no touching the bowl. These two small in-letter symbols express record and resume. Keep all other elements unchanged. Clean sharp geometric logo, subtle restrained tile shading, no new words, no labels, no additional decorative elements. One icon.

Input was the earlier RR + REC concept (`exec-c2714819-8fb9-4f78-936d-561c9715b396.png`); approved output was `exec-72d14aba-a7cd-4d06-b355-858244e829ef.png`.

## Monochrome edit prompt

Extract and adapt ONLY the central RR monogram from this app icon as a monochrome macOS menu-bar template image. Preserve the two recognizable forward-facing capital R shapes with identical diagonal legs, the recording circle inside the first R counter and the play triangle inside the second R counter. Remove the entire rounded-square tile, all shading, texture, glows and shadows. All letter strokes AND the circle AND the play triangle must be SOLID PURE BLACK at full opacity; both letter counters and all surroundings must be genuinely transparent. Crisp flat vector-like geometric mark. The letters must have clear transparent space around the little black circle and triangle, no merging with the letter outline. Enlarge the tiny symbols slightly if necessary for small-size legibility. Center the monogram, tightly framed with very small equal margins, preferably a landscape canvas matching the monogram proportions. No gradients, gray fills, white background, wordmarks or mockup. One clean monochrome transparent icon asset.

Input: approved app icon. Transparent background enabled. Output: `exec-66063c5f-771f-46dc-953d-089931140ed9.png`.
