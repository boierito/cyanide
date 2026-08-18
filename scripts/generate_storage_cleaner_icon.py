#!/usr/bin/env python3
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICON_DIR = ROOT / "Cyanide" / "Assets.xcassets" / "AppIcon.appiconset"
SOURCE_SVG = ICON_DIR / "storage-cleaner-icon-source.svg"

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
    if not SOURCE_SVG.exists():
        raise RuntimeError(f"missing icon source: {SOURCE_SVG}")

    ICON_DIR.mkdir(parents=True, exist_ok=True)
    for filename, size in IOS_ICONS.items():
        output = ICON_DIR / filename
        subprocess.run(
            [
                "rsvg-convert",
                "--width", str(size),
                "--height", str(size),
                "--output", str(output),
                str(SOURCE_SVG),
            ],
            check=True,
        )
        if not output.exists() or output.stat().st_size == 0:
            raise RuntimeError(f"failed to generate {output}")

    print(f"Generated {len(IOS_ICONS)} Storage Cleaner iOS app-icon assets from SVG.")


if __name__ == "__main__":
    main()
