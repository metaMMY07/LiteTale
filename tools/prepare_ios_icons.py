"""Render iOS asset-catalog sizes from the existing approved launcher resources.

Only iOS resources are written; Android artwork and geometry remain the source.
Requires Pillow, already used by generate_litetale_icons.py.
"""

import json
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
COLORS = ("iris", "blue", "rose", "orange", "teal", "green")


def main():
    catalog = ROOT / "ios/Runner/Assets.xcassets"
    source_dir = ROOT / "android/app/src/main/res/drawable-nodpi"
    for color in COLORS:
        name = "AppIcon" if color == "iris" else "AppIcon" + color.title()
        folder = catalog / (name + ".appiconset")
        folder.mkdir(parents=True, exist_ok=True)
        source = Image.open(source_dir / f"launcher_legacy_{color}.png").convert("RGB")
        # Fit the complete existing square; never crop the book's four corners.
        if source.width != source.height:
            raise ValueError(f"Expected square approved artwork for {color}")
        source.resize((1024, 1024), Image.Resampling.LANCZOS).save(folder / "Icon.png")
        contents = {
            "images": [{"filename": "Icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
            "info": {"author": "xcode", "version": 1},
        }
        (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")
    print("Prepared six iPhone/iPad icon sets from the existing launcher artwork.")


if __name__ == "__main__":
    main()
