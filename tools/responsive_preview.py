#!/usr/bin/env python3
"""Render actual Flutter library/editor scenes on phone and tablet sizes."""
import os
from pathlib import Path
import subprocess
import sys

from flutter_sdk import sdk

root = Path(__file__).resolve().parent.parent
(root / 'build').mkdir(exist_ok=True)
with (root / 'build/responsive-preview-compile.log').open('w') as log:
    result = subprocess.run([
        str(sdk / 'bin/cache/dart-sdk/bin/dartaotruntime'),
        str(sdk / 'bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot'),
        '--sdk-root', str(sdk / 'bin/cache/artifacts/engine/common/flutter_patched_sdk') + '/',
        '--target=flutter', '--packages=.dart_tool/package_config.json',
        '--output-dill=build/responsive-preview.dill', 'tools/responsive_preview.dart',
    ], cwd=root, stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    print((root / 'build/responsive-preview-compile.log').read_text())
    sys.exit(result.returncode)
for mode in ['phone', 'tablet', 'portrait']:
    environment = dict(os.environ)
    environment['XDG_DATA_HOME'] = str(root / 'build/responsive-preview-data' / mode)
    environment['NOTER_RESPONSIVE_SIZE'] = mode
    result = subprocess.run([
        str(sdk / 'bin/cache/artifacts/engine/linux-x64/flutter_tester'),
        '--disable-vm-service', '--run-forever',
        '--flutter-assets-dir=build/unit_test_assets', 'build/responsive-preview.dill',
    ], cwd=root, env=environment, timeout=60)
    if result.returncode:
        sys.exit(result.returncode)
