#!/usr/bin/env python3
"""Capture the actual PDF, Markdown and library widgets with real fonts."""
import os
from pathlib import Path
import subprocess
import sys
from flutter_sdk import sdk

root = Path(__file__).resolve().parent.parent
(root / "build").mkdir(exist_ok=True)
log = root / "build/design-preview-compile.log"
with log.open("w") as output:
    result = subprocess.run([
        str(sdk / "bin/cache/dart-sdk/bin/dartaotruntime"),
        str(sdk / "bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot"),
        "--sdk-root", str(sdk / "bin/cache/artifacts/engine/common/flutter_patched_sdk") + "/",
        "--target=flutter", "--packages=.dart_tool/package_config.json",
        "--output-dill=build/design-preview.dill", "tools/design_preview.dart",
    ], cwd=root, stdout=output, stderr=subprocess.STDOUT)
if result.returncode:
    print(log.read_text())
    sys.exit(result.returncode)
for device in ("desktop", "phone", "tablet"):
    env = dict(os.environ, NOTER_DESIGN_DEVICE=device,
               XDG_DATA_HOME=str(root / "build/design-preview-data"))
    result = subprocess.run([
        str(sdk / "bin/cache/artifacts/engine/linux-x64/flutter_tester"),
        "--disable-vm-service", "--run-forever",
        "--flutter-assets-dir=build/unit_test_assets", "build/design-preview.dill",
    ], cwd=root, env=env, timeout=120)
    if result.returncode:
        sys.exit(result.returncode)
