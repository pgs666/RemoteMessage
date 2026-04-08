from __future__ import annotations

import json
import sys
from pathlib import Path

from PIL import Image


ANDROID_ICON_SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

WINDOWS_ICON_SIZES = [16, 24, 32, 48, 64, 128, 256]

IOS_ICON_SPECS = [
    {"idiom": "iphone", "size": "20x20", "base": 20, "scales": [2, 3], "dark": True},
    {"idiom": "iphone", "size": "29x29", "base": 29, "scales": [2, 3], "dark": True},
    {"idiom": "iphone", "size": "40x40", "base": 40, "scales": [2, 3], "dark": True},
    {"idiom": "iphone", "size": "60x60", "base": 60, "scales": [2, 3], "dark": True},
    {"idiom": "ipad", "size": "20x20", "base": 20, "scales": [1, 2], "dark": True},
    {"idiom": "ipad", "size": "29x29", "base": 29, "scales": [1, 2], "dark": True},
    {"idiom": "ipad", "size": "40x40", "base": 40, "scales": [1, 2], "dark": True},
    {"idiom": "ipad", "size": "76x76", "base": 76, "scales": [1, 2], "dark": True},
    {"idiom": "ipad", "size": "83.5x83.5", "base": 83.5, "scales": [2], "dark": True},
    {"idiom": "ios-marketing", "size": "1024x1024", "base": 1024, "scales": [1], "dark": False},
]


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: python client/apply_client_icons.py <flutter_app_dir> <icons_dir>")
        return 1

    app_dir = Path(sys.argv[1]).resolve()
    icons_dir = Path(sys.argv[2]).resolve()

    default_icon_path = icons_dir / "Icon12-iOS-Default-1024x1024@1x.png"
    dark_icon_path = icons_dir / "Icon12-iOS-Dark-1024x1024@1x.png"

    if not default_icon_path.exists():
        raise FileNotFoundError(f"Default icon not found: {default_icon_path}")
    if not dark_icon_path.exists():
        raise FileNotFoundError(f"Dark icon not found: {dark_icon_path}")

    default_icon = load_square_image(default_icon_path)
    dark_icon = load_square_image(dark_icon_path)

    apply_android_icons(app_dir, default_icon)
    apply_ios_icons(app_dir, default_icon, dark_icon)
    apply_linux_icon(app_dir, default_icon)
    apply_windows_icon(app_dir, default_icon)

    print(f"Applied client icons to {app_dir}")
    return 0


def load_square_image(path: Path) -> Image.Image:
    image = Image.open(path).convert("RGBA")
    if image.width != image.height:
        raise ValueError(f"Icon must be square: {path}")
    return image


def resized(image: Image.Image, size: int) -> Image.Image:
    return image.resize((size, size), Image.Resampling.LANCZOS)


def save_png(image: Image.Image, path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    resized(image, size).save(path, format="PNG")


def apply_android_icons(app_dir: Path, default_icon: Image.Image) -> None:
    res_dir = app_dir / "android" / "app" / "src" / "main" / "res"
    if not res_dir.exists():
        return

    for folder_name, size in ANDROID_ICON_SIZES.items():
        save_png(default_icon, res_dir / folder_name / "ic_launcher.png", size)


def apply_linux_icon(app_dir: Path, default_icon: Image.Image) -> None:
    target = app_dir / "linux" / "runner" / "resources" / "app_icon.png"
    if not target.parent.exists():
        return

    save_png(default_icon, target, 256)


def apply_windows_icon(app_dir: Path, default_icon: Image.Image) -> None:
    target = app_dir / "windows" / "runner" / "resources" / "app_icon.ico"
    if not target.parent.exists():
        return

    target.parent.mkdir(parents=True, exist_ok=True)
    default_icon.save(target, format="ICO", sizes=[(size, size) for size in WINDOWS_ICON_SIZES])


def apply_ios_icons(app_dir: Path, default_icon: Image.Image, dark_icon: Image.Image) -> None:
    iconset_dir = app_dir / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    if not iconset_dir.parent.exists():
        return

    iconset_dir.mkdir(parents=True, exist_ok=True)
    contents = {
        "images": [],
        "info": {"version": 1, "author": "xcode"},
    }

    for spec in IOS_ICON_SPECS:
        safe_size = spec["size"].replace(".", "_")
        for scale in spec["scales"]:
            pixel_size = int(round(spec["base"] * scale))
            base_name = f"Icon-App-{safe_size}@{scale}x"
            default_name = f"{base_name}.png"
            save_png(default_icon, iconset_dir / default_name, pixel_size)
            contents["images"].append(
                {
                    "size": spec["size"],
                    "idiom": spec["idiom"],
                    "filename": default_name,
                    "scale": f"{scale}x",
                }
            )

            if spec.get("dark"):
                dark_name = f"{base_name}-dark.png"
                save_png(dark_icon, iconset_dir / dark_name, pixel_size)
                contents["images"].append(
                    {
                        "size": spec["size"],
                        "idiom": spec["idiom"],
                        "filename": dark_name,
                        "scale": f"{scale}x",
                        "appearances": [
                            {
                                "appearance": "luminosity",
                                "value": "dark",
                            }
                        ],
                    }
                )

    (iconset_dir / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())