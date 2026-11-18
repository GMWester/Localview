# Changelog

## 1.11.2

- **Fixed (for real): the mouse acting in the wrong place on a horizontal Android device**: besides the input, the screen capture also read a screen size that could still be the vertical one after the device turned. The horizontal screen was then squeezed into a vertical picture with black bars, and every click was mapped onto the wrong spot. Capture and input now check the size against the display's actual rotation (and the panel's natural orientation, for tablets), so the picture and the clicks follow every turn.

## 1.11.1

- **Play videos from a device's drive on your computer**: Windows' built-in WebDAV client refuses files over 50 MB by default, so most videos on a phone's drive failed with an error. When a device's storage appears as a drive, Localview now offers to raise that limit to 4 GB (once, with Windows' administrator prompt); the same is on *This device → Allow videos & large files on device drives*. On all computers, files now stream faster (the next part is fetched from the device while the current one is sent) and carry their real type (video/mp4, image/jpeg, ...), which some players need. macOS and Linux have no such size limit.
- **Lower latency when controlling an Android device in game mode** (regression in 1.10.0): the device re-sent a saved copy of its screen while nothing changed, and that copy could be up to 0.4 s old, so the picture jumped back and seemed to lag. Frames now go straight to the encoder (WebRTC repeats the last one by itself). Android devices also stream at most 8 Mbit/s and 60 fps: a phone uploading the default 20 Mbit/s over Wi-Fi filled its own send queue, which delayed the remote control's input on the same connection.
- **Fixed: clicks landing in the wrong place on a horizontal Android device**: the device converted the pointer position using a screen size that could still be the vertical one after the screen turned (while Localview runs in the background), so in landscape the mouse acted far away from where it was shown. It now uses the display's current size, for both touch input and Localview Pro's real mouse.
- **Fixed: the horizontal / vertical button sometimes doing nothing**: the computer chose the direction from the size of the last still picture, which no longer updates in game mode, so it could ask for the orientation the device already had. The device now switches to the other orientation based on its own rotation. If the app on screen keeps its own orientation (many home screens and some apps do), Localview says so instead of silently doing nothing.

## 1.11.0

- **Localview Pro starts by itself**: when a computer (Windows, macOS, Linux) connects to an Android device with Localview Pro, it now connects adb and starts real mouse & keyboard automatically in the background; a message says when it is on. Only the first pairing (6-digit code in the ADB dialog) is still done by hand. Wireless debugging and *ADB over Localview* must be on.
- **adb goes straight over your network**: on the same network, adb (pairing, connecting, starting the helper) now talks to the device directly at its local address instead of through the encrypted Localview connection, which is faster and avoids "device offline". Over the internet it still goes through Localview.
- Stale adb entries ("offline") are dropped and reconnected automatically, and the device answers the ADB dialog faster when Android already reports its wireless debugging port.

## 1.10.0

- **Game mode for Android devices (much faster phone streaming)**: Android phones, tablets, TVs and headsets now stream their screen as real hardware-encoded video (WebRTC, H.264), the same way computers do in game mode, instead of one JPEG picture per frame. Frames are a fraction of the size, the picture is smoother with less delay, and the device works less hard. It uses the screen sharing that is already running, so there is no second "start recording" prompt on the device. It starts automatically while *Game mode* is on in your settings (the default); if it can't connect, Localview falls back to pictures as before. The device's sound keeps its own path (the sound button works the same). While a computer watches in game mode, other viewers of the same device get no new pictures until it stops.
- **Turn the controlled phone's screen off**: when you control an Android device, the session toolbar has a screen button. With Localview Pro's helper running, the device's display really switches off while the picture keeps streaming to your computer, so only you see it and the device runs cooler (the power button turns it back on). Without the helper the brightness goes to its minimum instead (allow *Modify system settings* the first time). The screen comes back when you press the button again or disconnect.
- **Stop adb servers** (Windows, macOS, Linux): a button on *This device* (and *Stop adb* in the ADB dialog) ends every adb server still running on the computer.

## 1.9.4

- **Fixed: Localview Pro's real mouse & keyboard never turned on**: the helper listened on a kind of local socket that Android's security rules (SELinux) don't let normal apps open, so the app could never reach it and kept saying "off" even while the helper ran. The helper now listens on 127.0.0.1 (TCP), which apps may connect to. After updating, start the helper again from the computer; it replaces the old one.
- **Stop helpers button** (Localview Pro): *This device → Real mouse & keyboard* has a stop button that ends every real mouse & keyboard helper still running on the device. Starting the helper also stops older copies first, so they no longer pile up (or block the new one with "already running"). Helpers from 1.9.3 and older can't be reached by the app: restart the device once or start the new helper from the computer.
- **ADB dialog**: always shows the helper's start command with a copy button, including how to run it with adb connected directly over Wi-Fi when the connection through Localview says "device offline".
- ADB over Localview: a new connection is registered on the device before the computer is told it is open.

## 1.9.3

- **Fixed: Android devices disappearing and reappearing in Nearby**: Android drops network broadcasts to save power, and Localview only kept them let through while its window was open, so a phone running in the background (or with the screen off) missed most discovery questions. Localview now keeps Wi-Fi discovery working, and Wi-Fi in low-latency mode, for as long as it runs, also in the background. Computers also ask devices they already list directly every 3 seconds instead of relying on broadcasts, and only remove a device after 20 seconds without an answer (was 12).
- **Localview Pro can no longer freeze the session**: mouse and keyboard events now go through a queue that never blocks the app (pointer moves are merged), and the status check uses its own connection. Before, a helper that stopped reading could stall input and status checks, so clicks did nothing, the picture seemed frozen and the ADB dialog said the device "did not answer in time".
- **Localview Pro checks that Android accepts its input**: the helper counts the events Android accepts and refuses. If Android refuses everything, the device uses touch input again and *This device* and the ADB dialog show the reason.
- **ADB dialog**: after *Start real mouse & keyboard* it shows the helper's own log (read through adb), adb's output is always visible, and a slow answer from the device no longer hides the buttons and ports it showed before.

## 1.9.2

- **Install adb from Localview**: the ADB dialog (*⋮ → ADB (wireless debugging)…*) has an **Install adb** button on Windows, macOS and Linux that downloads Google's Android SDK Platform-Tools into Localview's own folder, so you no longer have to install adb yourself before pairing or starting Localview Pro's real mouse & keyboard.
- **Fixed: "does not allow ADB over Localview yet" although it was allowed**: when the Android device took long to look up its wireless-debugging ports (some devices never finish, especially while the pairing code is shown), the computer gave up and wrongly reported ADB as not allowed. The device now always answers within a few seconds (and reads the port directly where Android allows it), the computer waits longer, and a late answer shows "did not answer in time – Refresh" instead.

## 1.9.1

- **Android, Android Pro, Android TV and Android XR / Quest builds are back**: they were missing from 1.9.0 because the new sound player didn't build on Android. Everything listed under 1.9.0 for Android (sound from Android devices, Localview Pro) arrives with this version.
- **Localview Pro: the sound moves off the Android device** (Android 12+): when you switch the sound to your device while Localview Pro's helper is running, the helper records the device's whole sound output directly. Android then plays it only through Localview, so the device's speaker is silent without touching its volume, and apps that block normal capture (some streaming apps) come through as well. Restart the helper once after updating (*⋮ → ADB (wireless debugging)… → Start real mouse & keyboard*). Without the helper, or on Android 10–11, the 1.9.0 behaviour stays: the sound is copied and the device's media volume is turned down while it plays on your device.

## 1.9.0

- **Choose where the sound plays**: when you control a Windows or Linux computer, a speaker / headphones button in the session toolbar switches the sound between playing **only on the controlled computer** and **only on the device you control it from**. Game mode starts with the sound on your device. On Windows the computer's speakers are muted (on a few audio drivers this also silences the streamed sound; switch back if you hear nothing); on Linux the sound is routed into a private Localview output instead, so the speakers stay silent and the stream keeps working. The speakers come back when you switch back or disconnect. macOS computers can't send their sound, so the button isn't shown for them.
- **Sound from Android devices** (Android 10+): when you control a phone, tablet, TV or headset, the same button brings the sound apps play on it to your device. While it plays on your device, the Android device's media volume is turned down to zero (the stream keeps full volume) and put back when you switch back or disconnect. The first time, allow *Record audio* for Localview on the device (asked when you start sharing the screen); Localview only captures the sound apps play, never the microphone. Apps that forbid capture (some streaming apps with copy protection) stay silent in the stream.
- **Localview Pro for Android** (new `android-pro` release files): the Android app plus a small helper that runs with adb *shell* privileges, so a computer controlling the phone or tablet sends **real mouse and keyboard events**: hover, real left / right / middle clicks, the real scroll wheel, keyboard shortcuts and real key presses (also in games), instead of simulated touches. Start it from the computer through ADB over Localview: *⋮ → ADB (wireless debugging)… → Start real mouse & keyboard* (needed again after each restart of the device). The helper only answers the Localview app on that device. The regular Android build is unchanged.

## 1.8.0

- **Live touch when controlling Android** (Android 8+): pressing the mouse button puts the finger down immediately, it follows the pointer while you hold it and lifts on release. Previously a drag was only replayed after you let go (at the speed you dragged), which made scrolling and swiping on a phone lag by up to a couple of seconds. Holding the button is now a real long-press. Android 7 keeps the previous behaviour.
- **Type on Android with your computer's keyboard**: everything you type goes into the field that has focus on the device, in your own keyboard layout (Shift, AltGr, accents). Text is inserted at the cursor; Backspace, Delete, Enter, Tab (next field), the arrow keys and Home / End work, Ctrl+A / C / X select, copy and cut on the device, and **Ctrl+V pastes your computer's clipboard** into it. Apps that draw their own text fields (some games, a few web pages) may not accept it.
- **Smoother wheel scrolling on Android**: wheel notches are combined into one quick swipe instead of many slow ones that cancelled each other.
- **Faster Android video**: while you watch, each new screen image is compressed as soon as it is captured, so it is ready the moment it is needed, and phone screens are streamed at up to 1440 pixels (the *Resolution* setting still applies).

## 1.7.1

- **Fixed: a connected device's storage not appearing as a drive on Windows** when the device's name contains spaces (e.g. "My Android device"). The drive's web address no longer contains spaces (Explorer still shows the friendly name), and Localview retries with Windows' `\\127.0.0.1@port\…` form if the first attempt is refused.
- When you connect, Localview now says which drive letter the device's storage got, or why Windows refused the drive, instead of failing silently.

## 1.7.0

- **Much lower latency when controlling an Android device** (phones, tablets, Android TV, headsets): the device now compresses its screen natively (Android's JPEG encoder) instead of sending pixel tiles compressed in Dart, so frames are a fraction of the size and ready in milliseconds; nothing is sent while the screen is still. Controlling a phone from a PC went from 0.5–2 s behind to near real time. Viewers older than 1.7.0 keep the previous format.
- **Rotate the controlled device**: when you control an Android device, the session toolbar has a button to switch it between vertical and horizontal (and *⋮ → Device: auto-rotate* to give it back to the sensor). The first time, allow *Modify system settings* for Localview on the device (the screen opens there; you can tap it remotely). Apps that fix their own orientation keep it.
- **The stream follows the device's orientation**: turning a phone (or rotating it remotely) now resizes the picture instead of squeezing a landscape screen into a portrait frame.

## 1.6.0

- **Android updates**: from this version on, Android builds are signed with Localview's permanent release key, so in-app updates install over the previous version. Builds up to 1.5.0 used a temporary key: uninstall those once before installing 1.6.0. If an update is signed with a different key, Localview now says so instead of Android's "package conflicts" error.
- **ADB over Localview** (Android phones and tablets, Android TV / Google TV, Android XR and Meta Quest): a computer connected to the device with Localview can use `adb` without a cable. Turn on *This device → ADB over Localview* on the device and *Wireless debugging* in its Developer options (Android 11+; on TVs and headsets without it, *Network debugging* / `adb tcpip` on port 5555 works too). On the computer, *⋮ → ADB (wireless debugging)…* forwards the device's adb ports to `127.0.0.1` through the end-to-end encrypted connection, pairs (enter the code shown on the device) and runs `adb connect` for you. Works over the LAN and over the internet, and keeps working while Localview runs in the background. The device only accepts these tunnels while the setting is on, and only to its own adb.

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
