#include <cmath>

#include "devices.h"

vr::EVRInitError Hmd::Activate(uint32_t id) {
  id_ = id;
  auto props = vr::VRProperties();
  auto c = props->TrackedDeviceToPropertyContainer(id);
  props->SetStringProperty(c, vr::Prop_TrackingSystemName_String, "localview");
  props->SetStringProperty(c, vr::Prop_ModelNumber_String, ("Localview · " + s_.deviceName).c_str());
  props->SetStringProperty(c, vr::Prop_ManufacturerName_String, "Localview");
  props->SetStringProperty(c, vr::Prop_SerialNumber_String, "LOCALVIEW-HMD");
  props->SetStringProperty(c, vr::Prop_RenderModelName_String, "generic_hmd");
  float ipd = std::fabs(s_.eyeToHead[1].px - s_.eyeToHead[0].px);
  props->SetFloatProperty(c, vr::Prop_UserIpdMeters_Float, ipd > 0.04f && ipd < 0.09f ? ipd : 0.064f);
  props->SetFloatProperty(c, vr::Prop_UserHeadToEyeDepthMeters_Float, 0.f);
  props->SetFloatProperty(c, vr::Prop_DisplayFrequency_Float, s_.refreshHz);
  props->SetFloatProperty(c, vr::Prop_SecondsFromVsyncToPhotons_Float, 0.005f);
  props->SetUint64Property(c, vr::Prop_GraphicsAdapterLuid_Uint64, comp_->AdapterLuid());
  props->SetBoolProperty(c, vr::Prop_IsOnDesktop_Bool, false);
  props->SetBoolProperty(c, vr::Prop_DisplayDebugMode_Bool, false);
  props->SetBoolProperty(c, vr::Prop_HasDisplayComponent_Bool, true);
  props->SetBoolProperty(c, vr::Prop_HasDriverDirectModeComponent_Bool, true);
  props->SetBoolProperty(c, vr::Prop_DriverDirectModeSendsVsyncEvents_Bool, true);
  props->SetStringProperty(c, vr::Prop_ExpectedControllerType_String, "oculus_touch");
  vr::VRServerDriverHost()->SetDisplayEyeToHead(id, PoseToMatrix(s_.eyeToHead[0]), PoseToMatrix(s_.eyeToHead[1]));

  pose_ = ToDriverPose({0, 1.6f, 0, 0, 0, 0, 1}, nullptr, nullptr, false);
  QueryPerformanceFrequency(&freq_);
  QueryPerformanceCounter(&nextVsync_);
  LvLog("headset active: %ux%u per eye @ %.0f Hz, %u Mbps", s_.eyeWidth, s_.eyeHeight, s_.refreshHz, s_.bitrateMbps);
  return vr::VRInitError_None;
}

void* Hmd::GetComponent(const char* name) {
  if (strcmp(name, vr::IVRDisplayComponent_Version) == 0) return static_cast<vr::IVRDisplayComponent*>(this);
  if (strcmp(name, vr::IVRDriverDirectModeComponent_Version) == 0) return static_cast<vr::IVRDriverDirectModeComponent*>(this);
  return nullptr;
}

vr::DriverPose_t Hmd::GetPose() {
  std::lock_guard<std::mutex> l(mutex_);
  return pose_;
}

void Hmd::GetWindowBounds(int32_t* x, int32_t* y, uint32_t* w, uint32_t* h) {
  *x = 0;
  *y = 0;
  *w = s_.eyeWidth * 2;
  *h = s_.eyeHeight;
}

void Hmd::GetRecommendedRenderTargetSize(uint32_t* w, uint32_t* h) {
  *w = s_.eyeWidth;
  *h = s_.eyeHeight;
}

void Hmd::GetEyeOutputViewport(vr::EVREye eye, uint32_t* x, uint32_t* y, uint32_t* w, uint32_t* h) {
  *x = eye == vr::Eye_Left ? 0 : s_.eyeWidth;
  *y = 0;
  *w = s_.eyeWidth;
  *h = s_.eyeHeight;
}

void Hmd::GetProjectionRaw(vr::EVREye eye, float* l, float* r, float* t, float* b) {
  const lvvr::Fov& f = s_.fov[eye == vr::Eye_Left ? 0 : 1];
  *l = std::tan(f.left);
  *r = std::tan(f.right);
  *t = -std::tan(f.up);  // OpenVR: top is negative (y down)
  *b = -std::tan(f.down);
}

