#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 8 ]; then
  echo "Usage: $0 <bundle_dir> <output_dir> <version_name> <version_code> <arch> <deb_arch> <rpm_arch> <appimagetool_url>" >&2
  exit 1
fi

bundle_dir="$1"
output_dir="$2"
version_name="$3"
version_code="$4"
arch="$5"
deb_arch="$6"
rpm_arch="$7"
appimagetool_url="$8"

icon_path="client/icons/Icon12-iOS-Default-1024x1024@1x.png"
license_path="client/licenses/DroidSansFallback-LICENSE.txt"

if [ ! -d "$bundle_dir" ]; then
  echo "Bundle dir not found: $bundle_dir" >&2
  exit 1
fi

if [ ! -f "$icon_path" ]; then
  echo "App icon not found: $icon_path" >&2
  exit 1
fi

if [ ! -f "$license_path" ]; then
  echo "License file not found: $license_path" >&2
  exit 1
fi

exec_path="$(find "$bundle_dir" -maxdepth 1 -type f -executable | head -n1 || true)"
if [ -z "$exec_path" ]; then
  echo "Cannot find executable in bundle root: $bundle_dir" >&2
  find "$bundle_dir" -maxdepth 2 -type f | sed 's/^/  /'
  exit 1
fi
exec_name="$(basename "$exec_path")"

mkdir -p "$output_dir"

tar -C "$(dirname "$bundle_dir")" -czf "$output_dir/RemoteMessageClient-linux-${arch}-${version_name}-${version_code}.tar.gz" bundle

pkg_version="$(echo "$version_name" | tr -cd '0-9A-Za-z.')"
if [ -z "$pkg_version" ]; then
  pkg_version="0.0.1"
fi

pkgroot="$(mktemp -d)"
appdir="appdir-${arch}"
rm -rf "$appdir"
trap 'rm -rf "$pkgroot" "$appdir" appimagetool' EXIT

mkdir -p "$pkgroot/opt/RemoteMessageClient"
cp -R "$bundle_dir"/. "$pkgroot/opt/RemoteMessageClient/"

mkdir -p "$pkgroot/usr/share/applications"
cat > "$pkgroot/usr/share/applications/remotemessage.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=RemoteMessage
Comment=RemoteMessage desktop client
Exec=/opt/RemoteMessageClient/$exec_name
Icon=remotemessage
Categories=Network;
Terminal=false
StartupNotify=true
EOF

mkdir -p "$pkgroot/usr/share/icons/hicolor/256x256/apps"
cp "$icon_path" "$pkgroot/usr/share/icons/hicolor/256x256/apps/remotemessage.png"

mkdir -p "$pkgroot/usr/share/doc/remotemessage-client"
cp "$license_path" "$pkgroot/usr/share/doc/remotemessage-client/DroidSansFallback-LICENSE.txt"

fpm -s dir -t deb \
  -n remotemessage-client \
  -v "$pkg_version" \
  --iteration "$version_code" \
  --architecture "$deb_arch" \
  --description "RemoteMessage desktop client" \
  --license "Apache-2.0" \
  --maintainer "RemoteMessage" \
  --after-install client/linux_post_install.sh \
  --after-remove client/linux_post_remove.sh \
  -C "$pkgroot" \
  -p "$output_dir/RemoteMessageClient-linux-${arch}-${version_name}-${version_code}.deb" \
  .

fpm -s dir -t rpm \
  -n remotemessage-client \
  -v "$pkg_version" \
  --iteration "$version_code" \
  --architecture "$rpm_arch" \
  --description "RemoteMessage desktop client" \
  --license "Apache-2.0" \
  --maintainer "RemoteMessage" \
  --after-install client/linux_post_install.sh \
  --after-remove client/linux_post_remove.sh \
  -C "$pkgroot" \
  -p "$output_dir/RemoteMessageClient-linux-${arch}-${version_name}-${version_code}.rpm" \
  .

mkdir -p "$appdir"
cp -R "$bundle_dir"/. "$appdir"/

cat > "$appdir/AppRun" <<EOF
#!/bin/sh
HERE="\$(dirname "\$(readlink -f "\$0")")"
exec "\$HERE/$exec_name" "\$@"
EOF
chmod +x "$appdir/AppRun"

cat > "$appdir/remotemessage.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=RemoteMessage
Comment=RemoteMessage desktop client
Exec=$exec_name
Icon=remotemessage
Categories=Network;
Terminal=false
StartupNotify=true
EOF

cp "$icon_path" "$appdir/remotemessage.png"

curl -L "$appimagetool_url" -o appimagetool
chmod +x appimagetool
APPIMAGE_EXTRACT_AND_RUN=1 ./appimagetool "$appdir" "$output_dir/RemoteMessageClient-linux-${arch}-${version_name}-${version_code}.AppImage"
