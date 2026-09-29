#!/usr/bin/env python3
"""Run camera_desktop native behavioral tests without a Flutter app or camera.

Usage: python3 tool/test_macos_camera_native.py
Requires macOS and full Xcode. Synthetic samples exercise the actual media writer,
Vision registration and Core Image renderer; physical-camera QA is separate.
"""

import platform
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path


def output(*command):
    return subprocess.check_output(command, text=True).strip()


def run(*arguments):
    subprocess.run(arguments, check=True)


DECLARATION = re.compile(
    r"^\s*(?:(?:public|internal|private|fileprivate|open|final|@objc(?:\([^)]*\))?)\s+)*"
    r"(?:class|struct|enum|protocol|actor|typealias)\s+([A-Za-z_]\w*)",
    re.MULTILINE,
)


def flutter_independent_sources(sources):
    """Return the production sources that build without the Flutter engine.

    Files importing FlutterMacOS are excluded, then (to a fixpoint) every file
    that references a type declared in an excluded file. New production files
    are covered automatically instead of relying on a hand-maintained list.
    """
    texts = {path: path.read_text(encoding="utf-8") for path in sources.glob("*.swift")}
    excluded = {path for path, text in texts.items() if "import FlutterMacOS" in text}
    while True:
        names = {name for path in excluded for name in DECLARATION.findall(texts[path])}
        dependent = {
            path for path, text in texts.items()
            if path not in excluded
            and any(re.search(rf"\b{re.escape(name)}\b", text) for name in names)
        }
        if not dependent:
            return sorted(path for path in texts if path not in excluded)
        excluded |= dependent


def main():
    if platform.system() != "Darwin":
        raise SystemExit("Native camera tests require macOS and full Xcode.")
    root = Path(__file__).resolve().parents[1]
    package = root / "packages/camera_desktop/macos/camera_desktop"
    sources = package / "Sources/camera_desktop"
    developer = Path(output("xcode-select", "-p"))
    platform_developer = developer / "Platforms/MacOSX.platform/Developer"
    if not platform_developer.is_dir():
        raise SystemExit(
            f"Native camera tests require full Xcode; {developer} has no macOS "
            "platform (Command Line Tools cannot link XCTest). Select Xcode "
            "with xcode-select.")
    frameworks = str(platform_developer / "Library/Frameworks")
    libraries = str(platform_developer / "usr/lib")
    sdk = output("xcrun", "--sdk", "macosx", "--show-sdk-path")

    compiled = flutter_independent_sources(sources)
    if not compiled:
        raise SystemExit(f"No Flutter-independent Swift sources found in {sources}.")

    with tempfile.TemporaryDirectory(prefix="camera-recording-kit-camera-tests-") as temporary:
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
            *[str(path) for path in compiled])
        bundle = directory / "CameraTests.xctest"
        executable = bundle / "Contents/MacOS/CameraTests"
        executable.parent.mkdir(parents=True)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "CameraTests",
            "CFBundleIdentifier": "dev.camera-recording-kit.camera-tests",
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
