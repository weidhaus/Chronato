# Chronato brand

**Name:** Chronato. One word, capital C. Native UI labels use the system font.

## The mark: the C-stopwatch

A thick ring that opens on the right like a letter C, a stopwatch crown on
top, and one hand from the centre to 2 o'clock with a pivot dot. Ring and
crown are silver (or the one colour of a flat version); the hand and dot are
tomato.

Construction, on a 64-unit grid with y pointing up (the master is in
`scripts/make-icon.swift`):

| Part | Value |
|---|---|
| Ring | centre (34, 28.5), radius 18.5 to the stroke's centre line, weight 7.5, round caps |
| Opening | ±40° around 3 o'clock. With the caps, the visible ring is about 300° |
| Crown | stem 5 wide; button 15 × 5.5, corner radius 2.2, 2.6 above the ring |
| Hand | 10.5 long, 4 wide, round caps, at 2 o'clock (30° above horizontal) |
| Pivot | dot, radius 3.9 |

The ring's centre sits two units right of the grid's centre, because a C
carries its weight on the left; that centres the mark's outline. Icon sizes
of 32 px and below thicken the strokes so the mark still reads at 16 px.

## Colours

| Name | Hex | Use |
|---|---|---|
| Tomato | `#E5533D` | The only accent: the hand, running state, primary buttons |
| Graphite | `#1E1F22` | Icon base, the flat mark on light backgrounds |
| Silver | `#C9CCD1` | The ring, the flat mark on dark backgrounds |

App-icon materials: graphite tile `#3A3D42` → `#1A1B1E` (top to bottom),
satin silver `#F4F5F7` → `#8F949B`, tomato `#F57A63` → `#C4412D` (top left to
bottom right).

## Files

- `logo.svg`: the flat mark, for the README and the web. Graphite in light mode, silver in dark mode.
- `logo-1024.png`: the app icon at 1024 px, for presentations.
- `AppIcon.icns`: every macOS icon size, built by `swift scripts/make-icon.swift Branding`.
- `AppIcon-iOS-1024.png`: the iPhone icon, full bleed (iOS rounds the corners) and without alpha, from the same script. A copy sits in `iOS/App/Assets.xcassets`.
- The menu-bar glyph is drawn in code: `Brand.menuBarGlyph(running:)` in `Sources/Chronato/Brand.swift`. It is an 18 pt template image (idle: ring and crown; running: bolder, with hand and dot).

## Usage

- Keep the hand tomato in colour versions. In a one-colour version (black, white, graphite or silver), everything takes that colour.
- Tomato stays an accent. Don't use it for large fills, or for small text on white (3.7:1 contrast; 4.4:1 on graphite).
- Don't rotate, outline, stretch or re-angle the mark, and don't put text or a second hand inside it.
- Leave clear space of at least a quarter of the mark's height on all sides.
- The smallest sizes are 16 px for the app icon and the dedicated 18 pt glyph in the menu bar.
- Change the master, `logo.svg` and `Brand.menuBarGlyph` together.
