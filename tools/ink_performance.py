#!/usr/bin/env python3
"""Run the ink CPU probe in a headless Flutter engine, without desktop build tools."""
import json
from pathlib import Path
import subprocess
import sys
from urllib.parse import urljoin
from flutter_sdk import sdk

root = Path(__file__).resolve().parent.parent
build = root / 'build'
build.mkdir(exist_ok=True)
config = root / '.dart_tool/package_config.json'
packages = json.loads(config.read_text())
for package in packages['packages']:
    package['rootUri'] = urljoin(config.as_uri(), package['rootUri'])
package_file = build / 'ink-performance-packages.json'
package_file.write_text(json.dumps(packages))
dill = build / 'ink-performance.dill'
with (build / 'ink-performance-compile.log').open('w') as log:
    result = subprocess.run([
        str(sdk / 'bin/cache/dart-sdk/bin/dartaotruntime'),
        str(sdk / 'bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot'),
        '--sdk-root', str(sdk / 'bin/cache/artifacts/engine/common/flutter_patched_sdk') + '/',
        '--target=flutter', '--packages=' + str(package_file),
        '--output-dill=' + str(dill), 'tools/ink_performance.dart',
    ], cwd=root, stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    print((build / 'ink-performance-compile.log').read_text())
    sys.exit(result.returncode)
result = subprocess.run([
    str(sdk / 'bin/cache/artifacts/engine/linux-x64/flutter_tester'),
    '--disable-vm-service', '--run-forever',
    '--flutter-assets-dir=build/unit_test_assets', str(dill),
], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
print(result.stdout, end='')
report = None
for line in result.stdout.splitlines():
    if line.startswith('NOTER_INK_PERFORMANCE='):
        report = json.loads(line.split('=', 1)[1])
        (build / 'ink-performance-results.json').write_text(
            json.dumps(report, indent=2) + '\n')
sys.exit(result.returncode or (0 if report else 1))
