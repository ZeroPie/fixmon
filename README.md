# fixmon

Menu-bar app that fences off a damaged strip on the left edge of an external display, so macOS
behaves as if that part of the screen doesn't exist.

- **Overlay**: paints the dead strip black, above everything.
- **Mouse lock**: the cursor can't enter the strip.
- **Window push**: windows, dialogs and panels are kept out of the strip; maximized/tiled windows
  (native tiling, Fill, Raycast) are re-tiled onto the usable area, with a snap preview while dragging.
- **App menus**: the left of the menu bar sits under the strip, so ⌃⌥M (or pushing left into the
  strip along the menu bar) pops the frontmost app's menus at the cursor.
- **Fake full screen**: the green button fills the usable area; real full screen on that display is
  undone and filled instead (browsers are exempt, so video full screen keeps working).

## Build

```sh
./build.sh          # builds fixmon.app
open fixmon.app
./build.sh install  # or: install to /Applications and launch from there
```

The menu has a dead-zone width slider (the overlay follows live), Launch at login, and Restart.
The app icon is drawn by `icon/make_icon.swift`; `build.sh` regenerates `icon/AppIcon.icns` when it changes.

Needs Accessibility access (System Settings → Privacy & Security → Accessibility). Signing with a
local identity named "fixmon local signing" keeps that grant across rebuilds; otherwise it's ad-hoc.

Settings live in `defaults read dev.fixmon` (`deadWidth`, `displayMatch`, …) and the menu-bar menu.
Log: `~/Library/Logs/fixmon.log`.