vr::DistortionCoordinates_t Hmd::ComputeDistortion(vr::EVREye, float u, float v) {
  // The headset's own compositor applies lens distortion; the stream is undistorted.
  vr::DistortionCoordinates_t d;
  d.rfRed[0] = d.rfGreen[0] = d.rfBlue[0] = u;
  d.rfRed[1] = d.rfGreen[1] = d.rfBlue[1] = v;
  return d;
}

bool Hmd::ComputeInverseDistortion(vr::HmdVector2_t* out, vr::EVREye, uint32_t, float u, float v) {
  out->v[0] = u;
  out->v[1] = v;
  return true;
}

void Hmd::OnTracking(const lvvr::TrackingPayload& t) {
  std::lock_guard<std::mutex> l(mutex_);
  pose_ = ToDriverPose(t.head, t.headLinVel, t.headAngVel, true);
  hist_[histPos_++ % hist_.size()] = {t.timestampNs, t.head};
  if (id_ != vr::k_unTrackedDeviceIndexInvalid)
    vr::VRServerDriverHost()->TrackedDevicePoseUpdated(id_, pose_, sizeof pose_);
}

void Hmd::SetConnected(bool c) {
  std::lock_guard<std::mutex> l(mutex_);
  connected_ = c;
  if (!c) {
    pose_.poseIsValid = false;
    pose_.result = vr::TrackingResult_Running_OutOfRange;
    if (id_ != vr::k_unTrackedDeviceIndexInvalid)
      vr::VRServerDriverHost()->TrackedDevicePoseUpdated(id_, pose_, sizeof pose_);
  }
}

void Hmd::Present(vr::SharedTextureHandle_t sync) {
  ID3D11Texture2D* nv12 = nullptr;
  vr::HmdMatrix34_t m;
  if (!comp_->Present(sync, s_.eyeWidth, s_.eyeHeight, &nv12, &m)) return;
  // Which tracking sample did SteamVR render this frame with? Match the pose.
  Hist best{};
  {
    std::lock_guard<std::mutex> l(mutex_);
    float bestErr = 1e9f;
    for (const Hist& h : hist_) {
      if (h.ts == 0) continue;
      vr::HmdMatrix34_t hm = PoseToMatrix(h.pose);
      float err = 0;
      for (int r = 0; r < 3; r++)
        for (int c = 0; c < 4; c++) err += std::fabs(hm.m[r][c] - m.m[r][c]);
      if (err < bestErr) {
        bestErr = err;
        best = h;
      }
    }
    if (best.ts == 0) {  // nothing matched: use the matrix itself
      best.pose = {m.m[0][3], m.m[1][3], m.m[2][3], 0, 0, 0, 1};
    }
    frames_[++frameIndex_] = best;
    while (frames_.size() > 16) frames_.erase(frames_.begin());
  }
  enc_->Submit(comp_->Context(), nv12, frameIndex_);
}

bool Hmd::TakeFrameInfo(uint64_t frameIndex, uint64_t* ts, lvvr::Pose* head) {
  std::lock_guard<std::mutex> l(mutex_);
  auto it = frames_.find(frameIndex);
  if (it == frames_.end()) return false;
  *ts = it->second.ts;
  *head = it->second.pose;
  frames_.erase(it);
  return true;
}

void Hmd::PostPresent(const Throttling_t*) {
  // Simulated display vsync at the headset refresh rate.
  const LONGLONG period = LONGLONG(freq_.QuadPart / s_.refreshHz);
  LARGE_INTEGER now;
  QueryPerformanceCounter(&now);
  if (now.QuadPart > nextVsync_.QuadPart + period) nextVsync_.QuadPart = now.QuadPart;  // fell behind: resync
  nextVsync_.QuadPart += period;
  for (;;) {
    QueryPerformanceCounter(&now);
    LONGLONG left = nextVsync_.QuadPart - now.QuadPart;
    if (left <= 0) break;
    double ms = double(left) * 1000.0 / double(freq_.QuadPart);
    if (ms > 1.5) Sleep(DWORD(ms - 1)); else YieldProcessor();
  }
  vr::VRServerDriverHost()->VsyncEvent(0);
}
