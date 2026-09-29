#!/usr/bin/env python3
"""Run camera_avfoundation native unit tests on an iOS simulator.

Usage: python3 tool/test_ios_camera_native.py
Requires macOS, full Xcode with an iOS simulator runtime, and the Flutter iOS engine
artifacts (`flutter precache --ios`). The tests cover device-free logic (format
selection, capability building, metering and orientation decisions) with fake
formats; they do not use a camera. A shut-down simulator is booted for the run
and shut down again afterwards.
"""

import json
import os
import platform
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


def output(*command):
    return subprocess.check_output(command, text=True).strip()


def run(*arguments, env=None):
    subprocess.run(arguments, check=True, env=env)


def flutter_simulator_framework_dir():
    flutter = shutil.which("flutter")
    if flutter is None:
        raise SystemExit("flutter is not on PATH.")
    root = Path(os.path.realpath(flutter)).parents[1]
    xcframework = root / "bin/cache/artifacts/engine/ios/Flutter.xcframework"
    for slice_dir in sorted(xcframework.glob("ios-*-simulator")):
        if (slice_dir / "Flutter.framework").exists():
            return slice_dir
    raise SystemExit(f"No simulator Flutter.framework in {xcframework}; run `flutter precache --ios`.")


def pick_simulator():
    devices = json.loads(output("xcrun", "simctl", "list", "devices", "available", "--json"))
    iphones = [
        device
        for runtime, entries in devices["devices"].items()
        if "iOS" in runtime
        for device in entries
        if device["name"].startswith("iPhone")
    ]
    if not iphones:
        raise SystemExit("No available iPhone simulator.")
    booted = [device for device in iphones if device["state"] == "Booted"]
    return (booted or iphones)[0]


def main():
    if platform.system() != "Darwin":
        raise SystemExit("iOS native camera tests require macOS and Xcode.")
    root = Path(__file__).resolve().parents[1]
    package = root / "packages/camera_avfoundation/ios/camera_avfoundation"
    sources = sorted((package / "Sources/camera_avfoundation").glob("*.swift"))
    tests = sorted((package / "Tests/camera_avfoundationTests").glob("*.swift"))
    developer = Path(output("xcode-select", "-p"))
    platform_developer = developer / "Platforms/iPhoneSimulator.platform/Developer"
    frameworks = str(platform_developer / "Library/Frameworks")
    libraries = str(platform_developer / "usr/lib")
    sdk = output("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
    flutter = str(flutter_simulator_framework_dir())
    environment = dict(os.environ, SDKROOT=sdk)

    with tempfile.TemporaryDirectory(prefix="teleprompter-ios-camera-tests-") as temporary:
        directory = Path(temporary)
        base = [
            "xcrun", "swiftc", "-sdk", sdk,
            "-target", f"{platform.machine()}-apple-ios17.0-simulator",
            "-module-cache-path", str(directory / "module-cache"),
        ]
        run(*base, "-emit-library", "-emit-module", "-enable-testing",
            "-module-name", "camera_avfoundation", "-emit-module-path",
            str(directory / "camera_avfoundation.swiftmodule"),
            "-F", flutter, "-framework", "Flutter",
            "-Xlinker", "-install_name", "-Xlinker", "@rpath/libcamera_avfoundation.dylib",
            "-o", str(directory / "libcamera_avfoundation.dylib"),
            *[str(path) for path in sources], env=environment)
        bundle = directory / "CameraTests.xctest"
        bundle.mkdir()
        (bundle / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "CameraTests",
            "CFBundleIdentifier": "dev.teleprompter.camera-ios-tests",
            "CFBundlePackageType": "BNDL",
        }))
        run(*base, "-emit-library", "-module-name", "camera_avfoundationTests",
            "-F", frameworks, "-framework", "XCTest", "-I", libraries, "-L", libraries,
            "-I", temporary, "-L", temporary, "-lcamera_avfoundation", "-F", flutter,
            *[str(path) for path in tests],
            "-o", str(bundle / "CameraTests"), env=environment)

        simulator = pick_simulator()
        udid = simulator["udid"]
        booted_here = simulator["state"] != "Booted"
        if booted_here:
            run("xcrun", "simctl", "boot", udid)
        try:
            run("xcrun", "simctl", "bootstatus", udid, "-b")
            test_environment = dict(
                environment,
                SIMCTL_CHILD_DYLD_FRAMEWORK_PATH=f"{frameworks}:{flutter}",
                SIMCTL_CHILD_DYLD_LIBRARY_PATH=f"{libraries}:{temporary}",
            )
            run("xcrun", "simctl", "spawn", udid,
                str(platform_developer / "Library/Xcode/Agents/xctest"), str(bundle),
                env=test_environment)
        finally:
            if booted_here:
                subprocess.run(["xcrun", "simctl", "shutdown", udid], check=False)


if __name__ == "__main__":
    main()
