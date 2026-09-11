# Verification

Run on a compatible Apple Silicon MacBook in a graphical macOS session:

```sh
./Scripts/build.sh
./Scripts/verify.sh
```

Pass an output directory to `verify.sh` to keep its generated previews and results in a chosen location. The test images use a synthetic desktop, not screen captures. Generated files and app bundles should stay out of Git.

## Automated checks

The suite verifies:

- Independent forward ray/plane targets, the identity projection at 90°, a fixed hinge, and clipping.
- GPU color, orientation, full and reduced perspective, frame clearing, and closing fade.
- The 45° mapping at an eye distance of 60 cm and height of 34 cm, strong Gaussian blur, and progressive upper-image darkening.
- Soft projected edges, a retreating top boundary, and an unchanged interior projection and hinge.
- Hidden-window preparation of the first drawable, cancellation, and invalidation when a screenshot is replaced or cleared.
- Sensor smoothing and bounded prediction through quantized motion, reversals, stops, and stale readings.
- Immediate geometry tracking through late capture and fast closing, eased opacity, and reentry after hiding.
- The real HID sensor, app signature, and Info.plist.

Focused mutations that disable blur, smoothing, prediction, or entry easing fail the corresponding checks.

## Desktop integration

Use the menu's eight-second demo after granting screenshot permission. Check that preparation starts near 92°, the effect appears below 90°, reopening restores the desktop, and the completed gesture releases its screenshot. The app should use one screenshot per gesture.

For state-only diagnostics:

```sh
open MacDuo.app --args --demo-once --diagnostics /tmp/macduo-state.json
```

Diagnostics include angles, preparation time, entry samples, and screenshot lifecycle state. They contain no screen pixels. Do not commit local diagnostics.

The implementation was exercised on an M4 Max MacBook Pro with macOS 26.6.2. The desktop demo prepared its screenshot in 111 ms, used one capture through closing and reopening, and completed with the overlay hidden and the image released. The renamed app also passes the full automated suite and hardware probe.

Physical dispatch of the global pause shortcut has not been conclusively exercised by targeted UI automation. Registration succeeds; opening the lid to 90° provides an independent way to remove the effect. The perceived projection also depends on eye position, so inspect the result from the calibrated viewpoint.
