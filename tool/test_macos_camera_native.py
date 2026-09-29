#!/usr/bin/env python3
"""Run camera_desktop native behavioral tests without a Flutter app or camera.

Usage: python3 tool/test_macos_camera_native.py
Requires macOS and full Xcode. Synthetic samples exercise the actual media writer,
Vision registration and Core Image renderer; physical-camera QA is separate.
"""

import platform
import plistlib
import subprocess
import tempfile
from pathlib import Path


def output(*command):
    return subprocess.check_output(command, text=True).strip()


def run(*arguments):
    subprocess.run(arguments, check=True)


def main():
    if platform.system() != "Darwin":
        raise SystemExit("Native camera tests require macOS and Xcode.")
    root = Path(__file__).resolve().parents[1]
    package = root / "packages/camera_desktop/macos/camera_desktop"
    sources = package / "Sources/camera_desktop"
    developer = Path(output("xcode-select", "-p"))
    platform_developer = developer / "Platforms/MacOSX.platform/Developer"
    frameworks = str(platform_developer / "Library/Frameworks")
    libraries = str(platform_developer / "usr/lib")
    sdk = output("xcrun", "--sdk", "macosx", "--show-sdk-path")

    with tempfile.TemporaryDirectory(prefix="teleprompter-camera-tests-") as temporary:
        directory = Path(temporary)
        base = [
            "xcrun", "swiftc", "-sdk", sdk,
            "-target", f"{platform.machine()}-apple-macos11.0",
            "-module-cache-path", str(directory / "module-cache"),
        ]
        run(*base, "-emit-library", "-emit-module", "-enable-testing",
            "-module-name", "camera_desktop", "-emit-module-path",
            str(directory / "camera_desktop.swiftmodule"),
            "-o", str(directory / "libcamera_desktop.dylib"),
            *[str(sources / name) for name in [
                "RecordingQuality.swift", "DeviceEnumerator.swift",
                "AVCaptureDevice+Extension.swift", "RecordHandler.swift",
                "UnfairLock.swift", "RecordingTimeline.swift",
                "MacOSVideoStabilizer.swift", "PixelBufferCopy.swift",
                "PhotoHandler.swift",
            ]])
        bundle = directory / "CameraTests.xctest"
        executable = bundle / "Contents/MacOS/CameraTests"
        executable.parent.mkdir(parents=True)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "CameraTests",
            "CFBundleIdentifier": "dev.teleprompter.camera-tests",
            "CFBundlePackageType": "BNDL",
        }))
        run(*base, "-emit-library", "-module-name", "CameraTests",
            "-F", frameworks, "-framework", "XCTest", "-I", libraries,
            "-L", libraries, "-I", temporary, "-L", temporary, "-lcamera_desktop",
            "-Xlinker", "-rpath", "-Xlinker", libraries,
            "-Xlinker", "-rpath", "-Xlinker", frameworks,
            "-Xlinker", "-rpath", "-Xlinker", temporary,
            *[str(path) for path in sorted((package / "Tests/camera_desktopTests").glob("*.swift"))],
            "-o", str(executable))
        run("xcrun", "xctest", str(bundle))


if __name__ == "__main__":
    main()
