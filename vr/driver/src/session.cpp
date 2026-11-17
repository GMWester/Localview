#include "session.h"

#ifdef _WIN32
#include <windows.h>
#include <shlobj.h>
#endif

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>

std::filesystem::path SessionPath() {
#ifdef _WIN32
  PWSTR p = nullptr;
  std::wstring out;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &p))) {
    out = std::wstring(p) + L"\\Localview\\vr_session.txt";
  }
  CoTaskMemFree(p);
  return out;
#else
  if (const char* p = getenv("LOCALVIEW_VR_SESSION"); p && *p) return p;
  const char* home = getenv("HOME");
  return std::filesystem::path(home ? home : "") / ".config/localview/vr_session.txt";
#endif
}

static int HexVal(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

bool LoadSession(VrSession* s) {
  std::ifstream f{SessionPath()};
  if (!f) return false;
  bool haveKey = false;
  std::string line;
  while (std::getline(f, line)) {
    auto eq = line.find('=');
    if (eq == std::string::npos) continue;
    std::string k = line.substr(0, eq), v = line.substr(eq + 1);
    while (!v.empty() && (v.back() == '\r' || v.back() == ' ')) v.pop_back();
    std::istringstream in(v);
    try {
    if (k == "id") s->id = v;
    else if (k == "key" && v.size() == 64) {
      haveKey = true;
      for (int i = 0; i < 32; i++) {
        int a = HexVal(v[2 * i]), b = HexVal(v[2 * i + 1]);
        if (a < 0 || b < 0) { haveKey = false; break; }
        s->key[i] = uint8_t(a * 16 + b);
      }
    }
    else if (k == "port") s->port = uint16_t(std::stoi(v));
    else if (k == "eye_width") s->eyeWidth = std::stoul(v);
    else if (k == "eye_height") s->eyeHeight = std::stoul(v);
    else if (k == "refresh") s->refreshHz = std::stof(v);
    else if (k == "bitrate") s->bitrateMbps = std::stoul(v);
    else if (k == "controller_pitch") s->controllerPitchDeg = std::stof(v);
    else if (k == "name") s->deviceName = v;
    else if (k == "fov_l" || k == "fov_r") {
      lvvr::Fov& fv = s->fov[k == "fov_r"];
      in >> fv.left >> fv.right >> fv.up >> fv.down;
    } else if (k == "eye_l" || k == "eye_r") {
      lvvr::Pose& p = s->eyeToHead[k == "eye_r"];
      in >> p.px >> p.py >> p.pz >> p.qx >> p.qy >> p.qz >> p.qw;
    }
    } catch (...) {
      // Malformed value: keep the default.
    }
  }
  // Keep dimensions encoder friendly (multiple of 16, SBS width <= 4096 for H.264).
  s->eyeWidth = (std::min<uint32_t>(s->eyeWidth, 2048) + 15) & ~15u;
  s->eyeHeight = (std::min<uint32_t>(s->eyeHeight, 2304) + 15) & ~15u;
  if (s->refreshHz < 30 || s->refreshHz > 144) s->refreshHz = 90;
  return haveKey;
}
