#!/usr/bin/env python3
"""Run analysis with a writable cache, without changing user configuration."""
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
from flutter_sdk import sdk
environment = dict(os.environ)
environment['ANALYZER_STATE_LOCATION_OVERRIDE'] = str(root / '.dart_tool/analyzer-cache')
sys.exit(subprocess.call([str(sdk / 'bin/cache/dart-sdk/bin/dart'), '--suppress-analytics', 'analyze'], cwd=root, env=environment))
