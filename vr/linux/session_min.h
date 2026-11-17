// Minimal reader for the Localview PC VR session file, shared by the capture
// layer and the DRM-lease shim (which only need the stream size and refresh rate).
#pragma once
#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <string>

namespace lvsession {

inline std::string Path() {
  if (const char* p = getenv("LOCALVIEW_VR_SESSION"); p && *p) return p;
  const char* home = getenv("HOME");
  return std::string(home ? home : "") + "/.config/localview/vr_session.txt";
}

struct Display {
  uint32_t eyeWidth = 1832, eyeHeight = 1920;
  float refresh = 90.f;
  bool loaded = false;
};

// Same clamping as the driver (vr/driver/src/session.cpp), so both agree on the frame size.
inline Display Load() {
  Display d;
  std::ifstream f(Path());
  std::string line;
  while (std::getline(f, line)) {
    auto eq = line.find('=');
    if (eq == std::string::npos) continue;
    std::string k = line.substr(0, eq), v = line.substr(eq + 1);
    try {
      if (k == "eye_width") d.eyeWidth = std::stoul(v), d.loaded = true;
      else if (k == "eye_height") d.eyeHeight = std::stoul(v);
      else if (k == "refresh") d.refresh = std::stof(v);
    } catch (...) {}
  }
  d.eyeWidth = (std::min<uint32_t>(d.eyeWidth, 2048) + 15) & ~15u;
  d.eyeHeight = (std::min<uint32_t>(d.eyeHeight, 2304) + 15) & ~15u;
  if (d.refresh < 30 || d.refresh > 144) d.refresh = 90;
  return d;
}

}  // namespace lvsession
