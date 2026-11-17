#pragma once
#ifdef _WIN32
#include <windows.h>
#endif

#include <openvr_driver.h>

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <string>

#include "vrproto.h"

inline void LvLog(const char* fmt, ...) {
  char buf[1024];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
#ifndef LV_NO_STEAMVR
  if (vr::VRDriverLog()) vr::VRDriverLog()->Log((std::string("[localview] ") + buf).c_str());
#endif
  if (getenv("LOCALVIEW_VR_STDERR")) fprintf(stderr, "[localview] %s\n", buf);
}

// Headset pose -> OpenVR driver pose.
inline vr::DriverPose_t ToDriverPose(const lvvr::Pose& p, const float* lin, const float* ang, bool valid) {
  vr::DriverPose_t d = {};
  d.poseTimeOffset = 0;
  d.qWorldFromDriverRotation.w = 1;
  d.qDriverFromHeadRotation.w = 1;
  d.qRotation.w = p.qw;
  d.qRotation.x = p.qx;
  d.qRotation.y = p.qy;
  d.qRotation.z = p.qz;
  d.vecPosition[0] = p.px;
  d.vecPosition[1] = p.py;
  d.vecPosition[2] = p.pz;
  for (int i = 0; i < 3; i++) {
    d.vecVelocity[i] = lin ? lin[i] : 0;
    d.vecAngularVelocity[i] = ang ? ang[i] : 0;
  }
  d.result = valid ? vr::TrackingResult_Running_OK : vr::TrackingResult_Running_OutOfRange;
  d.poseIsValid = valid;
  d.deviceIsConnected = true;
  return d;
}

inline vr::HmdMatrix34_t PoseToMatrix(const lvvr::Pose& p) {
  const float x = p.qx, y = p.qy, z = p.qz, w = p.qw;
  vr::HmdMatrix34_t m;
  m.m[0][0] = 1 - 2 * (y * y + z * z); m.m[0][1] = 2 * (x * y - z * w);     m.m[0][2] = 2 * (x * z + y * w);     m.m[0][3] = p.px;
  m.m[1][0] = 2 * (x * y + z * w);     m.m[1][1] = 1 - 2 * (x * x + z * z); m.m[1][2] = 2 * (y * z - x * w);     m.m[1][3] = p.py;
  m.m[2][0] = 2 * (x * z - y * w);     m.m[2][1] = 2 * (y * z + x * w);     m.m[2][2] = 1 - 2 * (x * x + y * y); m.m[2][3] = p.pz;
  return m;
}
