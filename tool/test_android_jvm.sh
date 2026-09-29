#!/usr/bin/env bash
# Runs the Android JVM (Robolectric/Mockito) unit tests of
# packages/camera_android_camerax.
#
# The package ships without an example app or Gradle wrapper, and its
# build.gradle.kts reads `flutter.compileSdkVersion`, so it can only be built
# inside a Flutter host app. This script creates a throwaway host app with a
# path dependency on the package and runs the package's unit test task there.
#
# Usage:
#   tool/test_android_jvm.sh [extra gradle args...]
#
# Environment:
#   ANDROID_JVM_HOST_DIR  Reuse (and keep) this directory as the host app
#                         instead of a temporary one. Speeds up repeated runs.
#   JAVA_HOME             JDK used by Gradle. JDK 17 or newer is required.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_dir="$root/packages/camera_android_camerax"
package_name="camera_android_camerax"

if [[ ! -f "$package_dir/pubspec.yaml" ]]; then
  echo "error: $package_dir is not a Flutter package." >&2
  exit 1
fi

java_bin="java"
if [[ -n "${JAVA_HOME:-}" ]]; then
  java_bin="$JAVA_HOME/bin/java"
fi
# `java -version` fails (and would abort the script under `set -e`) when java
# is missing or JAVA_HOME is invalid, so tolerate the failure and report it.
java_version="$("$java_bin" -version 2>&1 | awk -F'"' '/version/ {split($2, v, "."); print (v[1] == "1") ? v[2] : v[1]; exit}')" || true
# Keep only the leading digits so early-access builds such as `25-ea` parse.
java_major="${java_version%%[!0-9]*}"
if [[ -z "$java_major" ]]; then
  echo "error: JDK 17 or newer is required, but no usable java was found at '$java_bin'. Set JAVA_HOME." >&2
  exit 1
fi
if (( java_major < 17 )); then
  echo "error: JDK 17 or newer is required (found '$java_version' at '$java_bin'). Set JAVA_HOME." >&2
  exit 1
fi

host_dir="${ANDROID_JVM_HOST_DIR:-}"
cleanup_host=false
if [[ -z "$host_dir" ]]; then
  host_dir="$(mktemp -d "${TMPDIR:-/tmp}/camerax_jvm_host.XXXXXX")"
  cleanup_host=true
fi
cleanup() {
  if [[ "$cleanup_host" == true ]]; then
    rm -rf "$host_dir"
  fi
}
trap cleanup EXIT

if [[ ! -f "$host_dir/pubspec.yaml" ]]; then
  echo "==> Creating throwaway Flutter host app in $host_dir"
  flutter create \
    --platforms=android \
    --project-name camerax_jvm_host \
    --org io.flutter.plugins \
    --no-pub \
    "$host_dir" >/dev/null
fi

# A reused host dir can exist without the dependency, for example when a
# previous `flutter pub add` failed, so check the pubspec rather than the dir.
if ! grep -Eq "^[[:space:]]+$package_name:" "$host_dir/pubspec.yaml"; then
  echo "==> Adding $package_name path dependency to the host app"
  (
    cd "$host_dir"
    flutter pub add "$package_name:{\"path\":\"$package_dir\"}" >/dev/null
  )
fi

echo "==> Resolving host app dependencies"
(cd "$host_dir" && flutter pub get >/dev/null)

echo "==> Running $package_name JVM unit tests (JDK $java_major)"
(
  cd "$host_dir/android"
  ./gradlew --no-daemon ":$package_name:testDebugUnitTest" "$@"
)
