# Verification

Run on a compatible Apple Silicon MacBook in a graphical macOS session:

```sh
./Scripts/build.sh
./Scripts/verify.sh
```

Pass an output directory to `verify.sh` to keep its generated previews and results in a chosen location. The test images use a synthetic desktop, not screen captures. Generated files and app bundles should stay out of Git.

## Automated checks

The suite verifies:

- Independent forward ray/plane targets, gentler initial stretch, the identity projection at 90°, a fixed hinge, and clipping.
- GPU color, orientation, full and reduced perspective, frame clearing, and closing fade.
- Centered straight-on defaults at different physical screen sizes, the 45° eye-ray mapping, custom elevated viewpoints, and progressive upper-image darkening.
- Soft projected edges, a retreating top boundary, a fixed hinge, and a vertical frost gradient that preserves lower detail while strongly blurring the top.
- Hidden-window preparation of the first drawable, cancellation, and invalidation when a screenshot is replaced or cleared.
- Continuous angle tweening between cached 100 ms sensor reports, including fractional display frames, steady slow movement, report-arrival continuity, reversals, stops, noise, and stale readings.
- Immediate geometry tracking through late capture and fast closing, eased opacity, and reentry after hiding.
- The real HID sensor, app signature, and Info.plist.

Focused mutations that disable blur, smoothing, prediction, or entry easing fail the corresponding checks. The held-report continuity check also fails against the previous motion estimator because a new sensor reading jumps the rendered angle.

## Desktop integration

Use the menu's eight-second demo after granting screenshot permission. Check that preparation starts near 92°, the effect appears below 90°, reopening restores the desktop, and the completed gesture releases its screenshot. The app should use one screenshot per gesture.

For state-only diagnostics:

```sh
open MacDuo.app --args --demo-once --diagnostics /tmp/macduo-state.json
```

Diagnostics include angles, preparation time, entry samples, screenshot lifecycle state, and frame pacing. The `framePacing` object reports display-link cadence, actual drawable presentation cadence, median and 95th-percentile frame intervals, and GPU time for up to 1,200 frames per visible run. Presentation timing is enabled only during diagnostics. A 120 fps run should have frame intervals near 8.33 ms. The display clock follows the active screen refresh rate; macOS may choose a lower rate based on display and power settings. They contain no screen pixels. Do not commit local diagnostics.

On an M4 Max MacBook Pro with macOS 26.6.2, a six-second native rendering probe at 4112×2658 presented 118.96 frames per second after warmup. Median and 95th-percentile presentation intervals were both 8.33 ms; GPU time was 1.97 ms at the 95th percentile. The production display clock separately measured 120 Hz, coalesced a 120 ms main-thread stall into one fresh update, rejected queued callbacks after invalidation, and restarted successfully. The app also passes the full projection, blur, motion, entry, signature, and hardware checks. The gentler-entry checks fail against the previous projection. The vertical-gradient checks also fail against the previous blur treatment: the lower desktop must retain its detail while the upper image diffuses.

A separate full-resolution tweening probe feeds whole-degree readings held for 100 ms into the production motion estimator, polls at 60 Hz, and tags each actual presented drawable with its rendered angle. On the same Mac with the centered viewpoint, the tweening version presented 116.52 fps. All 417 measured frame pairs with unchanged sensor readings advanced through intermediate angles, with no backward steps during steady closing or opening. The 15°/second trajectory had 0.368° RMS tracking error; the median frame step was 0.1246°. Focused checks also cover 30°/second and 60°/second motion, presentation lead, report timing jitter, noise, reversals, and stops. The extrapolation term is capped at 8°; the full correction curve and sensor delay can produce greater error after an unseen physical stop. Response tests cover acceleration, natural slowing, and stops at different phases within the device update interval.

With a keyboard-level viewpoint, the updated response curve and two-drawable Metal layer presented 64.78 fps. All 219 measured frame pairs with unchanged sensor readings advanced through intermediate angles, with no backward steps during steady closing or opening. After the simulated 15°/second motion stopped, the displayed angle settled within 0.1° in 229 ms when closing and 237 ms when opening. The previous low-viewpoint run took 246 ms and 321 ms respectively. These times include the sensor update interval and presentation delay; the estimator cannot observe a physical stop before the device reports it.

Reducing the Metal layer from three drawables to two lowered median and 95th-percentile display-target-to-presentation delay from 50 ms to 33.33 ms while preserving synchronization. Setting an explicit MTKView preference of 120 fps did not improve the keyboard-level run. The app targets 120 Hz; these measurements do not establish a guaranteed 120 fps desktop effect.

Physical dispatch of the global pause shortcut has not been conclusively exercised by targeted UI automation. Registration succeeds; opening the lid to 90° provides an independent way to remove the effect. The perceived projection also depends on eye position, so inspect the result from the calibrated viewpoint.
