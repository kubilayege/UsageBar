# UsageBar app artwork

Generated with the built-in imagegen tool. The source artwork is
`Sources/UsageBar/Resources/AppLogo.png`; its alpha channel is preserved.
`scripts/build-app.sh` derives the macOS icon sizes from this image.
The menu bar draws a simplified white silhouette in `MenuBarIcon.whiteLogo()`.

## Generation prompt

```text
Use case: logo-brand
Asset type: production macOS app icon for UsageBar, a menu bar app that tracks AI coding assistant usage.
Primary request: Create one polished, distinctive app icon. A warm peach usage-meter emblem made of three thick vertical rounded bars with their bottoms aligned: left bar medium height, middle bar short, right bar tallest. A small, crisp four-point sparkle sits in the open space above the middle bar, evoking AI. The bars should form a balanced, compact, instantly recognizable symbol, readable at 32 pixels.
Scene/backdrop: a single warm charcoal rounded-square macOS icon tile, with smooth continuous corners, extremely subtle bevel and a fine warm edge highlight. Genuine transparent background outside the tile.
Color palette: charcoal #2A2321 to #342B28 tile, peach #E3956A and softly lit apricot highlights on the emblem. Match an elegant warm dark interface.
Style/medium: premium restrained native macOS utility icon, clean geometric forms, softly dimensional satin finish, no distracting texture.
Composition/framing: square 1024 by 1024 canvas, icon tile centered with about 8 percent transparent padding on every side; emblem generously sized in the tile with balanced internal negative space. Straight-on orthographic view.
Constraints: one finished icon only, no text, no letters, no words, no mockup, no scene, no second icon, no presentation board, no watermark, no external drop shadow, no checkerboard baked into the image. Preserve actual alpha transparency outside the rounded-square tile.
```
