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
./build.sh dmg      # or: package dist/fixmon-<version>.dmg to hand to someone
```

The menu has a dead-zone width slider (the overlay follows live), a display picker (remembered by
hardware ID; if that display is unplugged nothing is fenced), per-app exclusions, Launch at login, and Restart.

### Installing the DMG on another Mac

fixmon isn't notarized (no paid Apple developer account), so Gatekeeper blocks the first launch.
Drag fixmon to Applications, open it once, then System Settings → Privacy & Security → "Open Anyway".
Or from a terminal: `xattr -dr com.apple.quarantine /Applications/fixmon.app`.
Then grant Accessibility when asked.

### Updates

fixmon checks GitHub releases once a day (and via "Check for Updates…" in the menu). An update is
only installed if it's signed by the same identity as the running copy, so the Accessibility grant
carries over and no Gatekeeper prompt appears. Releasing is just pushing a tag: `git tag v1.5 && git push origin v1.5`.

The app icon is drawn by `icon/make_icon.swift`; `build.sh` regenerates `icon/AppIcon.icns` when it changes.

Needs Accessibility access (System Settings → Privacy & Security → Accessibility). Signing with a
local identity named "fixmon local signing" keeps that grant across rebuilds; otherwise it's ad-hoc.

Settings live in `defaults read dev.fixmon` (`deadWidth`, `displayMatch`, …) and the menu-bar menu.
Log: `~/Library/Logs/fixmon.log`.
