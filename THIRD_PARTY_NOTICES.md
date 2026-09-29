# Third-party notices

This repository contains modified source forks. Preserve each package's full
license file and upstream attribution when redistributing or updating it.

| Package | Version | Provenance at import | License |
| --- | --- | --- | --- |
| `camera_android_camerax` | `0.7.4+3` | Flutter packages, `packages/camera/camera_android_camerax`; imported from the Teleprompter PR #24 fork snapshot at `a2606eccf106cdb3b39f246cec9ddbc71cf8920d` | BSD 3-Clause, [LICENSE](packages/camera_android_camerax/LICENSE) |
| `camera_avfoundation` | `0.10.2` | Flutter packages, `packages/camera/camera_avfoundation`; imported from the Teleprompter PR #24 fork snapshot at `a2606eccf106cdb3b39f246cec9ddbc71cf8920d` | BSD 3-Clause, [LICENSE](packages/camera_avfoundation/LICENSE) |
| `camera_desktop` | `1.2.1` | [hugocornellier/camera_desktop](https://github.com/hugocornellier/camera_desktop); imported from the Teleprompter PR #24 fork snapshot at `a2606eccf106cdb3b39f246cec9ddbc71cf8920d` | MIT, [LICENSE](packages/camera_desktop/LICENSE) |

## Upstream baselines

The fork snapshot was taken from these upstream releases. Unmodified imported
files are byte-identical to the listed upstream commit.

| Package | Upstream release | Upstream commit |
| --- | --- | --- |
| `camera_android_camerax` | [`camera_android_camerax-v0.7.4+3`](https://github.com/flutter/packages/tree/camera_android_camerax-v0.7.4%2B3/packages/camera/camera_android_camerax) | [`43dcfe52e9571de54966fccac3ffcdc6503bd312`](https://github.com/flutter/packages/commit/43dcfe52e9571de54966fccac3ffcdc6503bd312) |
| `camera_avfoundation` | [`camera_avfoundation-v0.10.2`](https://github.com/flutter/packages/tree/camera_avfoundation-v0.10.2/packages/camera/camera_avfoundation) | [`e0dc2c45f568b66f8165f9c7a1c137efd372cf5b`](https://github.com/flutter/packages/commit/e0dc2c45f568b66f8165f9c7a1c137efd372cf5b) |
| `camera_desktop` | 1.2.1 (upstream publishes no Git tags) | [`9d98e1b373cc60b0125773ab40b1ad46e4983ee1`](https://github.com/hugocornellier/camera_desktop/commit/9d98e1b373cc60b0125773ab40b1ad46e4983ee1), the commit that set version 1.2.1 |

For `camera_desktop`, the upstream commits after `9d98e1b` and before 1.2.2
(`efca556`, `f4b7b0c`) change only the example app and documentation, so the
imported package sources match all three; `9d98e1b` is recorded as the 1.2.1
release commit.

`camera_recording` is the repository-owned shared API. Its provenance and
license are recorded in its package directory.

The Android and iOS forks retain the Flutter Authors copyright and BSD
3-Clause license text. The desktop fork retains the Hugo Cornellier MIT notice.
Local changes do not replace those notices.

The baseline is a [Teleprompter PR #24 fork snapshot](https://github.com/imariman/teleprompter/pull/24), not an upstream Flutter commit. The repository-level
[MIT license](LICENSE) governs Camera Recording Kit contributors' additions;
the original package licenses govern their respective forked files and take
precedence where they apply.
