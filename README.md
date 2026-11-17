# Localview — iOS

> **This branch:** the iOS / iPadOS app (`ios/`). Pushing here builds unsigned LAN and WAN IPAs and adds them, with installers, to the release of the current version (`v<version>` from pubspec.yaml). iOS works as a controller and file share; Apple does not let apps be remotely controlled.

Control your devices from anywhere — a Parsec-style remote desktop app for **Windows, Linux, macOS, Android, iOS, Android TV, Android XR / Meta Quest and SteamOS (Steam Frame / Steam Deck)**, with **end-to-end encryption** and **remote storage mounted as real drives**.

Every platform has its own branch, and every branch publishes into **one release** ([Releases → latest](../../releases/latest)) with three variants — **LAN**, **WAN** and **Combined** (LAN + WAN in one app) — each as an installer and a portable download:

| Platform | Branch | Installer | Portable | Can be controlled | Can control others |
|---|---|---|---|---|---|
| Windows 10/11 (x64 and ARM64) | [`main`](../../tree/main) | `.exe` setup (Inno Setup, optional controller driver) | `.zip` | ✅ | ✅ |
| Linux x64 / arm64 | [`linux`](../../tree/linux) | `.deb` (Debian/Ubuntu), `.rpm` (Fedora/RHEL/openSUSE) | AppImage, `.tar.gz` | ✅ (X11 session) | ✅ |
| macOS | [`macos`](../../tree/macos) | `.dmg` | `.zip` | ✅ | ✅ |
| Android 7.0+ (ARMv7 32-bit, ARM64, x86-64) | [`android`](../../tree/android) | `.apk` (all-in-one or per processor) | | ✅ | ✅ |
| Android Pro (phones/tablets; real mouse & keyboard when controlled) | [`android-pro`](../../tree/android-pro) | `.apk` (all-in-one or per processor) | | ✅ (+ real mouse & keyboard via ADB helper) | ✅ |
| iOS / iPadOS | [`ios`](../../tree/ios) | `.ipa` (sideload) | | ❌ (Apple forbids input injection) | ✅ |
| Android TV (ARMv7 — most TVs, ARM64, x86-64) | [`android-tv`](../../tree/android-tv) | `.apk` (all-in-one or per processor) | | ✅ | ✅ |
| Android XR & Meta Quest (ARM64; ARMv7 for older 32-bit headsets) | [`android-xr`](../../tree/android-xr) | `.apk` (all-in-one or per processor) | | ✅ | ✅ + VR theater, PC VR |
| SteamOS: Steam Frame (arm64), Steam Deck (x64) | [`steamos`](../../tree/steamos) | AppImage | `.tar.gz` | ✅ (desktop mode) | ✅ + theater |

