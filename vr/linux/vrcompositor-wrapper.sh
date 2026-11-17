#!/bin/bash
# Localview PC VR: wrapper for SteamVR's compositor, installed by Localview as
# SteamVR/bin/linux64/vrcompositor (the original is kept as vrcompositor.real).
#
# While a Localview PC VR session is active (~/.config/localview/vr_active), the
# compositor gets the Localview capture layer, plus on Wayland the DRM-lease shim,
# so its headset frames go to the Localview SteamVR driver. Otherwise it starts the
# original compositor unchanged, so other headsets keep working.
REAL="$(dirname "$0")/vrcompositor.real"
LV_DIR="@LV_DIR@"
if [ -f "$HOME/.config/localview/vr_active" ] && [ -f "$LV_DIR/layer/localview_capture.json" ]; then
  export VK_LAYER_PATH="$LV_DIR/layer${VK_LAYER_PATH:+:$VK_LAYER_PATH}"
  export VK_INSTANCE_LAYERS="VK_LAYER_LOCALVIEW_capture"
  export VK_LOADER_LAYERS_ENABLE="VK_LAYER_LOCALVIEW_capture,VK_LAYER_MESA_device_select"
  export VK_LOADER_LAYERS_DISABLE="*"
  export DISABLE_VK_LAYER_VALVE_steam_fossilize_1=1 DISABLE_MANGOHUD=1 DISABLE_VKBASALT=1 DISABLE_OBS_VKCAPTURE=1
  if [ -n "$WAYLAND_DISPLAY" ]; then
    export LD_PRELOAD="$LV_DIR/localview/bin/linux64/liblocalview_drm_lease_shim.so${LD_PRELOAD:+:$LD_PRELOAD}"
  fi
fi
exec -a "$0" "$REAL" "$@"
