#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
use_mobile_slot=false
if [[ "${GITHUB_ACTIONS:-}" != "true" ]] && command -v mobile-slot >/dev/null 2>&1; then
  use_mobile_slot=true
  slot_status=0
  mobile-slot status || slot_status=$?
  if [[ "$slot_status" -ne 0 && "$slot_status" -ne 75 ]]; then
    exit "$slot_status"
  fi
fi

run_test() {
  if [[ "$use_mobile_slot" == true ]]; then
    mobile-slot test -- flutter test --concurrency=1 "$@"
  else
    flutter test --concurrency=1 "$@"
  fi
}

run_native_test() {
  if [[ "$use_mobile_slot" == true ]]; then
    mobile-slot run -- python3 tool/test_macos_camera_native.py
  else
    python3 tool/test_macos_camera_native.py
  fi
}

for package in "$root"/packages/*; do
  [[ -f "$package/pubspec.yaml" ]] || continue
  printf '\n==> %s\n' "${package#$root/}"
  (
    cd "$package"
    flutter pub get
    flutter analyze
    run_test
  )
done

# The native XCTest suite links XCTest from the macOS platform of a full Xcode
# install; Command Line Tools alone cannot build it.
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '\nSkipping macOS native tests on %s.\n' "$(uname -s)"
elif developer_dir="$(xcode-select -p 2>/dev/null)" &&
  [[ -d "$developer_dir/Platforms/MacOSX.platform" ]]; then
  run_native_test
else
  printf '\nSkipping macOS native tests: they require full Xcode selected with xcode-select.\n'
fi
