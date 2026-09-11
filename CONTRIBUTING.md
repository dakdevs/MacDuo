# Contributing

Build with `./Scripts/build.sh` and run `./Scripts/verify.sh` on a compatible Apple Silicon MacBook. The verification suite exercises Metal rendering and the physical lid-angle sensor, so it requires local hardware and a graphical macOS session.

For visual changes, inspect the preview and the eight-second desktop demo. Check closing and reopening, the handoff at 90°, and cleanup after pausing. The preview uses a generated desktop and needs no screenshot permission.

Bug reports should include the Mac model, macOS version, and reproduction steps. For geometry issues, include your approximate eye distance and height relative to the hinge. Share generated preview images when possible; avoid including private desktop content or local diagnostic files.

Keep contributions focused and include relevant verification results. Contributions are licensed under this repository's MIT license.
