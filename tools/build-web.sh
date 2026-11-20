#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

version="${NOTER_WEB_VERSION:-$(awk '/^version:/ {sub(/[+].*/, "", $2); print $2}' pubspec.yaml)}"
build="${NOTER_BUILD_NUMBER:-1}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]]

flutter build web --release --no-pub --target lib/main_web.dart \
  --no-web-resources-cdn --pwa-strategy none \
  --build-name "$version" --build-number "$build"

for file in index.html flutter_bootstrap.js notixer-sw.js register-sw.js main.dart.js version.json; do
  test -s "build/web/$file"
done
# Use content identity so a new build has its own complete offline cache.
python3 - build/web <<'PYTHON'
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
excluded = {"notixer-precache.js", "flutter_service_worker.js"}
files = [
    path for path in sorted(root.rglob("*"))
    if path.is_file() and path.name not in excluded and path.suffix != ".symbols"
]
digest = hashlib.sha256()
for path in files:
    digest.update(path.relative_to(root).as_posix().encode())
    digest.update(hashlib.sha256(path.read_bytes()).digest())
manifest = {
    "version": digest.hexdigest(),
    "files": [path.relative_to(root).as_posix() for path in files],
}
(root / "notixer-precache.js").write_text(
    "self.precache = " + json.dumps(manifest, separators=(",", ":")) + ";\n",
    encoding="utf-8",
)
PYTHON
mkdir -p dist
package="notixer_${version}_build-${build}_web.zip"
output="../../dist/$package"
(
  cd build/web
  # Write a new archive so removed asset paths cannot survive a rebuild.
  rm -f -- "$output.tmp.zip"
  zip -q -r "$output.tmp.zip" . -x "*.symbols" flutter_service_worker.js
  unzip -tq "$output.tmp.zip"
  mv -f -- "$output.tmp.zip" "$output"
)
printf '%s\n' "dist/$package"
