#pragma once
#include <array>
#include <atomic>
#include <map>
#include <memory>
#include <mutex>

#include "common.h"
#ifdef _WIN32
#include "compositor.h"
#include "encoder.h"
#endif
#include "network.h"
#include "session.h"

class Hmd;

class Controller : public vr::ITrackedDeviceServerDriver {
 public:
  Controller(int hand, float pitchDeg) : hand_(hand), pitchDeg_(pitchDeg) {}
  vr::EVRInitError Activate(uint32_t id) override;
  void Deactivate() override { id_ = vr::k_unTrackedDeviceIndexInvalid; }
  void EnterStandby() override {}
  void* GetComponent(const char*) override { return nullptr; }
  void DebugRequest(const char*, char* buf, uint32_t n) override { if (n) buf[0] = 0; }
  vr::DriverPose_t GetPose() override;
  void Update(const lvvr::ControllerState& s);
  void Disconnect();
  vr::PropertyContainerHandle_t Container() const { return container_; }
  int Hand() const { return hand_; }
  const char* Serial() const { return hand_ == 0 ? "LOCALVIEW-CTRL-L" : "LOCALVIEW-CTRL-R"; }

 private:
  enum { kA, kATouch, kB, kBTouch, kSystem, kTrigClick, kTrigTouch, kStickClick, kStickTouch, kThumbrest, kGripTouch, kGripClick, kBoolCount };
  enum { kTrigValue, kGripValue, kStickX, kStickY, kScalarCount };
  int hand_;
  float pitchDeg_;
  uint32_t id_ = vr::k_unTrackedDeviceIndexInvalid;
  vr::PropertyContainerHandle_t container_ = 0;
  std::array<vr::VRInputComponentHandle_t, kBoolCount> bools_{};
  std::array<vr::VRInputComponentHandle_t, kScalarCount> scalars_{};
  vr::VRInputComponentHandle_t haptic_ = 0;
  std::mutex mutex_;
  vr::DriverPose_t pose_{};
};

// Windows: SteamVR's compositor hands frames to the driver (IVRDriverDirectModeComponent, D3D11).
// Linux: the compositor renders to a virtual display provided by the Localview capture
// layer, which passes the frames to the driver's LinuxStreamer (capture_linux.cpp).
class Hmd : public vr::ITrackedDeviceServerDriver,
#ifdef _WIN32
            public vr::IVRDriverDirectModeComponent,
#endif
            public vr::IVRDisplayComponent {
 public:
#ifdef _WIN32
  Hmd(const VrSession& s, Compositor* c, Encoder* e) : s_(s), comp_(c), enc_(e) {}
#else
  explicit Hmd(const VrSession& s) : s_(s) {}
#endif
  // ITrackedDeviceServerDriver
  vr::EVRInitError Activate(uint32_t id) override;
  void Deactivate() override { id_ = vr::k_unTrackedDeviceIndexInvalid; }
  void EnterStandby() override {}
  void* GetComponent(const char* name) override;
  void DebugRequest(const char*, char* buf, uint32_t n) override { if (n) buf[0] = 0; }
  vr::DriverPose_t GetPose() override;
  // IVRDisplayComponent
  void GetWindowBounds(int32_t* x, int32_t* y, uint32_t* w, uint32_t* h) override;
  bool IsDisplayOnDesktop() override { return false; }
#ifdef _WIN32
  bool IsDisplayRealDisplay() override { return false; }
#else
  // On Linux the compositor drives a (virtual) display in direct mode.
  bool IsDisplayRealDisplay() override { return true; }
#endif
  void GetRecommendedRenderTargetSize(uint32_t* w, uint32_t* h) override;
  void GetEyeOutputViewport(vr::EVREye eye, uint32_t* x, uint32_t* y, uint32_t* w, uint32_t* h) override;
  void GetProjectionRaw(vr::EVREye eye, float* l, float* r, float* t, float* b) override;
  vr::DistortionCoordinates_t ComputeDistortion(vr::EVREye eye, float u, float v) override;
  bool ComputeInverseDistortion(vr::HmdVector2_t* out, vr::EVREye eye, uint32_t ch, float u, float v) override;
#ifdef _WIN32
  // IVRDriverDirectModeComponent
  void CreateSwapTextureSet(uint32_t pid, const SwapTextureSetDesc_t* d, SwapTextureSet_t* o) override { comp_->CreateSwapTextureSet(pid, d, o); }
  void DestroySwapTextureSet(vr::SharedTextureHandle_t h) override { comp_->DestroySwapTextureSet(h); }
  void DestroyAllSwapTextureSets(uint32_t pid) override { comp_->DestroyAllSwapTextureSets(pid); }
  void GetNextSwapTextureSetIndex(vr::SharedTextureHandle_t h[2], uint32_t (*i)[2]) override { comp_->GetNextSwapTextureSetIndex(h, i); }
  void SubmitLayer(const SubmitLayerPerEye_t (&perEye)[2]) override { comp_->SubmitLayer(perEye); }
  void Present(vr::SharedTextureHandle_t sync) override;
  void PostPresent(const Throttling_t*) override;
#endif

  void OnTracking(const lvvr::TrackingPayload& t);
  void SetConnected(bool c);
  // Remembers which tracking sample SteamVR rendered a frame with (matched by its head pose
  // matrix) and returns the frame index to pass through the encoder.
  uint64_t RecordFrame(const vr::HmdMatrix34_t& renderPose);
  // Frame metadata for the encoder callback.
  bool TakeFrameInfo(uint64_t frameIndex, uint64_t* ts, lvvr::Pose* head);

 private:
  struct Hist {
    uint64_t ts;
    lvvr::Pose pose;
  };
  VrSession s_;
#ifdef _WIN32
  Compositor* comp_;
  Encoder* enc_;
  LARGE_INTEGER freq_{}, nextVsync_{};
#endif
  uint32_t id_ = vr::k_unTrackedDeviceIndexInvalid;
  std::mutex mutex_;
  vr::DriverPose_t pose_{};
  std::array<Hist, 128> hist_{};
  size_t histPos_ = 0;
  std::map<uint64_t, Hist> frames_;
  uint64_t frameIndex_ = 0;
  bool connected_ = false;
};
