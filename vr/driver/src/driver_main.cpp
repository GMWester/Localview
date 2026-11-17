// Localview SteamVR driver: streams SteamVR to a standalone headset running
// Localview (Meta Quest / Android XR) over an encrypted UDP link.
#include <chrono>
#include <memory>

#include "devices.h"
#ifndef _WIN32
#include "linux/capture_linux.h"
#endif

class DeviceProvider : public vr::IServerTrackedDeviceProvider {
 public:
  vr::EVRInitError Init(vr::IVRDriverContext* ctx) override {
    VR_INIT_SERVER_DRIVER_CONTEXT(ctx);
    if (!LoadSession(&session_)) {
      // No pending Localview VR session: let SteamVR use other headsets.
      return vr::VRInitError_Init_HmdNotFound;
    }
    auto onEncoded = [this](const uint8_t* d, size_t n, bool key, uint64_t frame) { OnEncoded(d, n, key, frame); };
#ifdef _WIN32
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (!comp_.Init()) return vr::VRInitError_Driver_Failed;
    hmd_ = std::make_unique<Hmd>(session_, &comp_, &enc_);
    if (!enc_.Init(comp_.Device(), session_.eyeWidth * 2, session_.eyeHeight, session_.refreshHz, session_.bitrateMbps,
                   onEncoded)) {
      return vr::VRInitError_Driver_Failed;
    }
#else
    hmd_ = std::make_unique<Hmd>(session_);
    // Frames arrive from the capture layer inside vrcompositor once it starts.
    if (!streamer_.Start(session_.eyeWidth * 2, session_.eyeHeight, session_.refreshHz, session_.bitrateMbps,
                         [this](const vr::HmdMatrix34_t& m) { return hmd_->RecordFrame(m); }, onEncoded)) {
      return vr::VRInitError_Driver_Failed;
    }
#endif
    ctrl_[0] = std::make_unique<Controller>(0, session_.controllerPitchDeg);
    ctrl_[1] = std::make_unique<Controller>(1, session_.controllerPitchDeg);
    if (!net_.Start(session_.port, session_.key, [this](uint8_t t, const uint8_t* p, size_t n) { OnPacket(t, p, n); })) {
      return vr::VRInitError_Driver_Failed;
    }
    vr::VRServerDriverHost()->TrackedDeviceAdded("LOCALVIEW-HMD", vr::TrackedDeviceClass_HMD, hmd_.get());
    vr::VRServerDriverHost()->TrackedDeviceAdded(ctrl_[0]->Serial(), vr::TrackedDeviceClass_Controller, ctrl_[0].get());
    vr::VRServerDriverHost()->TrackedDeviceAdded(ctrl_[1]->Serial(), vr::TrackedDeviceClass_Controller, ctrl_[1].get());
    return vr::VRInitError_None;
  }

  void Cleanup() override {
    net_.Stop();
#ifdef _WIN32
    enc_.Shutdown();
#else
    streamer_.Stop();
#endif
    VR_CLEANUP_SERVER_DRIVER_CONTEXT();
  }

  const char* const* GetInterfaceVersions() override { return vr::k_InterfaceVersions; }

  void RunFrame() override {
    vr::VREvent_t ev;
    while (vr::VRServerDriverHost()->PollNextEvent(&ev, sizeof ev)) {
      if (ev.eventType != vr::VREvent_Input_HapticVibration) continue;
      const auto& h = ev.data.hapticVibration;
      for (auto& c : ctrl_) {
        if (c && c->Container() == h.containerHandle) {
          lvvr::HapticPayload p{};
          p.hand = uint8_t(c->Hand());
          p.durationSeconds = h.fDurationSeconds;
          p.frequency = h.fFrequency;
          p.amplitude = h.fAmplitude;
          net_.Send(lvvr::kHaptic, &p, sizeof p);
        }
      }
    }
    auto now = std::chrono::steady_clock::now();
    if (connected_ && now - lastPacket_.load() > std::chrono::seconds(3)) {
      connected_ = false;
      hmd_->SetConnected(false);
      for (auto& c : ctrl_) c->Disconnect();
      LvLog("headset timed out");
    }
  }

  bool ShouldBlockStandbyMode() override { return false; }
  void EnterStandby() override {}
  void LeaveStandby() override {}

 private:
  void OnPacket(uint8_t type, const uint8_t* p, size_t n) {
    lastPacket_ = std::chrono::steady_clock::now();
    if (!connected_) {
      connected_ = true;
#ifdef _WIN32
      enc_.ForceKeyframe();
#endif
    }
    switch (type) {
      case lvvr::kTracking:
        if (n >= sizeof(lvvr::TrackingPayload)) {
          lvvr::TrackingPayload t;
          memcpy(&t, p, sizeof t);
          hmd_->OnTracking(t);
          for (int i = 0; i < 2; i++) ctrl_[t.controller[i].hand & 1]->Update(t.controller[i]);
        }
        break;
      case lvvr::kHello:
      case lvvr::kIdrRequest: {
        auto now = std::chrono::steady_clock::now();
        if (now - lastIdr_ > std::chrono::milliseconds(200)) {
          lastIdr_ = now;
#ifdef _WIN32
          enc_.ForceKeyframe();
#endif
          // Linux: the encoder sends a keyframe every second.
        }
        break;
      }
      case lvvr::kBye:
        connected_ = false;
        hmd_->SetConnected(false);
        for (auto& c : ctrl_) c->Disconnect();
        break;
    }
  }

  void OnEncoded(const uint8_t* d, size_t n, bool key, uint64_t frame) {
    uint64_t ts = 0;
    lvvr::Pose head{0, 0, 0, 0, 0, 0, 1};
    hmd_->TakeFrameInfo(frame, &ts, &head);
    for (auto& frag : lvvr::fragmentFrame(uint32_t(frame), d, n, key, ts, head)) {
      net_.Send(lvvr::kVideo, frag.data(), frag.size());
    }
  }

  VrSession session_;
#ifdef _WIN32
  Compositor comp_;
  Encoder enc_;
#else
  LinuxStreamer streamer_;
#endif
  Network net_;
  std::unique_ptr<Hmd> hmd_;
  std::unique_ptr<Controller> ctrl_[2];
  std::atomic<std::chrono::steady_clock::time_point> lastPacket_{};
  std::chrono::steady_clock::time_point lastIdr_{};
  std::atomic<bool> connected_{false};
};

static DeviceProvider g_provider;

#ifdef _WIN32
#define LV_EXPORT extern "C" __declspec(dllexport)
#else
#define LV_EXPORT extern "C" __attribute__((visibility("default")))
#endif

LV_EXPORT void* HmdDriverFactory(const char* name, int* ret) {
  if (strcmp(vr::IServerTrackedDeviceProvider_Version, name) == 0) return &g_provider;
  if (ret) *ret = vr::VRInitError_Init_InterfaceNotFound;
  return nullptr;
}
