// Localview: settings come from the PC VR session file written by the Localview app.
#include "settings.h"

#include "session_min.h"
#include "util/logger.h"

Settings Settings::m_Instance;

Settings::Settings() : m_loaded(false) {}

Settings::~Settings() {}

void Settings::Load() {
  auto d = lvsession::Load();
  m_renderWidth = d.eyeWidth * 2;
  m_renderHeight = d.eyeHeight;
  m_refreshRate = int(d.refresh + 0.5f);
  m_loaded = d.loaded;
  Info("Localview capture layer: %ux%u @ %d Hz\n", m_renderWidth, m_renderHeight, m_refreshRate);
}
