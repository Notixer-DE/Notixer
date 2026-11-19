#!/usr/bin/env bash
set -euo pipefail
umask 022
cd "$(dirname "$0")/.."
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
app_version="$(awk '/^version:/ {sub(/[+].*/, "", $2); print $2}' pubspec.yaml)"
app_version="${NOTER_DEB_VERSION:-$app_version}"
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+ci\.[0-9]+)?$ ]]; then
  echo "Invalid package version: $app_version" >&2
  exit 1
fi
# A preceding Android debug bundle can leave VM snapshots in the shared asset
# directory. These do not belong in a Linux AOT release.
for asset in kernel_blob.bin vm_snapshot_data isolate_snapshot_data; do
  rm -f "build/flutter_assets/$asset" "build/linux/x64/release/bundle/data/flutter_assets/$asset"
done
flutter_args=(build linux --release --no-pub)
if [[ -n "${NOTER_BUILD_NUMBER:-}" ]]; then
  [[ "$NOTER_BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "Invalid build number" >&2; exit 1; }
  flutter_args+=(--build-number "$NOTER_BUILD_NUMBER")
fi
"$FLUTTER_BIN" "${flutter_args[@]}"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
chmod 0755 "$stage"
bundle="build/linux/x64/release/bundle"
test -x "$bundle/notixer"
mkdir -p "$stage/DEBIAN" "$stage/opt/notixer" "$stage/usr/bin" "$stage/usr/share/applications" "$stage/usr/share/icons/hicolor/scalable/apps"
cp -a "$bundle/notixer" "$bundle/data" "$bundle/lib" "$stage/opt/notixer/"
ln -s /opt/notixer/notixer "$stage/usr/bin/notixer"
install -m 0644 packaging/notixer.desktop "$stage/usr/share/applications/de.noter.noter.desktop"
install -m 0644 packaging/notixer.svg "$stage/usr/share/icons/hicolor/scalable/apps/notixer.svg"
cat > "$stage/DEBIAN/control" <<CONTROL
Package: notixer
Version: ${app_version}
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Notixer contributors
Depends: libgtk-3-0t64, libsecret-1-0, libstdc++6, libc6, libblkid1, liblzma5
Conflicts: noter
Replaces: noter
Provides: noter
Description: Notixer offline notes with handwriting and PDF annotations
 A local Flutter notebook for Debian.
CONTROL
mkdir -p dist
dpkg-deb --root-owner-group --build "$stage" "dist/notixer_${app_version}_amd64.deb"
