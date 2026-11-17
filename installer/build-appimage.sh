#!/bin/sh
# build-appimage.sh <bundle-dir> <mode> <label> <arch: x86_64|aarch64> <output.AppImage>
set -eu
BUNDLE=$1; MODE=$2; LABEL=$3; ARCH=$4; OUT=$5
DIR=$(mktemp -d)/Localview.AppDir
mkdir -p "$DIR/usr/lib/localview"
cp -r "$BUNDLE"/. "$DIR/usr/lib/localview/"
cp "$(dirname "$0")/../assets/icon.png" "$DIR/localview.png"
cat > "$DIR/AppRun" <<'EOD'
#!/bin/sh
HERE=$(dirname "$(readlink -f "$0")")
exec "$HERE/usr/lib/localview/localview" "$@"
EOD
chmod +x "$DIR/AppRun"
cat > "$DIR/localview.desktop" <<EOD
[Desktop Entry]
Type=Application
Name=Localview $LABEL
Exec=localview
Icon=localview
Categories=Network;RemoteAccess;Game;
EOD
TOOL=$(mktemp -d)/appimagetool
curl -fsSL -o "$TOOL" "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH.AppImage"
chmod +x "$TOOL"
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=$ARCH "$TOOL" --no-appstream "$DIR" "$OUT"
