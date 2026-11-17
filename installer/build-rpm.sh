#!/bin/sh
# build-rpm.sh <bundle-dir> <mode> <label> <rpm-arch: x86_64|aarch64> <version> <output.rpm>
# Fedora / RHEL / openSUSE package (prebuilt Flutter bundle under /opt).
set -eu
BUNDLE=$(cd "$1" && pwd); MODE=$2; LABEL=$3; ARCH=$4; VERSION=$5; OUT=$6
NAME=localview-$MODE
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(mktemp -d)
mkdir -p "$TOP/SPECS" "$TOP/BUILD" "$TOP/RPMS" "$TOP/SOURCES"
cat > "$TOP/SPECS/$NAME.spec" <<EOD
Name:           $NAME
Version:        $VERSION
Release:        1
Summary:        Localview $LABEL - control your devices from anywhere
License:        AGPL-3.0-only
URL:            https://github.com/GMWester/Localview
BuildArch:      $ARCH
AutoReqProv:    no
Requires:       gtk3, libX11, libXtst, libXfixes, pulseaudio-libs
Recommends:     gvfs
Suggests:       ffmpeg-free

%global debug_package %{nil}
%global _build_id_links none
%global __strip /bin/true
%global __brp_check_rpaths %{nil}

%description
Remote desktop with end-to-end encryption, game mode (hardware video, audio,
controllers), remote drives and VR streaming.

%install
mkdir -p %{buildroot}/opt/$NAME %{buildroot}%{_bindir} %{buildroot}%{_datadir}/applications \
  %{buildroot}%{_datadir}/icons/hicolor/512x512/apps %{buildroot}/usr/lib/udev/rules.d
cp -r $BUNDLE/. %{buildroot}/opt/$NAME/
ln -s /opt/$NAME/localview %{buildroot}%{_bindir}/$NAME
cp $HERE/../assets/icon.png %{buildroot}%{_datadir}/icons/hicolor/512x512/apps/$NAME.png
cat > %{buildroot}%{_datadir}/applications/$NAME.desktop <<DESK
[Desktop Entry]
Type=Application
Name=Localview $LABEL
Comment=Remote desktop, game and VR streaming
Exec=/opt/$NAME/localview
Icon=$NAME
Categories=Network;RemoteAccess;Game;
StartupWMClass=io.localview.localview
DESK
echo 'KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"' > %{buildroot}/usr/lib/udev/rules.d/60-localview-uinput.rules

%post
udevadm control --reload-rules >/dev/null 2>&1 || :
udevadm trigger --name-match=uinput >/dev/null 2>&1 || :

%files
/opt/$NAME
%{_bindir}/$NAME
%{_datadir}/applications/$NAME.desktop
%{_datadir}/icons/hicolor/512x512/apps/$NAME.png
/usr/lib/udev/rules.d/60-localview-uinput.rules
EOD
rpmbuild --quiet --define "_topdir $TOP" --target "$ARCH" -bb "$TOP/SPECS/$NAME.spec"
cp "$TOP"/RPMS/*/*.rpm "$OUT"
rm -rf "$TOP"
