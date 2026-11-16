#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
app_version="$(awk '/^version:/ {sub(/[+].*/, "", $2); print $2}' pubspec.yaml)"
app_version="${NOTER_DEB_VERSION:-$app_version}"
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+ci\.[0-9]+)?$ ]]; then
  echo "Ungültige Paketversion: $app_version" >&2
  exit 1
fi
# A preceding Android debug bundle can leave VM snapshots in the shared asset
# directory. These do not belong in a Linux AOT release.
for asset in kernel_blob.bin vm_snapshot_data isolate_snapshot_data; do
  rm -f "build/flutter_assets/$asset" "build/linux/x64/release/bundle/data/flutter_assets/$asset"
done
flutter_args=(build linux --release --no-pub)
if [[ -n "${NOTER_BUILD_NUMBER:-}" ]]; then
  [[ "$NOTER_BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "Ungültige Buildnummer" >&2; exit 1; }
  flutter_args+=(--build-number "$NOTER_BUILD_NUMBER")
fi
"$FLUTTER_BIN" "${flutter_args[@]}"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/DEBIAN" "$stage/opt/noter" "$stage/usr/bin" "$stage/usr/share/applications" "$stage/usr/share/icons/hicolor/scalable/apps"
cp -a build/linux/x64/release/bundle/. "$stage/opt/noter/"
ln -s /opt/noter/noter "$stage/usr/bin/noter"
cp packaging/noter.desktop "$stage/usr/share/applications/de.noter.noter.desktop"
cp packaging/noter.svg "$stage/usr/share/icons/hicolor/scalable/apps/"
cat > "$stage/DEBIAN/control" <<CONTROL
Package: noter
Version: ${app_version}
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Notixer contributors
Depends: libgtk-3-0t64, libsecret-1-0, libstdc++6, libc6, libblkid1, liblzma5
Description: Offline notes with handwriting and PDF annotations
 A local Flutter notebook for Debian and Android.
CONTROL
mkdir -p dist
dpkg-deb --root-owner-group --build "$stage" "dist/noter_${app_version}_amd64.deb"
