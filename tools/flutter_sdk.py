"""Find Flutter from an explicit path, the workspace cache, or PATH."""
import os
from pathlib import Path
import shutil

root = Path(__file__).resolve().parent.parent
if os.environ.get('FLUTTER_SDK'):
    sdk = Path(os.environ['FLUTTER_SDK'])
elif (root / '.tooling/flutter/bin/flutter').exists():
    sdk = root / '.tooling/flutter'
elif shutil.which('flutter'):
    sdk = Path(shutil.which('flutter')).resolve().parent.parent
else:
    raise SystemExit('Flutter is missing. Set FLUTTER_SDK or add Flutter to PATH.')
