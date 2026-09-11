# Acknowledgments

MacDuo's lid sensor access is informed by Sam Henri Gold's [LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor) research into Apple's undocumented HID lid-angle sensor, including the device identifiers and feature-report layout. That upstream project is licensed under [Apache License 2.0](https://github.com/samhenrigold/LidAngleSensor/blob/main/LICENSE).

The visual concept was inspired by [lqSky7/iphone-duo-macos-animation](https://github.com/lqSky7/iphone-duo-macos-animation).

MacDuo independently implements its sensor polling, screenshot capture, projection, blur, smoothing, and application lifecycle. It does not bundle source code, audio, or other assets from either project. MacDuo's own code is licensed under the MIT license in `LICENSE`.
