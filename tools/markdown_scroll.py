#!/usr/bin/env python3
"""Run the Markdown scroll probe in a headless Flutter engine, without desktop build tools."""
import os
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
package_file = build / 'markdown-scroll-packages.json'
package_file.write_text(json.dumps(packages))
dill = build / 'markdown-scroll.dill'
with (build / 'markdown-scroll-compile.log').open('w') as log:
    result = subprocess.run([
        str(sdk / 'bin/cache/dart-sdk/bin/dartaotruntime'),
        str(sdk / 'bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot'),
        '--sdk-root', str(sdk / 'bin/cache/artifacts/engine/common/flutter_patched_sdk') + '/',
        '--target=flutter', '--packages=' + str(package_file),
        '--output-dill=' + str(dill), 'tools/markdown_scroll.dart',
    ], cwd=root, stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    print((build / 'markdown-scroll-compile.log').read_text())
    sys.exit(result.returncode)
result = subprocess.run([
    str(sdk / 'bin/cache/artifacts/engine/linux-x64/flutter_tester'),
    '--disable-vm-service', '--run-forever',
    '--flutter-assets-dir=build/unit_test_assets', str(dill),
], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120, env=dict(os.environ, NOTER_BENCHMARK_EXIT='1'))
print(result.stdout, end='')
report = None
for line in result.stdout.splitlines():
    if line.startswith('NOTER_MARKDOWN_SCROLL='):
        report = json.loads(line.split('=', 1)[1])
        (build / 'markdown-scroll-results.json').write_text(
            json.dumps(report, indent=2) + '\n')
if report:
    assert report['parses'] == 1, 'Scrolling must never parse Markdown again'
    assert report['cached_blocks'] <= 256, 'Widget cache must stay bounded'
    assert report['ui']['samples'] > 100, 'Need real frame timings'
sys.exit(result.returncode or (0 if report else 1))