**Not sure which file to pick?** Use the [Localview Installer](https://github.com/GMWester/LocalViewInstaller/releases/latest): choose your device, processor and LAN/WAN/Combined, and it downloads and installs the matching build.

LAN and WAN builds talk to the same variant (LAN↔LAN, WAN↔WAN); **Combined** talks to all three.

## Game & video streaming (Game mode)

When the controlled device is a Windows, macOS or Linux PC, Localview switches to **Game mode** automatically:

* **Hardware video**: H.264 is preferred (GPU encode/decode on almost every device), with VP8/VP9/AV1 fallbacks. Presets go from 720p60 up to **4K60**, **1080p120**, and a native-resolution 90 fps preset for VR headsets (gamepad icon in the session toolbar).
* **Sound**: PC audio is streamed with the video. On Windows and Linux it is captured automatically (WASAPI / PulseAudio-PipeWire loopback). On macOS, install a loopback device such as [BlackHole](https://existential.audio/blackhole/) and route output to it; Localview picks it up.
* **Low latency**: real-time transport with congestion control and frame-rate-first degradation. Turn on *Show stream stats* to see resolution, fps, bitrate and round-trip time.
* **Controllers**: Xbox/PlayStation/Switch Pro controllers, Steam Frame and Quest controllers, and TV gamepads on the device you hold become a **virtual Xbox 360 controller on the PC** — ViGEmBus on Windows (the installer offers it) and uinput on Linux/SteamOS (the `.deb` adds the udev rule). Phones get an **on-screen controller** (gamepad toggle). On macOS hosts, which have no virtual-controller API, buttons are mapped to keys (WASD, Space, Esc…).
* **Security**: the WebRTC offer/answer travels inside the end-to-end encrypted Localview session, so the DTLS-SRTP media keys are authenticated by your password or pairing key. LAN builds never contact a STUN server; WAN and Combined builds use public STUN servers (Google, Cloudflare) only to discover their public address for NAT traversal.
* If UDP can't get through (strict firewalls), the session falls back to *compatibility mode* (the encrypted TCP stream) automatically.

## VR: Android XR, Meta Quest, Steam Frame

* **Android XR** (`android-xr` build): **Theater mode** (the VR icon in the session toolbar; headsets open in it automatically) switches to Full Space and turns the app into a big screen in front of you, Virtual-Desktop style. You pick the screen size (1.5 m to a 10 m cinema) and the surroundings (dark void, passthrough of your room, or the system environment) under ⋮ → *Theater size & surroundings*. Headset controllers act as the mouse (ray + trigger) and are forwarded as an Xbox controller in Game mode.
* **Meta Quest** (Horizon OS): the same build runs as a resizable panel (drag the corners to make it huge). Horizon OS does not let third-party panel apps create their own environment, so the theater there is the fullscreen, toolbar-less view.
* **Steam Frame / Steam Deck** (`steamos` build): add the AppImage to Steam (*Add a Non-Steam Game*). In the headset, SteamOS shows it on its large virtual screen; Localview's Theater mode goes fullscreen with no toolbar, and Steam Input forwards the Frame/Deck controls as a controller to the PC.
* **PC VR (SteamVR games)** — play SteamVR / OpenXR PC VR games on **Meta Quest** and **Android XR** headsets, like Virtual Desktop or ALVR:
  1. Install the Windows, Linux (x64) or SteamOS build of Localview on the gaming PC (it includes a SteamVR driver) and install Steam + SteamVR. On Linux / SteamOS also install `ffmpeg` (see below).
  2. On the headset, install the `android-xr` APK, connect to the PC, and press the **cube icon** (*Play SteamVR games*) in the session toolbar.
  3. Localview registers its driver with SteamVR, (re)starts SteamVR configured for your headset's resolution, field of view and refresh rate, and the headset switches to an immersive OpenXR view.
  * Video: GPU H.264 (NVIDIA/AMD/Intel through Media Foundation), 50–200 Mbps, side-by-side stereo at the headset's recommended resolution (capped at 2048 px per eye), 90 Hz.
  * Latency hiding: each frame carries the exact head pose SteamVR rendered it with, and the headset submits it with that pose so its compositor reprojects to your current head position.
  * Tracking: head and both controllers (position, rotation, velocities) every headset frame; controllers appear to games as Oculus Touch controllers (all buttons, triggers, grips, sticks, capacitive touch) with haptics.
  * Audio: game sound plays on the headset through the encrypted game-mode audio channel.
  * Security: every UDP packet is ChaCha20-Poly1305 encrypted and authenticated with a fresh 256-bit key that the PC generates per session and sends through the end-to-end encrypted Localview connection; replayed or forged packets are dropped.
  * Leave PC VR by holding the left controller's menu button for 3 seconds.
  * Network: use 5/6 GHz Wi-Fi (ideally the PC wired to the router). Over the internet, UDP port 47920 must be reachable (the WAN/Combined builds request it via UPnP).
  * Requirements: Windows 10/11, or Linux x64 / SteamOS, with a GPU that has a hardware H.264 encoder (practically every NVIDIA GTX 900+/AMD RX 400+/Intel HD 500+), SteamVR; Quest 2/3/3S/Pro or an Android XR headset.
  * **Linux / SteamOS** (details in [`vr/linux`](vr/linux/README.md)): Localview copies its driver to `~/.local/share/localview/vr`, registers it with SteamVR and installs a small wrapper for SteamVR's compositor that loads the Localview capture layer only while you stream (other headsets keep working). Video is encoded by `ffmpeg`: install it with your package manager (`sudo apt install ffmpeg`, `sudo dnf install ffmpeg-free`, `sudo pacman -S ffmpeg`); on SteamOS, whose system is read-only, put a static ffmpeg build at `~/.local/share/localview/ffmpeg/ffmpeg`. NVIDIA uses NVENC, AMD/Intel use VA-API (on Fedora, H.264 encoding needs the RPM Fusion `mesa-va-drivers-freeworld` / `intel-media-driver`), otherwise x264 on the CPU. Use the native Steam package rather than Flatpak Steam.
  * **Wine / Proton**: Windows-only VR games run through Steam's Proton, which passes their SteamVR (OpenVR) calls to the Linux SteamVR and therefore to Localview; nothing extra to set up. For a Windows VR game that isn't from Steam, add its `.exe` to Steam (*Games → Add a Non-Steam Game*), then *Properties → Compatibility → Force Proton*. Plain Wine has no SteamVR bridge, so launch such games through Proton. Proton/Wine games also work in game mode (flat screen streaming) without any setup.

## LAN variant

1. Install **Localview LAN** on both devices and connect them to the same router.
2. On the device you want to control, open **This device → Set password**.
3. On the other device, **Nearby devices** lists every device on the network running Localview LAN. Click one, type its password, and you're connected.

Discovery uses a UDP broadcast plus a unicast sweep of the local /24 (port 47801), so it also works on iOS and on networks that filter broadcasts. Sessions use TCP port 47800.

## WAN variant

1. Install **Localview WAN** on both devices.
2. On the device you want to control, set a password (**This device → Set password**). Its address is shown under *How to reach this device*; the app asks the router to forward TCP port **47900** with UPnP automatically (forward it manually if your router has UPnP off).
3. On your other device, press **+** in the *My devices* box, enter that IP (or `ip:port`) and the password.
4. A fresh 256-bit pairing key is generated and stored on **both** devices. The added device now shows up in your list, and the controlling device shows up on the other one too (under *My devices*, where you can allow it to control back). Later connections use the key — no password needed. Remove a device to delete its key.

## Combined variant (LAN + WAN in one app)

For devices you use both at home and from far away, install **Localview** (Combined) on both:

* **Devices → Nearby (LAN)** lists devices on the same router (LAN and Combined builds). Click one and type its password.
* Connecting on the LAN also pairs the devices: a pairing key is generated and saved on both, and the device is added to **Devices → My devices (anywhere)**. Its public IP (reported by the router via UPnP) is saved with it.
* From **My devices**, tapping a device connects over the LAN when it's nearby and over the internet otherwise — no password needed after the first time.
* You can still press **+** to add a device by IP and password, exactly like the WAN build.

Combined uses TCP port 47900 (UPnP-forwarded) and answers LAN discovery on UDP 47801, so it interoperates with LAN builds (via discovery) and WAN builds (via IP).

## Encryption

Each connection runs an ephemeral **X25519** key exchange. Session keys are derived with **HKDF-SHA256** from the shared secret combined with either
* `PBKDF2-SHA256(password, per-device salt, 120 000 iterations)` (LAN, and the first WAN pairing), or
* the 256-bit pairing key created when the device was added (WAN).

Every message (video, input, clipboard, files) is sealed with **ChaCha20-Poly1305** using per-direction keys and counter nonces, so tampering, replay and reordering break the session. Passwords never leave the device they were set on: other devices only ever prove knowledge of them through the key exchange. The device that set a password keeps it in its owner-only settings file so you can look it up there (This device → Password → eye button) if you forget it. Five wrong passwords lock an IP out for five minutes. Ephemeral keys give forward secrecy.

## Two-factor authentication

*This device → Two-factor authentication → Set up*: scan the QR code with an authenticator app (or tap *Type the code manually* and enter the key), press **Next** and type the 6-digit code it shows. From then on every connection to this device — by password or with a saved pairing key — also asks for the current code (RFC 6238 TOTP, 30-second codes, ±30 s clock tolerance, each code accepted once). Turning it off requires a current code. Nearby devices with 2FA show a shield icon.

## Updates

*This device → Updates* (bottom of the page) checks the latest release and installs the matching build: Windows runs the setup silently and restarts Localview, Android opens the package installer, Linux replaces the AppImage / installs the .deb / unpacks the archive, macOS opens the disk image. iOS can't self-update, so it links to the release.

## Remote storage as drives

While two devices are connected, each one can expose its storage to the other (toggle under **This device → Files & drives**). The storage is tunnelled through the encrypted session and served to the OS by a loopback-only WebDAV bridge (random secret path, `127.0.0.1` only):

| OS | Where the drive appears |
|---|---|
| Windows | File Explorer → This PC (mapped drive letter, via the built-in WebClient service). Windows limits WebDAV files to 50 MB by default — raise `HKLM\SYSTEM\CurrentControlSet\Services\WebClient\Parameters\FileSizeLimitInBytes` for bigger files. |
| macOS | Finder → Locations (mounted volume) |
| Linux / SteamOS | Files sidebar (GVfs `dav://` mount) |
| Android / Android TV / XR | Files app sidebar (Storage Access Framework provider) |
| iOS | iOS has no user-mountable network drives for apps without a File Provider extension, so use the **folder** button in a session to browse; downloads land in Files → On My iPhone → Localview |

The in-app file browser (folder button in the session toolbar) works on every platform.

## Controls

* **Mouse/keyboard**: everything is forwarded (physical key codes, so any layout works).
* **Touch**: tap = click, long-press = right-click, drag = drag, two fingers = scroll, keyboard button = on-screen keyboard.
* **TV remotes, game controllers, VR controllers**: the *virtual cursor* (mouse button in the toolbar; on by default on TV) — arrows/stick move, OK/A clicks, X right-clicks, Back/B toggles the toolbar. On Quest / Android XR the controller ray works as a normal pointer.
* **Monitors**: on a device with several monitors, the monitor button in the session toolbar picks which one you see (or *All displays* on Windows/Linux); mouse input and game mode follow it.
* **Where the sound plays**: controlling a Windows or Linux computer, the speaker / headphones button switches the sound between *only on that computer* and *only on this device* (Windows mutes its output; Linux routes the sound into a private `localview_stream` output). Game mode starts with the sound on this device.
* **Localview Pro (Android)**: the `android-pro` build adds a helper that runs with adb *shell* privileges, so computers controlling the device send real mouse and keyboard events (hover, right-click, wheel, keyboard shortcuts, keys in games) instead of simulated touches. Start it from the computer: *⋮ → ADB (wireless debugging)… → Start real mouse & keyboard* (needs ADB over Localview and Wireless debugging; again after each restart of the device). The helper only accepts the Localview app (a per-install token) and is gone after a restart. Text still goes through the layout-aware typing.
* **ADB over Localview** (Android, Android TV, Android XR / Quest): turn on *This device → ADB over Localview* and *Wireless debugging* on the device; on the computer, *⋮ → ADB (wireless debugging)…* pairs and runs `adb connect 127.0.0.1:<port>` through the encrypted Localview connection (LAN or internet, no cable). Older devices: *Network debugging* / `adb tcpip` (port 5555).
* **Keep running in the background** (This device → Appearance): closing the window while connected (or while the computer can be controlled) hides it instead of quitting; connections and their mounted drives stay available. Reopen from the tray icon / Dock or by starting Localview again; *Quit* is in the tray menu. On Android a notification keeps the connections running.
* **Several windows**: open each monitor, or each of several devices, in its own window (monitor button → *Open … in a new window*; device list → ⧉ / *Open in a new window*). Works on Windows, macOS, Linux, Android and on Android XR / Meta Quest, where every window is a separate panel. Extra windows reuse the login of the window that opened them through a session ticket (kept only in the device's memory, valid 12 hours, cleared when its password or 2FA changes).
* Appearance (This device → Appearance): System, Light, Dark, or **OLED** (pure black, ideal for OLED phones and VR headsets).
* Animations (This device → Appearance → Animations): turn off every UI animation (switches, menus, dialogs, page transitions, ripples).
* Toolbar: stream quality (resolution/fps), clipboard send/receive, Win key, Alt+Tab, Ctrl+Shift+Esc, Android Back/Home/Recents.

## Platform setup notes

* **Windows** — allow the firewall prompt on first launch.
* **macOS** — grant *Screen Recording* and *Accessibility* (This device → Permissions). The app is ad-hoc signed: right-click → Open the first time.
* **Linux / SteamOS** — Game mode needs PulseAudio or PipeWire running (all desktops have it). Hosting needs an X11 session (Wayland can't be captured by third-party apps without a portal). Needs `libgtk-3`, `libX11`, `libXtst`, `libXfixes` (present on all mainstream desktops and SteamOS).
* **Android / TV / XR** — tap *Start* for screen sharing, enable the *Localview remote input* accessibility service, and allow *All files access* to share storage.
* **iOS** — unsigned IPA; sideload with AltStore/Sideloadly or sign it with your Apple developer account.
* APKs are signed with a CI debug key; uninstall before installing a build from a different CI run if Android refuses the update.

## Installing

* **Windows**: run `Localview-<variant>-windows-x64-setup-<version>.exe` (ARM64 PCs: `…-windows-arm64-setup-<version>.exe`). It adds Start menu/desktop shortcuts, an optional sign-in auto-start (so the PC is reachable), a firewall rule, and optionally the ViGEmBus controller driver. The `.zip` is the same app without installation.
* **macOS**: open the `.dmg` and drag Localview to Applications.
* **Linux**: Debian/Ubuntu `sudo apt install ./localview-<variant>_<version>_<arch>.deb`; Fedora/RHEL `sudo dnf install ./localview-<variant>-<version>-1.<arch>.rpm`; or make the AppImage executable and run it.
* **SteamOS**: in Desktop Mode, download the AppImage for your device (arm64 for Steam Frame, x64 for Steam Deck), mark it executable, then add it to Steam as a Non-Steam Game.
* **Android / TV / XR / Quest**: install the APK (allow installs from unknown sources; on TV use Downloader or `adb install`; on Quest use SideQuest or `adb install`).
* **iOS**: sideload the unsigned IPA with AltStore/Sideloadly or sign it with your developer account.

## Versions

The version lives in one place, `version:` in `pubspec.yaml`. Every platform build reads it, shows it in the app and publishes to the release `v<version>`; see [CHANGELOG.md](CHANGELOG.md).

## Building from source

```bash
flutter pub get
flutter test
flutter build <windows|linux|macos|apk|ios> --release --dart-define=LV_MODE=lan   # or wan
```

For Android add `-P lvMode=wan` so LAN and WAN install side by side. Requires Flutter 3.50.

## Architecture

* `lib/src/crypto.dart` — handshake key derivation and the sealed channel
* `lib/src/host.dart` — host isolate: TCP server, auth, pairing, screen streaming
* `lib/src/client.dart` — client isolate: connect, decrypt, decode, drive bridge
* `lib/src/codec.dart` — tile-diff + deflate frame codec
* `lib/src/files.dart`, `link.dart` — encrypted file RPC, WebDAV bridge
* `lib/src/platform/` — native capture/input via FFI (Win32 GDI + SendInput, X11 + XTest + XFixes, CoreGraphics + CGEvent), Android (Kotlin MediaProjection + AccessibilityService + DocumentsProvider), OS drive mounting
* `lib/src/discovery.dart`, `upnp.dart` — LAN discovery and router port mapping
* `lib/src/stream/rtc.dart` — Game mode (WebRTC hardware video + audio, signaled through the encrypted session)
* `lib/src/platform/gamepad_host.dart`, `windows/runner/virtual_gamepad.cpp` — virtual Xbox controllers (ViGEmBus / uinput)
* `lib/src/platform/theater.dart`, `android-xr` `XrBridge.kt` — Theater mode / Android XR Full Space big screen
* `vr/driver/` — SteamVR driver (C++: virtual HMD + Touch controllers, D3D11 direct-mode compositor, Media Foundation H.264 encoder, encrypted UDP)
* `vr/common/` — VR wire protocol and ChaCha20-Poly1305 shared by the driver and headset
* `android-xr` `src/main/cpp/vr_main.cpp` — native OpenXR headset client (MediaCodec decode, reprojection-aware layer submission, controller input, haptics)
* `installer/` — Windows Inno Setup script, `.deb`, AppImage and `.dmg` builders

License: AGPL-3.0 (see `LICENSE`).
