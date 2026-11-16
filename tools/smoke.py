#!/usr/bin/env python3
"""Compile and run the storage/PDF smoke checks without a listening test socket."""
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
from flutter_sdk import sdk
(root / 'build').mkdir(exist_ok=True)
with (root / 'build/smoke-compile.log').open('w') as log:
    result = subprocess.run([str(sdk / 'bin/cache/dart-sdk/bin/dartaotruntime'),
        str(sdk / 'bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot'),
        '--sdk-root', str(sdk / 'bin/cache/artifacts/engine/common/flutter_patched_sdk') + '/',
        '--target=flutter', '--packages=.dart_tool/package_config.json',
        '--output-dill=build/smoke.dill', 'tools/smoke.dart'], cwd=root, stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    print('\n'.join(line for line in (root / 'build/smoke-compile.log').read_text().splitlines() if not line.startswith('+file:'))); sys.exit(result.returncode)
result = subprocess.run([str(sdk / 'bin/cache/artifacts/engine/linux-x64/flutter_tester'),
    '--disable-vm-service', '--run-forever', '--flutter-assets-dir=build/unit_test_assets', 'build/smoke.dill'],
    cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
print(result.stdout, end='')
sys.exit(result.returncode or (0 if 'All standalone smoke checks passed, including Noter 1.3 performance.' in result.stdout else 1))
