#!/usr/bin/env python3
"""Render the actual library and editor in a headless Flutter engine."""
import os
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parent.parent
from flutter_sdk import sdk
(root / 'build').mkdir(exist_ok=True)
with (root / 'build/preview-compile.log').open('w') as log:
    result = subprocess.run([str(sdk / 'bin/cache/dart-sdk/bin/dartaotruntime'),
        str(sdk / 'bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot'),
        '--sdk-root', str(sdk / 'bin/cache/artifacts/engine/common/flutter_patched_sdk') + '/',
        '--target=flutter', '--packages=.dart_tool/package_config.json',
        '--output-dill=build/preview.dill', 'tools/preview.dart'], cwd=root, stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    print('\n'.join(line for line in (root / 'build/preview-compile.log').read_text().splitlines() if not line.startswith('+file:'))); sys.exit(result.returncode)
environment = dict(os.environ)
environment['XDG_DATA_HOME'] = str(root / 'build/preview-data')
for small in ([os.environ['NOTER_PREVIEW_ONLY']] if 'NOTER_PREVIEW_ONLY' in os.environ else ['0', '1', '2']):
    environment['NOTER_PREVIEW_SMALL'] = small
    result = subprocess.run([str(sdk / 'bin/cache/artifacts/engine/linux-x64/flutter_tester'),
        '--disable-vm-service', '--run-forever', '--flutter-assets-dir=build/unit_test_assets', 'build/preview.dill'], cwd=root, env=environment, timeout=180)
    if result.returncode: sys.exit(result.returncode)
