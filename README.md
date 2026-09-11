# MacBook-Duo

A tiny menu bar app that fakes the iPhone Duo fold-blur effect on a MacBook. As you close the lid, the screen blurs and darkens at the edges to match how far it's folded, like the fold animation on a book-style phone.

It reads the lid angle straight from the hinge sensor over IOKit HID and drives it into the same private blur API macOS itself uses for stuff like Mission Control and Notification Center. There's also a rough keystone correction that adds trapezoidal black bars at the top edge, so the visible content looks like it's still sitting flat even as the lid folds down.

## Why this exists

Just a for-fun hack, built by poking at private SkyLight/CoreGraphics symbols and the lid angle sensor. It's not an official API and Apple could break it in any OS update.

## Requirements

- Apple Silicon MacBook with a lid angle sensor (basically anything recent enough to report hinge angle over HID)
- macOS with the private `SLS`/`CGS` blur symbols still present (varies by OS version, no guarantees)

## Build

```bash
swiftc -O LidBlur.swift -o LidBlur
```

## Run

```bash
./LidBlur | tee lidblur.log
```

It runs as a menu bar item (no Dock icon). Click the laptop icon in the menu bar to:

- turn the blur on/off
- toggle whether it applies on the lock screen
- pick the lock-screen space level (if the default doesn't work on your machine)
- turn on a red debug tint to visually confirm the blur window is actually active
- toggle the trapezoidal black bars and tune viewing distance / exaggeration
- switch between transition modes (blur radius vs. opacity)
- calibrate what angle counts as "fully clear" and "fully blurred" based on your current lid position
- re-detect the sensor if it stops responding

## How it works, roughly

1. `LidAngleSensor` polls the internal HID hinge-angle sensor.
2. `AngleMapper` smooths that angle and turns it into a 0–1 blur intensity with an easing curve.
3. `BlurOverlay` creates a borderless, click-through, fullscreen window on the built-in display and applies the private background-blur API to it, with the radius/opacity driven by that intensity.
4. `LockScreenSpace` creates a Space above the lock screen level and moves the overlay windows into it, so the effect still shows when the screen is locked.
5. `MaskOverlay` draws the trapezoidal black bars on a separate, higher window based on `KeystoneModel`'s projection math.
6. A failsafe forces everything back to fully clear if the sensor stops reporting or if the lock screen has been showing too long after wake, so you're never stuck staring through a permanently blurred screen.

## Known rough edges

- Relies entirely on private, undocumented Apple APIs (found via community reverse engineering) — expect it to break on some future macOS release.
- Built-in display only.
- Debug log via `print` — pipe to a file if you want to keep it (see the run command above).

## License

MIT — see [LICENSE](LICENSE).
