// Virtual Xbox 360 controllers for game streaming, via the ViGEmBus driver.
// Exported from the executable so Dart can call them with dart:ffi
// (DynamicLibrary.executable()).
#include <windows.h>

#include <ViGEm/Client.h>

#include <cstdint>
#include <mutex>

namespace {
std::mutex g_mutex;
PVIGEM_CLIENT g_client = nullptr;
PVIGEM_TARGET g_pads[4] = {nullptr, nullptr, nullptr, nullptr};
bool g_connected = false;
}  // namespace

extern "C" __declspec(dllexport) int32_t lv_pad_init() {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_connected) return 0;
  if (g_client == nullptr) g_client = vigem_alloc();
  if (g_client == nullptr) return -1;
  const VIGEM_ERROR err = vigem_connect(g_client);
  if (!VIGEM_SUCCESS(err)) {
    vigem_free(g_client);
    g_client = nullptr;
    return static_cast<int32_t>(err);
  }
  g_connected = true;
  return 0;
}

extern "C" __declspec(dllexport) int32_t lv_pad_update(int32_t index, uint16_t buttons, uint8_t lt,
                                                       uint8_t rt, int16_t lx, int16_t ly, int16_t rx,
                                                       int16_t ry) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_connected || index < 0 || index > 3) return -1;
  if (g_pads[index] == nullptr) {
    PVIGEM_TARGET pad = vigem_target_x360_alloc();
    if (pad == nullptr) return -2;
    if (!VIGEM_SUCCESS(vigem_target_add(g_client, pad))) {
      vigem_target_free(pad);
      return -3;
    }
    g_pads[index] = pad;
  }
  XUSB_REPORT report;
  ZeroMemory(&report, sizeof(report));
  report.wButtons = buttons;
  report.bLeftTrigger = lt;
  report.bRightTrigger = rt;
  report.sThumbLX = lx;
  report.sThumbLY = ly;
  report.sThumbRX = rx;
  report.sThumbRY = ry;
  return VIGEM_SUCCESS(vigem_target_x360_update(g_client, g_pads[index], report)) ? 0 : -4;
}

extern "C" __declspec(dllexport) void lv_pad_shutdown() {
  std::lock_guard<std::mutex> lock(g_mutex);
  for (auto& pad : g_pads) {
    if (pad != nullptr) {
      vigem_target_remove(g_client, pad);
      vigem_target_free(pad);
      pad = nullptr;
    }
  }
  if (g_client != nullptr) {
    if (g_connected) vigem_disconnect(g_client);
    vigem_free(g_client);
    g_client = nullptr;
  }
  g_connected = false;
}
