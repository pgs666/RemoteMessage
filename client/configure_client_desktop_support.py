from __future__ import annotations

import shutil
import sys
from pathlib import Path


DESKTOP_FONT_FAMILY = "RemoteMessageDesktopFallback"
FONT_FILE_NAME = "DroidSansFallbackFull.ttf"
FONT_ASSET_RELATIVE_PATH = f"assets/fonts/{FONT_FILE_NAME}"
CLIENT_DIR = Path(__file__).resolve().parent
FONT_SOURCE = CLIENT_DIR / "assets" / "fonts" / FONT_FILE_NAME


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python client/configure_client_desktop_support.py <flutter_app_dir>")
        return 1

    app_dir = Path(sys.argv[1]).resolve()
    if not app_dir.exists():
        raise FileNotFoundError(f"Flutter app directory not found: {app_dir}")

    configure_desktop_font(app_dir)

    print(f"Configured desktop support for {app_dir}")
    return 0


def configure_desktop_font(app_dir: Path) -> None:
    if not FONT_SOURCE.exists():
        raise FileNotFoundError(f"Bundled font not found: {FONT_SOURCE}")

    target_font = app_dir / FONT_ASSET_RELATIVE_PATH
    target_font.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(FONT_SOURCE, target_font)

    patch_pubspec(app_dir / "pubspec.yaml")


def patch_pubspec(pubspec_path: Path) -> None:
    if not pubspec_path.exists():
        return

    text = pubspec_path.read_text(encoding="utf-8")
    if DESKTOP_FONT_FAMILY in text:
        return

    newline = "\r\n" if "\r\n" in text else "\n"
    font_block = newline.join(
        [
            "  fonts:",
            f"    - family: {DESKTOP_FONT_FAMILY}",
            "      fonts:",
            f"        - asset: {FONT_ASSET_RELATIVE_PATH}",
        ]
    )

    marker = "  uses-material-design: true"
    if marker in text:
        text = text.replace(marker, f"{marker}{newline}{font_block}", 1)
    elif "flutter:" in text:
        text = text.replace("flutter:", f"flutter:{newline}{font_block}", 1)
    else:
        raise ValueError(f"Cannot find flutter section in {pubspec_path}")

    pubspec_path.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
