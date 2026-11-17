# Changelog

## 1.2.0

- **Two-factor authentication**: protect a device with an authenticator app (Google Authenticator, Microsoft Authenticator, Authy, 1Password, …). Set up by QR code or by typing the key, then confirm with a code. Every connection to that device — including saved/paired devices — then asks for the current code. Codes are checked by the device itself, can't be reused, and wrong codes count toward the lockout.
- **In-app updates**: *This device → Updates* checks GitHub for a newer version and installs the right file for your platform, processor and variant (silent Windows setup, macOS disk image, Android installer, AppImage/.deb/archive on Linux and SteamOS).
- **Older & 32-bit Android devices**: besides the all-in-one APK, every Android, Android TV and Android XR / Quest release now has per-processor APKs — ARMv7 (32-bit: older phones, most Android TVs, older headsets), ARM64 and x86-64 (Chromebooks, emulators). Android 7.0 or newer (Android 10+ for the VR build). In-app updates pick the APK for your processor.
- **Windows on ARM**: native ARM64 builds (installer and zip) for Snapdragon / Copilot+ PCs and Surface Pro X. PC VR stays on x64 Windows (SteamVR has no ARM64 version).
- **Fedora / RHEL / openSUSE**: Linux releases now include `.rpm` packages (x86_64 and aarch64) next to the `.deb`, AppImage and archive; in-app updates use the same package type you installed.
- **Stable Android signing**: with a release key configured in CI, Android accepts in-app updates over the previous version.
- **Animations switch**: *This device → Appearance → Animations* turns off page transitions, touch ripples and dialog/sheet animations.

## 1.1.0

- **PC VR**: play SteamVR games on Meta Quest and Android XR headsets (SteamVR driver + native OpenXR client, encrypted UDP, Touch controllers, haptics, game audio).
- **Game mode**: hardware H.264 video with system audio over WebRTC (up to 4K60 / 1080p120), live stream stats, automatic fallback.
- **Controllers**: gamepads (and an on-screen pad on phones) appear on the PC as Xbox 360 controllers (ViGEmBus on Windows, uinput on Linux).
- **Theater mode**: fullscreen on every platform; Virtual-Desktop-style big screen on Android XR with size and surroundings options.
- **Combined variant**: LAN discovery and WAN pairing in one app.
- **Appearance**: System / Light / Dark (neutral grey) / OLED black themes.
- **Password lookup**: the device that set a password can show it again.
- **Installers**: Windows setup (.exe), macOS .dmg, Linux .deb and AppImage, all in one release per version.

## 1.0.0

- Remote control for Windows, Linux, macOS, Android, iOS (controller only), Android TV, Android XR / Quest and SteamOS.
- LAN and WAN variants, end-to-end encryption (X25519 + ChaCha20-Poly1305), pairing keys.
- Remote storage mounted as drives (Windows, macOS, Linux, Android) and an in-app file browser.
