#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${FLUTTER_BIN:-}" ]]; then
  if [[ -x .tooling/flutter/bin/flutter ]]; then
    FLUTTER_BIN="$PWD/.tooling/flutter/bin/flutter"
  else
    FLUTTER_BIN=flutter
  fi
fi
if [[ -z "${GRADLE_USER_HOME:-}" && -d .tooling/gradle ]]; then
  export GRADLE_USER_HOME="$PWD/.tooling/gradle"
fi
# The existing locally installed preview was signed with this XDG key. Preserve
# it when available; otherwise retain Gradle's standard Android debug key.
if [[ -z "${NOTER_DEBUG_KEYSTORE:-}" && -f "${XDG_CONFIG_HOME:-$HOME/.config}/.android/debug.keystore" ]]; then
  export NOTER_DEBUG_KEYSTORE="${XDG_CONFIG_HOME:-$HOME/.config}/.android/debug.keystore"
fi
export FLUTTER_SUPPRESS_ANALYTICS=true
"$FLUTTER_BIN" pub get --enforce-lockfile
"$FLUTTER_BIN" build apk --release --no-pub
app_version="$(awk '/^version:/ {sub(/[+].*/, "", $2); print $2}' pubspec.yaml)"
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid package version: $app_version" >&2
  exit 1
fi
mkdir -p dist
artifact="dist/notixer_${app_version}_preview.apk"
cp build/app/outputs/flutter-apk/app-release.apk "$artifact"
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" && -f android/local.properties ]]; then
  sdk_root="$(sed -n 's/^sdk.dir=//p' android/local.properties | head -n 1)"
fi
if [[ -x "$sdk_root/build-tools/36.0.0/apksigner" ]]; then
  "$sdk_root/build-tools/36.0.0/apksigner" verify --print-certs "$artifact"
fi
sha256sum "$artifact"
echo "Android-Preview created: $artifact"
