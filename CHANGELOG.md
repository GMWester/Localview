# Changelog

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
