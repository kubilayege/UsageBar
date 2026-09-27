# UsageBar app artwork

The icon is drawn in code by [`scripts/render-app-icon.swift`](../../scripts/render-app-icon.swift):

```sh
swift scripts/render-app-icon.swift Sources/UsageBar/Resources/AppLogo.png
```

It is a flat version of the app's window meter: three meters on a graphite tile, filled in apricot
(`#EBA27A`), the tallest carrying the hatched "projected by reset" run, and a bone (`#EFE8E1`) needle
cut across all three, the same marks the popup and dashboard draw. The tile follows the macOS icon grid
(an 824-point rounded square on a 1024 canvas) with a transparent margin.

`AppLogo.png` is used inside the app, and `scripts/build-app.sh` derives the macOS `AppIcon.icns`
sizes from it. The menu bar draws the same mark in white in `MenuBarIcon.whiteLogo()`.
