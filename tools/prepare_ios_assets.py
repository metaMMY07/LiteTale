"""Select assets for the iOS build checkout before Flutter builds its bundle."""

import sys
from pathlib import Path


pubspec = Path(sys.argv[1])
text = pubspec.read_text(encoding="utf-8")
assets = [
    line for line in text.splitlines(keepends=True)
    if not line.strip().startswith("- lib/assets/epub_")
]
pubspec.write_text("".join(assets), encoding="utf-8")
