# PC VR on Linux / SteamOS

SteamVR on Linux does not let a driver receive the compositor's frames directly
(the Windows `IVRDriverDirectModeComponent` path does not work there), so Localview
uses the same technique as [ALVR](https://github.com/alvr-org/ALVR):

| Part | Runs in | What it does |
|---|---|---|
| `../driver` (`driver_localview.so`) | `vrserver` | Headset + Touch controllers, tracking, encrypted UDP link, imports frames, RGB→NV12 on the GPU, H.264 via `ffmpeg` (NVENC / VA-API / x264) |
| `layer/` (`liblocalview_vk_capture.so`) | `vrcompositor` | Vulkan layer: provides a virtual headset display and hands each presented frame (Vulkan memory + timeline semaphore fds, render pose) to the driver over `$XDG_RUNTIME_DIR/localview-vr-ipc` |
| `shim/` (`liblocalview_drm_lease_shim.so`) | `vrcompositor` (Wayland only) | Fakes the Wayland DRM-lease protocol so the compositor uses the virtual display |
| `vrcompositor-wrapper.sh` | — | Installed as `SteamVR/bin/linux64/vrcompositor`; enables the layer/shim only while a Localview session is active |

The Localview app installs these to `~/.local/share/localview/vr/`, registers the
driver in `~/.config/openvr/openvrpaths.vrpath`, writes the session to
`~/.config/localview/vr_session.txt` and starts SteamVR through Steam.

`layer/` and `shim/` are adapted from ALVR (MIT, see `LICENSE-ALVR`; the layer
is in turn based on Arm's Vulkan WSI layer, MIT, see `layer/LICENSE-Arm`).

`test/pipeline_test.cpp` checks the driver side end to end (import → NV12 →
ffmpeg → decode) with a fake compositor; it runs on Mesa lavapipe in CI.
