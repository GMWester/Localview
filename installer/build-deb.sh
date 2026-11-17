#!/bin/sh
# build-deb.sh <bundle-dir> <mode> <label> <deb-arch: amd64|arm64> <version> <output.deb>
set -eu
BUNDLE=$1; MODE=$2; LABEL=$3; ARCH=$4; VERSION=$5; OUT=$6
NAME=localview-$MODE
ROOT=$(mktemp -d)
mkdir -p "$ROOT/DEBIAN" "$ROOT/opt/$NAME" "$ROOT/usr/bin" "$ROOT/usr/share/applications" \
  "$ROOT/usr/share/icons/hicolor/512x512/apps" "$ROOT/usr/lib/udev/rules.d"
cp -r "$BUNDLE"/. "$ROOT/opt/$NAME/"
ln -s "/opt/$NAME/localview" "$ROOT/usr/bin/$NAME"
cp "$(dirname "$0")/../assets/icon.png" "$ROOT/usr/share/icons/hicolor/512x512/apps/$NAME.png"
cat > "$ROOT/usr/share/applications/$NAME.desktop" <<EOD
[Desktop Entry]
Type=Application
Name=Localview $LABEL
Comment=Remote desktop, game and VR streaming
Exec=/opt/$NAME/localview
Icon=$NAME
Categories=Network;RemoteAccess;Game;
StartupWMClass=io.localview.localview
EOD
# Lets the logged-in user create virtual game controllers (uinput) for streamed gamepads.
cat > "$ROOT/usr/lib/udev/rules.d/60-localview-uinput.rules" <<EOD
KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"
EOD
cat > "$ROOT/DEBIAN/control" <<EOD
Package: $NAME
Version: $VERSION
Section: net
Priority: optional
Architecture: $ARCH
Maintainer: Localview <noreply@localview.invalid>
Depends: libgtk-3-0 | libgtk-3-0t64, libx11-6, libxtst6, libxfixes3, libpulse0
Recommends: gvfs-backends, pulseaudio | pipewire-pulse
Description: Localview $LABEL - control your devices from anywhere
 Remote desktop with end-to-end encryption, game mode (hardware video,
 audio, controllers), remote drives and VR theater support.
EOD
cat > "$ROOT/DEBIAN/postinst" <<'EOD'
#!/bin/sh
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --name-match=uinput 2>/dev/null || true
exit 0
EOD
chmod 755 "$ROOT/DEBIAN/postinst"
dpkg-deb --build --root-owner-group "$ROOT" "$OUT"
rm -rf "$ROOT"
