#pragma once
#include <cstdint>
#include <string>

#include "vrproto.h"

// Written by the Localview app (%LOCALAPPDATA%\Localview\vr_session.txt) before it starts SteamVR.
struct VrSession {
  std::string id;
  uint8_t key[32] = {};
  uint16_t port = lvvr::kDefaultPort;
  uint32_t eyeWidth = 1832, eyeHeight = 1920;
  float refreshHz = 90.f;
  uint32_t bitrateMbps = 100;
  lvvr::Fov fov[2] = {{-0.87f, 0.75f, 0.83f, -0.92f}, {-0.75f, 0.87f, 0.83f, -0.92f}};
  lvvr::Pose eyeToHead[2] = {{-0.032f, 0, 0, 0, 0, 0, 1}, {0.032f, 0, 0, 0, 0, 0, 1}};
  float controllerPitchDeg = 0.f;
  std::string deviceName = "Headset";
};

std::wstring SessionPath();
bool LoadSession(VrSession* out);
