# Localview — macOS

> **This branch:** the macOS app (`macos/`). Pushing here builds LAN and WAN app bundles and publishes release `macos-v1.0.0`.

Control your devices from anywhere — a Parsec-style remote desktop app for **Windows, Linux, macOS, Android, iOS, Android TV, Android XR / Meta Quest and SteamOS (Steam Frame / Steam Deck)**, with **end-to-end encryption** and **remote storage mounted as real drives**.

Every platform has its own branch and its own GitHub Release, each with three builds — **LAN**, **WAN** and **Combined** (LAN + WAN in one app):

| Platform | Branch | Release | Can be controlled | Can control others |
|---|---|---|---|---|
| Windows 10/11 | [`main`](../../tree/main) | `windows-v1.0.0` | ✅ | ✅ |
| Linux (x64, arm64) | [`linux`](../../tree/linux) | `linux-v1.0.0` | ✅ (X11 session) | ✅ |
| macOS | [`macos`](../../tree/macos) | `macos-v1.0.0` | ✅ | ✅ |
| Android | [`android`](../../tree/android) | `android-v1.0.0` | ✅ | ✅ |
| iOS / iPadOS | [`ios`](../../tree/ios) | `ios-v1.0.0` | ❌ (Apple forbids input injection) | ✅ |
| Android TV | [`android-tv`](../../tree/android-tv) | `android-tv-v1.0.0` | ✅ | ✅ |
| Android XR & Meta Quest | [`android-xr`](../../tree/android-xr) | `android-xr-v1.0.0` | ✅ | ✅ |
| SteamOS (Steam Frame arm64, Steam Deck x64) | [`steamos`](../../tree/steamos) | `steamos-v1.0.0` | ✅ (X11 desktop) | ✅ |

Download from the [Releases page](../../releases). LAN and WAN builds talk to the same variant (LAN↔LAN, WAN↔WAN); **Combined** talks to all three.

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

Every message (video, input, clipboard, files) is sealed with **ChaCha20-Poly1305** using per-direction keys and counter nonces, so tampering, replay and reordering break the session. Passwords are never stored, only the salted PBKDF2 verifier. Five wrong passwords lock an IP out for five minutes. Ephemeral keys give forward secrecy.

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
* Appearance (This device → Appearance): System, Light, Dark, or **OLED** (pure black, ideal for OLED phones and VR headsets).
* Toolbar: stream quality (resolution/fps), clipboard send/receive, Win key, Alt+Tab, Ctrl+Shift+Esc, Android Back/Home/Recents.

## Platform setup notes

* **Windows** — allow the firewall prompt on first launch.
* **macOS** — grant *Screen Recording* and *Accessibility* (This device → Permissions). The app is ad-hoc signed: right-click → Open the first time.
* **Linux / SteamOS** — hosting needs an X11 session (Wayland can't be captured by third-party apps without a portal). Needs `libgtk-3`, `libX11`, `libXtst`, `libXfixes` (present on all mainstream desktops and SteamOS).
* **Android / TV / XR** — tap *Start* for screen sharing, enable the *Localview remote input* accessibility service, and allow *All files access* to share storage.
* **iOS** — unsigned IPA; sideload with AltStore/Sideloadly or sign it with your Apple developer account.
* APKs are signed with a CI debug key; uninstall before installing a build from a different CI run if Android refuses the update.

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

License: AGPL-3.0 (see `LICENSE`).
