#!/usr/bin/env python3
import base64
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICON_DIR = ROOT / "Cyanide" / "Assets.xcassets" / "AppIcon.appiconset"
SOURCE_B64 = ICON_DIR / "storage-cleaner-icon-source.b64"
SOURCE_JPG = ICON_DIR / ".storage-cleaner-icon-source.jpg"

IOS_ICONS = {
    "icon-ios-20x20@2x.png": 40,
    "icon-ios-20x20@3x.png": 60,
    "icon-ios-29x29@2x.png": 58,
    "icon-ios-29x29@3x.png": 87,
    "icon-ios-38x38@2x.png": 76,
    "icon-ios-38x38@3x.png": 114,
    "icon-ios-40x40@2x.png": 80,
    "icon-ios-40x40@3x.png": 120,
    "icon-ios-60x60@2x.png": 120,
    "icon-ios-60x60@3x.png": 180,
    "icon-ios-64x64@2x.png": 128,
    "icon-ios-64x64@3x.png": 192,
    "icon-ios-68x68@2x.png": 136,
    "icon-ios-76x76@2x.png": 152,
    "icon-ios-83.5x83.5@2x.png": 167,
    "icon-ios-1024x1024.png": 1024,
}


def main() -> None:
    ICON_DIR.mkdir(parents=True, exist_ok=True)
    SOURCE_JPG.write_bytes(base64.b64decode(SOURCE_B64.read_text().strip()))
    try:
        for filename, size in IOS_ICONS.items():
            output = ICON_DIR / filename
            subprocess.run(
                [
                    "sips",
                    "-s", "format", "png",
                    "-z", str(size), str(size),
                    str(SOURCE_JPG),
                    "--out", str(output),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            if not output.exists() or output.stat().st_size == 0:
                raise RuntimeError(f"failed to generate {output}")
        print(f"Generated {len(IOS_ICONS)} Storage Cleaner iOS app-icon assets.")
    finally:
        SOURCE_JPG.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
