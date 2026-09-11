# MacDuo

A native Swift menu bar app for MacBook Pro. Below a 90° lid angle, it reprojects one full-screen desktop snapshot so the picture appears to remain on a fixed upright plane. Closing adds progressive frost and a fade; opening reverses the same effect.

MacDuo prepares the screenshot at 92°, eases into the effect below 90°, and uses your eye position to keep the image on an upright virtual plane. It captures one image per gesture, with no continuous video capture.

## Get started

```sh
git clone https://github.com/dakdevs/MacDuo.git
cd MacDuo
./Scripts/build.sh
open MacDuo.app
```

Requires an Apple Silicon MacBook with a compatible lid-angle sensor, macOS 14 or newer, and the Xcode Command Line Tools. Run `xcode-select --install` if the command line tools are missing. Compatibility is currently verified on an M4 Max MacBook Pro. The app is built locally and is not notarized.

## Use

1. Open `MacDuo.app`.
2. Choose **Allow Screen Recording** in its preview or menu bar menu. Enable **MacDuo** in System Settings → Privacy & Security → Screen & System Audio Recording. Relaunch if macOS requests it.
3. Use **Preview & calibration** to adjust eye distance and eye height relative to the hinge. The preview uses a sample desktop and needs no screen permission.
4. Click **Enable effect**, then slowly lower the lid below 90°. Opening to 90° removes the overlay immediately.

The laptop icon and live angle stay in the menu bar. **Control–Option–Command–L** pauses the effect. The menu also offers an eight-second desktop demo and Quit. The app has no Dock icon and does not register itself to launch at login.

Perspective strength starts at 100% for full upright-plane correction. Lower values reduce the correction, and 0% keeps the image flat while retaining frost and fade. Initial eye calibration assumes your eyes are centered, 60 cm in front of the hinge and 34 cm above it. At this viewpoint, the image stays fully lit and blurred at 45°. Adjust the calibration to your usual posture. Screen height is read from the built-in display. The illusion works for the chosen viewpoint; a flat screen cannot reproduce it from every head position or draw beyond the physical panel. At 45°, part of the virtual upright desktop extends beyond the physical screen and is cropped. The picture fades only as the panel approaches your line of sight, before the perspective can invert.

The effect changes appearance. Mouse events pass through at their original coordinates, and the cursor remains available. The effect covers the menu bar and Dock. Open the lid to 90° or press Control–Option–Command–L to pause. Use the effect while moving the lid; pause it if you want to work below 90°. Normal hardware display blanking, sleep, and lock continue to work.

## Build

Requires Apple Silicon, macOS 14 or newer, and the Xcode Command Line Tools. No Homebrew packages, Swift packages, or full Xcode installation are needed. The tested host is an M4 Max MacBook Pro running macOS 26.6.2.

```sh
./Scripts/build.sh
open MacDuo.app
```

The build creates an ad-hoc-signed local app. It is not a notarized distribution build. Rebuilding can cause macOS to request screen permission again. The Metal shader compiles at runtime using the system GPU driver.

## Verify

```sh
./Scripts/verify.sh
./MacDuo.app/Contents/MacOS/MacDuo --probe
```

The verification script runs independent ray/plane geometry checks and renders real GPU output. It checks identity at 90°, a fixed hinge, sampled perspective at 60°, image orientation and colors, identical opening and closing at the same angle, frame clearing, and the near-closed fade. It writes test PNGs and a results log to a temporary directory printed in its output. Pass a directory as its first argument to choose a location.

For development, launch a preview and optional state-only diagnostics:

```sh
open MacDuo.app --args --preview --diagnostics /tmp/macduo-state.json
```

`--demo-once` runs an eight-second screenshot effect after permission is granted. Diagnostics contain angle, screenshot state, and error messages; they contain no screen pixels.

## How it works

`LidAngleSensor.swift` reads the undocumented Apple HID lid sensor on one serial queue at 60 Hz. `DesktopSnapshot.swift` takes a single full-screen screenshot of the built-in display using SCScreenshotManager and explicitly excludes every window owned by MacDuo. `PlaneProjection.swift` maps each physical display pixel along a ray from the calibrated eye into the fixed upright plane. `PlaneRenderer.swift` samples that frozen image with the projection map and applies frost and fading in Metal. A Gaussian blur pyramid is built once per screenshot and reused while the angle changes. The graphics pipeline warms at launch, and the first screenshot frame is rendered while hidden. `EffectTransition.swift` eases geometry and frost in over 220 ms, with a 100 ms opacity handoff. `LidMotion.swift` smooths the sensor’s one-degree steps and makes a short, bounded velocity prediction. The raw measurement still controls the 90° threshold; prediction cannot delay reopening.

The app prepares one screenshot when the lid reaches 92° and keeps the overlay hidden until below 90°. It reuses that image through closing and reopening, hides it immediately at 90°, and discards it at 94°. The separate reset threshold prevents repeated screenshots when the sensor fluctuates near 90° or 92°. Holding the lid in this band also holds the same prepared image; open to 94° for a fresh gesture. Videos and changing windows are frozen during the effect. There is no continuous capture session. The screenshot stays in memory on this Mac, with no audio capture, recording file, or network code. macOS still requires the permission named Screen Recording for screenshots. Screenshot errors, invalid or stale sensor readings, sleep, lock, and display changes hide the overlay and discard the image. Generations reject late screenshot results after a stop or restart.

The first version uses SDR capture. Protected video may appear black. The lid sensor interface is undocumented, so compatibility depends on hardware and macOS. The design and tradeoffs are in `DESIGN.md`.

## References

- [Apple: ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [Apple: application-excluding content filter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:excludingapplications:exceptingwindows:))
- [LidAngleSensor: hardware sensor research](https://github.com/samhenrigold/LidAngleSensor)

## Credits and license

The visual concept was inspired by [lqSky7/iphone-duo-macos-animation](https://github.com/lqSky7/iphone-duo-macos-animation). The lid sensor work builds on the hardware research documented by [samhenrigold/LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor). MacDuo implements its own screenshot capture, projection, blur, smoothing, and application lifecycle.

MacDuo is available under the [MIT license](LICENSE).
