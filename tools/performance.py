#!/usr/bin/env python3
"""Compile and run the large-PDF performance checks without a listening test socket."""
import os
import json
from urllib.parse import urljoin
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
from flutter_sdk import sdk
(root / 'build').mkdir(exist_ok=True)
config_file = root / '.dart_tool/package_config.json'
packages = json.loads(config_file.read_text())
for package in packages['packages']:
    package['rootUri'] = urljoin(config_file.as_uri(), package['rootUri'])
    if package['name'] == 'noter' and os.environ.get('NOTER_PERF_SOURCE'):
        package['rootUri'] = Path(os.environ['NOTER_PERF_SOURCE']).resolve().as_uri() + '/'
(root / 'build/performance-packages.json').write_text(json.dumps(packages))
with (root / 'build/performance-compile.log').open('w') as log:
    result = subprocess.run([str(sdk / 'bin/cache/dart-sdk/bin/dartaotruntime'),
        str(sdk / 'bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot'),
        '--sdk-root', str(sdk / 'bin/cache/artifacts/engine/common/flutter_patched_sdk') + '/',
        '--target=flutter', '--packages=build/performance-packages.json',
        '--output-dill=build/performance.dill', 'tools/performance.dart'], cwd=root, stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    print('\n'.join(line for line in (root / 'build/performance-compile.log').read_text().splitlines() if not line.startswith('+file:'))); sys.exit(result.returncode)
result = subprocess.run([str(sdk / 'bin/cache/artifacts/engine/linux-x64/flutter_tester'),
    '--disable-vm-service', '--run-forever', '--flutter-assets-dir=build/unit_test_assets', 'build/performance.dill'],
    cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
print(result.stdout, end='')
for line in result.stdout.splitlines():
    if line.startswith('NOTER_PERFORMANCE='):
        report = json.loads(line.split('=', 1)[1])
        (root / ('build/performance-baseline.json' if os.environ.get('NOTER_PERF_SOURCE') else 'build/performance-results.json')).write_text(json.dumps(report, indent=2) + '\n')
        # A generous regression guard catches the old 0.8-second UI stall;
        # this is not a 60-fps/device latency assertion.
        saving = next(r for r in report['results'] if r.get('operation') == 'save_48MiB')
        if not os.environ.get('NOTER_PERF_SOURCE') and saving['worst_event_loop_gap_ms'] > 250:
            raise SystemExit('Large-PDF saving blocked the UI event loop for over 250 ms.')
sys.exit(result.returncode or (0 if 'NOTER_PERFORMANCE=' in result.stdout else 1))
