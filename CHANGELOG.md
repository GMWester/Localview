# Changelog

## 1.5.0

- **Quit Localview**: a *Quit Localview* button at the bottom of *This device* closes the app completely, instead of keeping it in the background (asks first when that ends connections or remote access).
- **Fixed: no mouse pointer when controlling a phone or tablet** from a computer. Phones and tablets have no on-screen pointer, so your own pointer now stays visible over their picture.
- **Fixed: SD card missing from an Android device's shared storage.** The volumes now come from Android itself (internal storage, every SD card and USB drive, e.g. *SD card (9C33-6BBD)*), and cards inserted later appear within a few seconds.

## 1.4.0

- **Choose the monitor**: when the device you control has several monitors, the new monitor button in the session toolbar switches between them (or *All displays* on Windows and Linux). The mouse follows the monitor you see, and game mode streams that monitor too. Each viewer picks its own monitor.
- **Several windows at once** (Windows, macOS, Linux, Android, Android XR and Meta Quest): open each monitor of a device in its own window (monitor button → *Open … in a new window*), and open other devices in new windows from the device list (the ⧉ button on a nearby device, or *Open in a new window* in a saved device's menu). With three or more devices connected you can watch all of them side by side. On headsets every window is its own panel. Extra windows log in with a one-time session ticket from the window that opened them, so they ask for no password or authenticator code; tickets live only in the device's memory, last 12 hours and end when its password or 2FA changes.
- **Keep running in the background** (*This device → Appearance*, on by default): while you are connected to other devices, or your computer can be controlled remotely, closing Localview's window only hides it. Connections and the drives they share stay open, so the files of the connected devices stay available in Explorer / Finder / your file manager; the picture pauses while hidden. Reopen it from the tray icon (Windows, Linux) or the Dock (macOS), or simply start Localview again; the tray menu also has *Quit*. On Android, closing or swiping Localview away keeps the connections in a background service (shown as a notification).
- **Version in every file name**: release files now end with their version, e.g. `Localview-Combined-android-arm64-1.4.0.apk` or `Localview-Combined-windows-x64-setup-1.4.0.exe` (`.deb` and `.rpm` already did). In-app updates recognise both the new and the old names; Localview 1.3.0 and older look only for the old names, so update those once by hand or with the Localview Installer.

## 1.3.0

- **PC VR on Linux and SteamOS**: Linux (x64) and SteamOS PCs - including the Steam Deck - can now stream SteamVR games to Meta Quest and Android XR headsets, like the Windows version. Localview installs its SteamVR driver and a compositor capture layer (based on ALVR's) automatically when you press *Play SteamVR games* on the headset. Video is encoded on the GPU with NVENC (NVIDIA) or VA-API (AMD / Intel), with x264 as a fallback; this needs `ffmpeg` on the PC.
- **Windows VR games through Proton**: Windows-only SteamVR games run through Steam's Proton on Linux / SteamOS and stream to the headset like native ones. Non-Steam Windows VR games work when added to Steam (*Add a Non-Steam Game*) with Proton selected; plain Wine has no SteamVR bridge.
- **Android SD cards in shared drives**: an Android device's shared storage now shows *Internal storage* plus one *SD card (ID)* folder per SD card or USB drive, so cards appear in Windows Explorer, Finder and Linux file managers. (Writing to an SD card needs Android 11 or newer with *All files access*; on Android 10 and older, cards are read-only.)
- **Animations switch fixed**: turning animations off now also stops switch, dropdown and popup-menu, segmented-button, tab, navigation, snack-bar and tooltip animations (not just page transitions and ripples). Scrolling keeps its normal feel and loading spinners stay still.

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
