// Localview VR: native OpenXR client that plays SteamVR streamed from a PC
// running the Localview SteamVR driver. Runs on Meta Quest (Horizon OS) and
// Android XR headsets.
//
// Pipeline: UDP (ChaCha20-Poly1305) -> frame reassembly -> MediaCodec (H.264,
// hardware) -> AImageReader -> EGLImage (external OES texture) -> per-eye blit
// into OpenXR swapchains -> projection layer submitted with the exact eye poses
// the PC rendered with, so the runtime's reprojection hides network latency.
#include <android/log.h>
#include <android/native_window.h>
#include <android_native_app_glue.h>
#include <jni.h>
#include <media/NdkImageReader.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>

#define XR_USE_PLATFORM_ANDROID
#define XR_USE_GRAPHICS_API_OPENGL_ES
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "vrproto.h"

#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "LocalviewVR", __VA_ARGS__)
#define CHECK_XR(x)                                       \
  do {                                                    \
    XrResult r_ = (x);                                    \
    if (XR_FAILED(r_)) {                                  \
      LOG("%s failed: %d (line %d)", #x, r_, __LINE__);   \
      return false;                                       \
    }                                                     \
  } while (0)

namespace {

// ------------------------------------------------------------------ connection params from Java
std::mutex g_connMutex;
std::string g_host;
int g_port = 0;
uint8_t g_key[32];
std::atomic<bool> g_connectRequested{false};

int HexVal(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

int64_t NowNs() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

struct FrameMeta {
  uint64_t trackingTs;
  lvvr::Pose head;
};

struct ViewSnapshot {
  XrView views[2];
};

class VrApp {
 public:
  explicit VrApp(android_app* app) : app_(app) {}
  void Run();

 private:
  // --- setup
  bool InitXr();
  bool InitEgl();
  bool InitSession();
  bool InitActions();
  bool InitSwapchains();
  bool InitGl();
  bool InitDecoder();
  void Shutdown();
  // --- loop
  void PollEvents(bool* exit);
  void Frame();
  void SendTracking(XrTime t, const XrView views[2], const XrSpaceLocation& head, const XrSpaceVelocity& headVel);
  void ReportDisplayInfo(XrTime t);
  void StartNetwork();
  void NetLoop();
  void DecodeLoop();
  void OutputLoop();
  bool LatchVideo();
  void ApplyHaptics();
  // --- java
  void CallJava(const char* method, const char* json);

  android_app* app_;
  JNIEnv* env_ = nullptr;

  XrInstance instance_ = XR_NULL_HANDLE;
  XrSystemId system_ = XR_NULL_SYSTEM_ID;
  XrSession session_ = XR_NULL_HANDLE;
  XrSessionState state_ = XR_SESSION_STATE_UNKNOWN;
  bool running_ = false;
  XrSpace stage_ = XR_NULL_HANDLE, view_ = XR_NULL_HANDLE;
  XrViewConfigurationView viewConfig_[2]{};
  XrSwapchain swapchain_[2]{};
  std::vector<XrSwapchainImageOpenGLESKHR> images_[2];
  bool srgbSwapchain_ = false;
  bool refreshExt_ = false;
  float refreshHz_ = 90.f;
  uint32_t eyeW_ = 0, eyeH_ = 0;

  XrActionSet actionSet_ = XR_NULL_HANDLE;
  XrAction gripPose_, trigger_, squeeze_, stick_, stickClick_, stickTouch_, triggerTouch_, thumbrest_;
  XrAction btnA_, btnB_, btnX_, btnY_, touchA_, touchB_, touchX_, touchY_, menu_, haptic_;
  XrPath handPath_[2]{};
  XrSpace gripSpace_[2]{};

  EGLDisplay egl_ = EGL_NO_DISPLAY;
  EGLConfig eglConfig_ = nullptr;
  EGLContext eglCtx_ = EGL_NO_CONTEXT;
  EGLSurface eglSurf_ = EGL_NO_SURFACE;
  GLuint program_ = 0, fbo_ = 0, vao_ = 0, videoTex_ = 0;
  GLint regionLoc_ = -1, srgbLoc_ = -1;
  PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC getNativeClientBuffer_ = nullptr;
  PFNEGLCREATEIMAGEKHRPROC createImage_ = nullptr;
  PFNEGLDESTROYIMAGEKHRPROC destroyImage_ = nullptr;
  PFNGLEGLIMAGETARGETTEXTURE2DOESPROC imageTargetTexture_ = nullptr;

  AMediaCodec* codec_ = nullptr;
  AImageReader* reader_ = nullptr;
  AImage* currentImage_ = nullptr;
  EGLImageKHR currentEglImage_ = EGL_NO_IMAGE_KHR;
  bool haveVideo_ = false;
  FrameMeta currentMeta_{};

  // network
  int sock_ = -1;
  sockaddr_storage pcAddr_{};
  socklen_t pcAddrLen_ = 0;
  lvvr::SecureLink link_;
  std::atomic<bool> netRunning_{false};
  std::atomic<bool> gotVideo_{false};
  std::thread netThread_, decodeThread_, outputThread_;
  std::mutex frameMutex_;
  std::condition_variable frameCv_;
  std::deque<lvvr::Frame> frames_;
  std::mutex metaMutex_;
  std::map<int64_t, FrameMeta> meta_;
  std::mutex viewMutex_;
  std::map<uint64_t, ViewSnapshot> viewHistory_;
  std::mutex hapticMutex_;
  std::vector<lvvr::HapticPayload> haptics_;
  int64_t lastIdrNs_ = 0;
  int64_t lastHelloNs_ = 0;
  bool displayReported_ = false;
  lvvr::HelloPayload hello_{};
  int64_t menuDownSince_ = 0;
};

void VrApp::CallJava(const char* method, const char* json) {
  if (!env_) return;
  jobject act = app_->activity->clazz;
  jclass cls = env_->GetObjectClass(act);
  jmethodID m = env_->GetMethodID(cls, method, "(Ljava/lang/String;)V");
  if (m) {
    jstring s = env_->NewStringUTF(json ? json : "");
    env_->CallVoidMethod(act, m, s);
    env_->DeleteLocalRef(s);
  }
  if (env_->ExceptionCheck()) env_->ExceptionClear();
  env_->DeleteLocalRef(cls);
}

bool VrApp::InitXr() {
  PFN_xrInitializeLoaderKHR initLoader = nullptr;
  if (XR_SUCCEEDED(xrGetInstanceProcAddr(XR_NULL_HANDLE, "xrInitializeLoaderKHR",
                                         reinterpret_cast<PFN_xrVoidFunction*>(&initLoader))) && initLoader) {
    XrLoaderInitInfoAndroidKHR li{XR_TYPE_LOADER_INIT_INFO_ANDROID_KHR};
    li.applicationVM = app_->activity->vm;
    li.applicationContext = app_->activity->clazz;
    initLoader(reinterpret_cast<const XrLoaderInitInfoBaseHeaderKHR*>(&li));
  }
  uint32_t n = 0;
  xrEnumerateInstanceExtensionProperties(nullptr, 0, &n, nullptr);
  std::vector<XrExtensionProperties> exts(n, {XR_TYPE_EXTENSION_PROPERTIES});
  xrEnumerateInstanceExtensionProperties(nullptr, n, &n, exts.data());
  std::vector<const char*> enable = {XR_KHR_ANDROID_CREATE_INSTANCE_EXTENSION_NAME, XR_KHR_OPENGL_ES_ENABLE_EXTENSION_NAME};
  for (auto& e : exts) {
    if (strcmp(e.extensionName, XR_FB_DISPLAY_REFRESH_RATE_EXTENSION_NAME) == 0) {
      refreshExt_ = true;
      enable.push_back(XR_FB_DISPLAY_REFRESH_RATE_EXTENSION_NAME);
    }
  }
  XrInstanceCreateInfoAndroidKHR ai{XR_TYPE_INSTANCE_CREATE_INFO_ANDROID_KHR};
  ai.applicationVM = app_->activity->vm;
  ai.applicationActivity = app_->activity->clazz;
  XrInstanceCreateInfo ci{XR_TYPE_INSTANCE_CREATE_INFO};
  ci.next = &ai;
  strcpy(ci.applicationInfo.applicationName, "Localview VR");
  ci.applicationInfo.applicationVersion = 1;
  strcpy(ci.applicationInfo.engineName, "Localview");
  ci.applicationInfo.apiVersion = XR_API_VERSION_1_0;
  ci.enabledExtensionCount = uint32_t(enable.size());
  ci.enabledExtensionNames = enable.data();
  CHECK_XR(xrCreateInstance(&ci, &instance_));
  XrSystemGetInfo sg{XR_TYPE_SYSTEM_GET_INFO};
  sg.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
  CHECK_XR(xrGetSystem(instance_, &sg, &system_));
  uint32_t vc = 0;
  CHECK_XR(xrEnumerateViewConfigurationViews(instance_, system_, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 0, &vc, nullptr));
  if (vc != 2) return false;
  viewConfig_[0] = viewConfig_[1] = {XR_TYPE_VIEW_CONFIGURATION_VIEW};
  CHECK_XR(xrEnumerateViewConfigurationViews(instance_, system_, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 2, &vc, viewConfig_));
  // Stream resolution: the headset's recommended size, capped so the side-by-side
  // frame stays within H.264 limits (4096 wide), rounded to 16.
  uint32_t rw = viewConfig_[0].recommendedImageRectWidth, rh = viewConfig_[0].recommendedImageRectHeight;
  eyeW_ = std::min<uint32_t>(rw, 2048) & ~15u;
  eyeH_ = uint32_t(float(rh) * float(eyeW_) / float(rw)) & ~15u;
  LOG("recommended %ux%u -> streaming %ux%u per eye", rw, rh, eyeW_, eyeH_);
  return true;
}

bool VrApp::InitEgl() {
  egl_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  eglInitialize(egl_, nullptr, nullptr);
  const EGLint attrs[] = {EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
                          EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE};
  EGLint num = 0;
  if (!eglChooseConfig(egl_, attrs, &eglConfig_, 1, &num) || num == 0) return false;
  const EGLint ctxAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
  eglCtx_ = eglCreateContext(egl_, eglConfig_, EGL_NO_CONTEXT, ctxAttrs);
  const EGLint pb[] = {EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE};
  eglSurf_ = eglCreatePbufferSurface(egl_, eglConfig_, pb);
  if (!eglMakeCurrent(egl_, eglSurf_, eglSurf_, eglCtx_)) return false;
  getNativeClientBuffer_ = reinterpret_cast<PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(eglGetProcAddress("eglGetNativeClientBufferANDROID"));
  createImage_ = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
  destroyImage_ = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
  imageTargetTexture_ = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
  return getNativeClientBuffer_ && createImage_ && destroyImage_ && imageTargetTexture_;
}

bool VrApp::InitSession() {
  PFN_xrGetOpenGLESGraphicsRequirementsKHR getReq = nullptr;
  CHECK_XR(xrGetInstanceProcAddr(instance_, "xrGetOpenGLESGraphicsRequirementsKHR",
                                 reinterpret_cast<PFN_xrVoidFunction*>(&getReq)));
  XrGraphicsRequirementsOpenGLESKHR req{XR_TYPE_GRAPHICS_REQUIREMENTS_OPENGL_ES_KHR};
  CHECK_XR(getReq(instance_, system_, &req));
  XrGraphicsBindingOpenGLESAndroidKHR gb{XR_TYPE_GRAPHICS_BINDING_OPENGL_ES_ANDROID_KHR};
  gb.display = egl_;
  gb.config = eglConfig_;
  gb.context = eglCtx_;
  XrSessionCreateInfo sc{XR_TYPE_SESSION_CREATE_INFO};
  sc.next = &gb;
  sc.systemId = system_;
  CHECK_XR(xrCreateSession(instance_, &sc, &session_));

  uint32_t n = 0;
  xrEnumerateReferenceSpaces(session_, 0, &n, nullptr);
  std::vector<XrReferenceSpaceType> types(n);
  xrEnumerateReferenceSpaces(session_, n, &n, types.data());
  bool hasStage = false;
  for (auto t : types) hasStage |= t == XR_REFERENCE_SPACE_TYPE_STAGE;
  XrReferenceSpaceCreateInfo rs{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
  rs.poseInReferenceSpace.orientation.w = 1;
  rs.referenceSpaceType = hasStage ? XR_REFERENCE_SPACE_TYPE_STAGE : XR_REFERENCE_SPACE_TYPE_LOCAL;
  if (!hasStage) rs.poseInReferenceSpace.position.y = -1.6f;  // approximate standing height
  CHECK_XR(xrCreateReferenceSpace(session_, &rs, &stage_));
  rs.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
  rs.poseInReferenceSpace.position.y = 0;
  CHECK_XR(xrCreateReferenceSpace(session_, &rs, &view_));
  return true;
}

bool VrApp::InitActions() {
  XrActionSetCreateInfo as{XR_TYPE_ACTION_SET_CREATE_INFO};
  strcpy(as.actionSetName, "localview");
  strcpy(as.localizedActionSetName, "Localview");
  CHECK_XR(xrCreateActionSet(instance_, &as, &actionSet_));
  xrStringToPath(instance_, "/user/hand/left", &handPath_[0]);
  xrStringToPath(instance_, "/user/hand/right", &handPath_[1]);
  auto mk = [&](XrAction* a, const char* name, XrActionType type, bool both) {
    XrActionCreateInfo ai{XR_TYPE_ACTION_CREATE_INFO};
    ai.actionType = type;
    strcpy(ai.actionName, name);
    strcpy(ai.localizedActionName, name);
    if (both) {
      ai.countSubactionPaths = 2;
      ai.subactionPaths = handPath_;
    }
    return XR_SUCCEEDED(xrCreateAction(actionSet_, &ai, a));
  };
  bool ok = mk(&gripPose_, "grip", XR_ACTION_TYPE_POSE_INPUT, true) && mk(&trigger_, "trigger", XR_ACTION_TYPE_FLOAT_INPUT, true) &&
            mk(&squeeze_, "squeeze", XR_ACTION_TYPE_FLOAT_INPUT, true) && mk(&stick_, "stick", XR_ACTION_TYPE_VECTOR2F_INPUT, true) &&
            mk(&stickClick_, "stick_click", XR_ACTION_TYPE_BOOLEAN_INPUT, true) &&
            mk(&stickTouch_, "stick_touch", XR_ACTION_TYPE_BOOLEAN_INPUT, true) &&
            mk(&triggerTouch_, "trigger_touch", XR_ACTION_TYPE_BOOLEAN_INPUT, true) &&
            mk(&thumbrest_, "thumbrest", XR_ACTION_TYPE_BOOLEAN_INPUT, true) && mk(&btnA_, "a", XR_ACTION_TYPE_BOOLEAN_INPUT, false) &&
            mk(&btnB_, "b", XR_ACTION_TYPE_BOOLEAN_INPUT, false) && mk(&btnX_, "x", XR_ACTION_TYPE_BOOLEAN_INPUT, false) &&
            mk(&btnY_, "y", XR_ACTION_TYPE_BOOLEAN_INPUT, false) && mk(&touchA_, "a_touch", XR_ACTION_TYPE_BOOLEAN_INPUT, false) &&
            mk(&touchB_, "b_touch", XR_ACTION_TYPE_BOOLEAN_INPUT, false) && mk(&touchX_, "x_touch", XR_ACTION_TYPE_BOOLEAN_INPUT, false) &&
            mk(&touchY_, "y_touch", XR_ACTION_TYPE_BOOLEAN_INPUT, false) && mk(&menu_, "menu", XR_ACTION_TYPE_BOOLEAN_INPUT, false) &&
            mk(&haptic_, "haptic", XR_ACTION_TYPE_VIBRATION_OUTPUT, true);
  if (!ok) return false;

  auto suggest = [&](const char* profile, std::vector<std::pair<XrAction, const char*>> b) {
    XrPath prof;
    xrStringToPath(instance_, profile, &prof);
    std::vector<XrActionSuggestedBinding> s;
    for (auto& [a, p] : b) {
      XrPath path;
      xrStringToPath(instance_, p, &path);
      s.push_back({a, path});
    }
    XrInteractionProfileSuggestedBinding sb{XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING};
    sb.interactionProfile = prof;
    sb.countSuggestedBindings = uint32_t(s.size());
    sb.suggestedBindings = s.data();
    XrResult r = xrSuggestInteractionProfileBindings(instance_, &sb);
    LOG("bindings %s: %d", profile, r);
  };
  suggest("/interaction_profiles/oculus/touch_controller",
          {{gripPose_, "/user/hand/left/input/grip/pose"}, {gripPose_, "/user/hand/right/input/grip/pose"},
           {trigger_, "/user/hand/left/input/trigger/value"}, {trigger_, "/user/hand/right/input/trigger/value"},
           {triggerTouch_, "/user/hand/left/input/trigger/touch"}, {triggerTouch_, "/user/hand/right/input/trigger/touch"},
           {squeeze_, "/user/hand/left/input/squeeze/value"}, {squeeze_, "/user/hand/right/input/squeeze/value"},
           {stick_, "/user/hand/left/input/thumbstick"}, {stick_, "/user/hand/right/input/thumbstick"},
           {stickClick_, "/user/hand/left/input/thumbstick/click"}, {stickClick_, "/user/hand/right/input/thumbstick/click"},
           {stickTouch_, "/user/hand/left/input/thumbstick/touch"}, {stickTouch_, "/user/hand/right/input/thumbstick/touch"},
           {thumbrest_, "/user/hand/left/input/thumbrest/touch"}, {thumbrest_, "/user/hand/right/input/thumbrest/touch"},
           {btnX_, "/user/hand/left/input/x/click"}, {btnY_, "/user/hand/left/input/y/click"},
           {touchX_, "/user/hand/left/input/x/touch"}, {touchY_, "/user/hand/left/input/y/touch"},
           {btnA_, "/user/hand/right/input/a/click"}, {btnB_, "/user/hand/right/input/b/click"},
           {touchA_, "/user/hand/right/input/a/touch"}, {touchB_, "/user/hand/right/input/b/touch"},
           {menu_, "/user/hand/left/input/menu/click"},
           {haptic_, "/user/hand/left/output/haptic"}, {haptic_, "/user/hand/right/output/haptic"}});
  suggest("/interaction_profiles/khr/simple_controller",
          {{gripPose_, "/user/hand/left/input/grip/pose"}, {gripPose_, "/user/hand/right/input/grip/pose"},
           {trigger_, "/user/hand/left/input/select/click"}, {trigger_, "/user/hand/right/input/select/click"},
           {menu_, "/user/hand/left/input/menu/click"},
           {haptic_, "/user/hand/left/output/haptic"}, {haptic_, "/user/hand/right/output/haptic"}});

  for (int h = 0; h < 2; h++) {
    XrActionSpaceCreateInfo sc{XR_TYPE_ACTION_SPACE_CREATE_INFO};
    sc.action = gripPose_;
    sc.subactionPath = handPath_[h];
    sc.poseInActionSpace.orientation.w = 1;
    CHECK_XR(xrCreateActionSpace(session_, &sc, &gripSpace_[h]));
  }
  XrSessionActionSetsAttachInfo at{XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO};
  at.countActionSets = 1;
  at.actionSets = &actionSet_;
  CHECK_XR(xrAttachSessionActionSets(session_, &at));
  return true;
}

bool VrApp::InitSwapchains() {
  uint32_t n = 0;
  xrEnumerateSwapchainFormats(session_, 0, &n, nullptr);
  std::vector<int64_t> fmts(n);
  xrEnumerateSwapchainFormats(session_, n, &n, fmts.data());
  int64_t fmt = GL_RGBA8;
  for (auto f : fmts) {
    if (f == GL_SRGB8_ALPHA8) {
      fmt = f;
      srgbSwapchain_ = true;
    }
  }
  for (int e = 0; e < 2; e++) {
    XrSwapchainCreateInfo ci{XR_TYPE_SWAPCHAIN_CREATE_INFO};
    ci.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
    ci.format = fmt;
    ci.sampleCount = 1;
    ci.width = eyeW_;
    ci.height = eyeH_;
    ci.faceCount = 1;
    ci.arraySize = 1;
    ci.mipCount = 1;
    CHECK_XR(xrCreateSwapchain(session_, &ci, &swapchain_[e]));
    uint32_t count = 0;
    xrEnumerateSwapchainImages(swapchain_[e], 0, &count, nullptr);
    images_[e].assign(count, {XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_ES_KHR});
    CHECK_XR(xrEnumerateSwapchainImages(swapchain_[e], count, &count,
                                        reinterpret_cast<XrSwapchainImageBaseHeader*>(images_[e].data())));
  }
  if (refreshExt_) {
    PFN_xrEnumerateDisplayRefreshRatesFB enumRates = nullptr;
    PFN_xrRequestDisplayRefreshRateFB request = nullptr;
    PFN_xrGetDisplayRefreshRateFB get = nullptr;
    xrGetInstanceProcAddr(instance_, "xrEnumerateDisplayRefreshRatesFB", reinterpret_cast<PFN_xrVoidFunction*>(&enumRates));
    xrGetInstanceProcAddr(instance_, "xrRequestDisplayRefreshRateFB", reinterpret_cast<PFN_xrVoidFunction*>(&request));
    xrGetInstanceProcAddr(instance_, "xrGetDisplayRefreshRateFB", reinterpret_cast<PFN_xrVoidFunction*>(&get));
    if (enumRates && request) {
      uint32_t rc = 0;
      enumRates(session_, 0, &rc, nullptr);
      std::vector<float> rates(rc);
      enumRates(session_, rc, &rc, rates.data());
      float best = 0;
      for (float r : rates)
        if (r <= 90.5f && r > best) best = r;  // 90 Hz: good balance of smoothness and bitrate
      if (best > 0) request(session_, best);
    }
    if (get) get(session_, &refreshHz_);
  }
  return true;
}

bool VrApp::InitGl() {
  const char* vs = R"(#version 300 es
uniform vec4 region;
out vec2 uv;
void main() {
  vec2 t = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(t * 2.0 - 1.0, 0.0, 1.0);
  uv = vec2(mix(region.x, region.z, t.x), mix(region.w, region.y, t.y));
})";
  const char* fs = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;
uniform samplerExternalOES tex;
uniform int srgbTarget;
in vec2 uv;
out vec4 color;
void main() {
  vec3 c = texture(tex, uv).rgb;
  if (srgbTarget == 1) c = mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
  color = vec4(c, 1.0);
})";
  auto compile = [](GLenum type, const char* src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, nullptr);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
      char log[1024];
      glGetShaderInfoLog(s, sizeof log, nullptr, log);
      LOG("shader: %s", log);
    }
    return s;
  };
  program_ = glCreateProgram();
  glAttachShader(program_, compile(GL_VERTEX_SHADER, vs));
  glAttachShader(program_, compile(GL_FRAGMENT_SHADER, fs));
  glLinkProgram(program_);
  regionLoc_ = glGetUniformLocation(program_, "region");
  srgbLoc_ = glGetUniformLocation(program_, "srgbTarget");
  glGenFramebuffers(1, &fbo_);
  glGenVertexArrays(1, &vao_);
  glGenTextures(1, &videoTex_);
  glBindTexture(GL_TEXTURE_EXTERNAL_OES, videoTex_);
  glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  return true;
}

bool VrApp::InitDecoder() {
  const int32_t w = int32_t(eyeW_ * 2), h = int32_t(eyeH_);
  if (AImageReader_newWithUsage(w, h, AIMAGE_FORMAT_PRIVATE, AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE, 4, &reader_) != AMEDIA_OK)
    return false;
  ANativeWindow* window = nullptr;
  AImageReader_getWindow(reader_, &window);
  codec_ = AMediaCodec_createDecoderByType("video/avc");
  if (!codec_) return false;
  AMediaFormat* f = AMediaFormat_new();
  AMediaFormat_setString(f, AMEDIAFORMAT_KEY_MIME, "video/avc");
  AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_WIDTH, w);
  AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_HEIGHT, h);
  AMediaFormat_setInt32(f, "low-latency", 1);
  AMediaFormat_setInt32(f, "vendor.qti-ext-dec-low-latency.enable", 1);
  AMediaFormat_setInt32(f, "vendor.qti-ext-dec-picture-order.enable", 1);
  AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_PRIORITY, 0);
  AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_OPERATING_RATE, 1000);
  media_status_t st = AMediaCodec_configure(codec_, f, window, nullptr, 0);
  AMediaFormat_delete(f);
  if (st != AMEDIA_OK) return false;
  return AMediaCodec_start(codec_) == AMEDIA_OK;
}

void VrApp::ReportDisplayInfo(XrTime t) {
  if (displayReported_) return;
  XrViewLocateInfo li{XR_TYPE_VIEW_LOCATE_INFO};
  li.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
  li.displayTime = t;
  li.space = view_;
  XrViewState vs{XR_TYPE_VIEW_STATE};
  XrView views[2] = {{XR_TYPE_VIEW}, {XR_TYPE_VIEW}};
  uint32_t n = 0;
  if (XR_FAILED(xrLocateViews(session_, &li, &vs, 2, &n, views)) || !(vs.viewStateFlags & XR_VIEW_STATE_POSITION_VALID_BIT)) return;
  hello_.version = lvvr::kProtocolVersion;
  hello_.eyeWidth = eyeW_;
  hello_.eyeHeight = eyeH_;
  hello_.refreshHz = refreshHz_;
  for (int e = 0; e < 2; e++) {
    hello_.fov[e] = {views[e].fov.angleLeft, views[e].fov.angleRight, views[e].fov.angleUp, views[e].fov.angleDown};
    const auto& p = views[e].pose;
    hello_.eyeToHead[e] = {p.position.x, p.position.y, p.position.z, p.orientation.x, p.orientation.y, p.orientation.z,
                           p.orientation.w};
  }
  XrSystemProperties sp{XR_TYPE_SYSTEM_PROPERTIES};
  xrGetSystemProperties(instance_, system_, &sp);
  snprintf(hello_.deviceName, sizeof hello_.deviceName, "%s", sp.systemName);
  char json[1024];
  auto& L = hello_.fov[0];
  auto& R = hello_.fov[1];
  auto& el = hello_.eyeToHead[0];
  auto& er = hello_.eyeToHead[1];
  snprintf(json, sizeof json,
           "{\"eyeWidth\":%u,\"eyeHeight\":%u,\"refresh\":%.2f,\"name\":\"%s\","
           "\"fovL\":[%.5f,%.5f,%.5f,%.5f],\"fovR\":[%.5f,%.5f,%.5f,%.5f],"
           "\"eyeL\":[%.5f,%.5f,%.5f,%.6f,%.6f,%.6f,%.6f],\"eyeR\":[%.5f,%.5f,%.5f,%.6f,%.6f,%.6f,%.6f]}",
           eyeW_, eyeH_, refreshHz_, hello_.deviceName, L.left, L.right, L.up, L.down, R.left, R.right, R.up, R.down, el.px,
           el.py, el.pz, el.qx, el.qy, el.qz, el.qw, er.px, er.py, er.pz, er.qx, er.qy, er.qz, er.qw);
  displayReported_ = true;
  LOG("display info: %s", json);
  CallJava("onDisplayInfo", json);
}

void VrApp::StartNetwork() {
  std::string host;
  int port;
  uint8_t key[32];
  {
    std::lock_guard<std::mutex> l(g_connMutex);
    host = g_host;
    port = g_port;
    memcpy(key, g_key, 32);
  }
  addrinfo hints{}, *res = nullptr;
  hints.ai_socktype = SOCK_DGRAM;
  if (getaddrinfo(host.c_str(), std::to_string(port).c_str(), &hints, &res) != 0 || !res) {
    LOG("cannot resolve %s", host.c_str());
    return;
  }
  sock_ = socket(res->ai_family, SOCK_DGRAM, IPPROTO_UDP);
  memcpy(&pcAddr_, res->ai_addr, res->ai_addrlen);
  pcAddrLen_ = socklen_t(res->ai_addrlen);
  freeaddrinfo(res);
  int buf = 8 << 20;
  setsockopt(sock_, SOL_SOCKET, SO_RCVBUF, &buf, sizeof buf);
  timeval tv{0, 100000};
  setsockopt(sock_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  link_.reset(key, false);
  netRunning_ = true;
  netThread_ = std::thread([this] { NetLoop(); });
  decodeThread_ = std::thread([this] { DecodeLoop(); });
  outputThread_ = std::thread([this] { OutputLoop(); });
  LOG("streaming from %s:%d", host.c_str(), port);
}

void VrApp::NetLoop() {
  lvvr::Reassembler reasm;
  uint8_t buf[2048];
  while (netRunning_) {
    ssize_t n = recv(sock_, buf, sizeof buf, 0);
    if (n <= 0) continue;
    uint8_t type;
    uint8_t* payload;
    size_t len;
    if (!link_.open(buf, size_t(n), &type, &payload, &len)) continue;
    if (type == lvvr::kVideo) {
      lvvr::Frame f;
      bool needIdr = false;
      if (reasm.add(payload, len, &f, &needIdr)) {
        gotVideo_ = true;
        std::lock_guard<std::mutex> l(frameMutex_);
        if (frames_.size() > 3) {  // decoder can't keep up: skip to the next keyframe
          frames_.clear();
          needIdr = true;
        } else {
          frames_.push_back(std::move(f));
          frameCv_.notify_one();
        }
      }
      int64_t now = NowNs();
      if (needIdr && now - lastIdrNs_ > 100000000) {
        lastIdrNs_ = now;
        uint8_t out[lvvr::kMaxDatagram];
        size_t m = link_.seal(lvvr::kIdrRequest, "", 0, out);
        sendto(sock_, out, m, 0, reinterpret_cast<sockaddr*>(&pcAddr_), pcAddrLen_);
      }
    } else if (type == lvvr::kHaptic && len >= sizeof(lvvr::HapticPayload)) {
      lvvr::HapticPayload h;
      memcpy(&h, payload, sizeof h);
      std::lock_guard<std::mutex> l(hapticMutex_);
      haptics_.push_back(h);
    }
  }
}

void VrApp::DecodeLoop() {
  while (netRunning_) {
    lvvr::Frame f;
    {
      std::unique_lock<std::mutex> l(frameMutex_);
      frameCv_.wait_for(l, std::chrono::milliseconds(50), [this] { return !frames_.empty() || !netRunning_; });
      if (frames_.empty()) continue;
      f = std::move(frames_.front());
      frames_.pop_front();
    }
    ssize_t idx = AMediaCodec_dequeueInputBuffer(codec_, 20000);
    if (idx < 0) continue;
    size_t cap = 0;
    uint8_t* in = AMediaCodec_getInputBuffer(codec_, size_t(idx), &cap);
    if (!in || cap < f.data.size()) {
      AMediaCodec_queueInputBuffer(codec_, size_t(idx), 0, 0, 0, 0);
      continue;
    }
    memcpy(in, f.data.data(), f.data.size());
    {
      std::lock_guard<std::mutex> l(metaMutex_);
      meta_[int64_t(f.index)] = {f.trackingTimestampNs, f.renderHead};
      while (meta_.size() > 32) meta_.erase(meta_.begin());
    }
    AMediaCodec_queueInputBuffer(codec_, size_t(idx), 0, f.data.size(), int64_t(f.index), 0);
  }
}

void VrApp::OutputLoop() {
  while (netRunning_) {
    AMediaCodecBufferInfo info;
    ssize_t idx = AMediaCodec_dequeueOutputBuffer(codec_, &info, 20000);
    if (idx >= 0) AMediaCodec_releaseOutputBuffer(codec_, size_t(idx), info.size > 0);  // render to the ImageReader
  }
}

bool VrApp::LatchVideo() {
  AImage* img = nullptr;
  if (AImageReader_acquireLatestImage(reader_, &img) != AMEDIA_OK || !img) return haveVideo_;
  AHardwareBuffer* hb = nullptr;
  AImage_getHardwareBuffer(img, &hb);
  EGLClientBuffer cb = getNativeClientBuffer_(hb);
  const EGLint attrs[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
  EGLImageKHR eimg = createImage_(egl_, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, cb, attrs);
  if (eimg == EGL_NO_IMAGE_KHR) {
    AImage_delete(img);
    return haveVideo_;
  }
  glBindTexture(GL_TEXTURE_EXTERNAL_OES, videoTex_);
  imageTargetTexture_(GL_TEXTURE_EXTERNAL_OES, eimg);
  if (currentEglImage_ != EGL_NO_IMAGE_KHR) destroyImage_(egl_, currentEglImage_);
  if (currentImage_) AImage_delete(currentImage_);
  currentImage_ = img;
  currentEglImage_ = eimg;
  int64_t ts = 0;
  AImage_getTimestamp(img, &ts);  // = presentation time (frame index) in ns
  int64_t index = ts / 1000;
  std::lock_guard<std::mutex> l(metaMutex_);
  auto it = meta_.find(index);
  if (it != meta_.end()) currentMeta_ = it->second;
  haveVideo_ = true;
  return true;
}

void VrApp::ApplyHaptics() {
  std::vector<lvvr::HapticPayload> hs;
  {
    std::lock_guard<std::mutex> l(hapticMutex_);
    hs.swap(haptics_);
  }
  for (auto& h : hs) {
    XrHapticVibration v{XR_TYPE_HAPTIC_VIBRATION};
    v.duration = XrDuration(std::max(0.01f, h.durationSeconds) * 1e9f);
    v.frequency = h.frequency > 0 ? h.frequency : XR_FREQUENCY_UNSPECIFIED;
    v.amplitude = std::min(1.f, std::max(0.f, h.amplitude));
    XrHapticActionInfo ai{XR_TYPE_HAPTIC_ACTION_INFO};
    ai.action = haptic_;
    ai.subactionPath = handPath_[h.hand & 1];
    xrApplyHapticFeedback(session_, &ai, reinterpret_cast<XrHapticBaseHeader*>(&v));
  }
}

void VrApp::SendTracking(XrTime t, const XrView views[2], const XrSpaceLocation& head, const XrSpaceVelocity& headVel) {
  lvvr::TrackingPayload tp{};
  tp.timestampNs = uint64_t(t);
  const auto& hp = head.pose;
  tp.head = {hp.position.x, hp.position.y, hp.position.z, hp.orientation.x, hp.orientation.y, hp.orientation.z, hp.orientation.w};
  if (headVel.velocityFlags & XR_SPACE_VELOCITY_LINEAR_VALID_BIT) {
    tp.headLinVel[0] = headVel.linearVelocity.x; tp.headLinVel[1] = headVel.linearVelocity.y; tp.headLinVel[2] = headVel.linearVelocity.z;
  }
  if (headVel.velocityFlags & XR_SPACE_VELOCITY_ANGULAR_VALID_BIT) {
    tp.headAngVel[0] = headVel.angularVelocity.x; tp.headAngVel[1] = headVel.angularVelocity.y; tp.headAngVel[2] = headVel.angularVelocity.z;
  }
  auto boolState = [&](XrAction a, XrPath sub) {
    XrActionStateGetInfo gi{XR_TYPE_ACTION_STATE_GET_INFO};
    gi.action = a;
    gi.subactionPath = sub;
    XrActionStateBoolean s{XR_TYPE_ACTION_STATE_BOOLEAN};
    return XR_SUCCEEDED(xrGetActionStateBoolean(session_, &gi, &s)) && s.isActive && s.currentState;
  };
  auto floatState = [&](XrAction a, XrPath sub) {
    XrActionStateGetInfo gi{XR_TYPE_ACTION_STATE_GET_INFO};
    gi.action = a;
    gi.subactionPath = sub;
    XrActionStateFloat s{XR_TYPE_ACTION_STATE_FLOAT};
    return XR_SUCCEEDED(xrGetActionStateFloat(session_, &gi, &s)) && s.isActive ? s.currentState : 0.f;
  };
  bool menuDown = false;
  for (int h = 0; h < 2; h++) {
    lvvr::ControllerState& c = tp.controller[h];
    c.hand = uint8_t(h);
    XrSpaceVelocity vel{XR_TYPE_SPACE_VELOCITY};
    XrSpaceLocation loc{XR_TYPE_SPACE_LOCATION, &vel};
    if (XR_SUCCEEDED(xrLocateSpace(gripSpace_[h], stage_, t, &loc)) &&
        (loc.locationFlags & XR_SPACE_LOCATION_ORIENTATION_VALID_BIT)) {
      const auto& p = loc.pose;
      c.active = 1;
      c.pose = {p.position.x, p.position.y, p.position.z, p.orientation.x, p.orientation.y, p.orientation.z, p.orientation.w};
      c.linVel[0] = vel.linearVelocity.x; c.linVel[1] = vel.linearVelocity.y; c.linVel[2] = vel.linearVelocity.z;
      c.angVel[0] = vel.angularVelocity.x; c.angVel[1] = vel.angularVelocity.y; c.angVel[2] = vel.angularVelocity.z;
    }
    XrPath sub = handPath_[h];
    c.trigger = floatState(trigger_, sub);
    c.grip = floatState(squeeze_, sub);
    XrActionStateGetInfo gi{XR_TYPE_ACTION_STATE_GET_INFO};
    gi.action = stick_;
    gi.subactionPath = sub;
    XrActionStateVector2f sv{XR_TYPE_ACTION_STATE_VECTOR2F};
    if (XR_SUCCEEDED(xrGetActionStateVector2f(session_, &gi, &sv)) && sv.isActive) {
      c.stickX = sv.currentState.x;
      c.stickY = sv.currentState.y;
    }
    uint32_t b = 0;
    if (boolState(stickClick_, sub)) b |= lvvr::kBtnStickClick;
    if (boolState(stickTouch_, sub)) b |= lvvr::kBtnStickTouch;
    if (boolState(triggerTouch_, sub)) b |= lvvr::kBtnTriggerTouch;
    if (boolState(thumbrest_, sub)) b |= lvvr::kBtnThumbrestTouch;
    if (h == 0) {
      if (boolState(btnX_, XR_NULL_PATH)) b |= lvvr::kBtnX;
      if (boolState(btnY_, XR_NULL_PATH)) b |= lvvr::kBtnY;
      if (boolState(touchX_, XR_NULL_PATH)) b |= lvvr::kBtnXTouch;
      if (boolState(touchY_, XR_NULL_PATH)) b |= lvvr::kBtnYTouch;
      if (boolState(menu_, XR_NULL_PATH)) {
        b |= lvvr::kBtnMenu;
        menuDown = true;
      }
    } else {
      if (boolState(btnA_, XR_NULL_PATH)) b |= lvvr::kBtnA;
      if (boolState(btnB_, XR_NULL_PATH)) b |= lvvr::kBtnB;
      if (boolState(touchA_, XR_NULL_PATH)) b |= lvvr::kBtnATouch;
      if (boolState(touchB_, XR_NULL_PATH)) b |= lvvr::kBtnBTouch;
    }
    c.buttons = b;
  }
  // Hold the left menu button for 3 seconds to leave PC VR.
  int64_t now = NowNs();
  if (menuDown) {
    if (menuDownSince_ == 0) menuDownSince_ = now;
    if (now - menuDownSince_ > 3000000000LL) ANativeActivity_finish(app_->activity);
  } else {
    menuDownSince_ = 0;
  }
  {
    std::lock_guard<std::mutex> l(viewMutex_);
    ViewSnapshot s;
    s.views[0] = views[0];
    s.views[1] = views[1];
    viewHistory_[uint64_t(t)] = s;
    while (viewHistory_.size() > 256) viewHistory_.erase(viewHistory_.begin());
  }
  if (sock_ < 0) return;
  uint8_t out[lvvr::kMaxDatagram];
  size_t m = link_.seal(lvvr::kTracking, &tp, sizeof tp, out);
  sendto(sock_, out, m, 0, reinterpret_cast<sockaddr*>(&pcAddr_), pcAddrLen_);
  if (!gotVideo_ && now - lastHelloNs_ > 500000000) {
    lastHelloNs_ = now;
    m = link_.seal(lvvr::kHello, &hello_, sizeof hello_, out);
    sendto(sock_, out, m, 0, reinterpret_cast<sockaddr*>(&pcAddr_), pcAddrLen_);
  }
}

void VrApp::Frame() {
  XrFrameWaitInfo wi{XR_TYPE_FRAME_WAIT_INFO};
  XrFrameState fs{XR_TYPE_FRAME_STATE};
  if (XR_FAILED(xrWaitFrame(session_, &wi, &fs))) return;
  XrFrameBeginInfo bi{XR_TYPE_FRAME_BEGIN_INFO};
  if (XR_FAILED(xrBeginFrame(session_, &bi))) return;

  ReportDisplayInfo(fs.predictedDisplayTime);
  if (g_connectRequested.exchange(false) && sock_ < 0 && InitDecoder()) StartNetwork();

  XrActiveActionSet aas{actionSet_, XR_NULL_PATH};
  XrActionsSyncInfo si{XR_TYPE_ACTIONS_SYNC_INFO};
  si.countActiveActionSets = 1;
  si.activeActionSets = &aas;
  xrSyncActions(session_, &si);
  ApplyHaptics();

  XrViewLocateInfo li{XR_TYPE_VIEW_LOCATE_INFO};
  li.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
  li.displayTime = fs.predictedDisplayTime;
  li.space = stage_;
  XrViewState vstate{XR_TYPE_VIEW_STATE};
  XrView views[2] = {{XR_TYPE_VIEW}, {XR_TYPE_VIEW}};
  uint32_t vn = 0;
  xrLocateViews(session_, &li, &vstate, 2, &vn, views);
  XrSpaceVelocity hv{XR_TYPE_SPACE_VELOCITY};
  XrSpaceLocation head{XR_TYPE_SPACE_LOCATION, &hv};
  xrLocateSpace(view_, stage_, fs.predictedDisplayTime, &head);
  if (head.locationFlags & XR_SPACE_LOCATION_ORIENTATION_VALID_BIT) SendTracking(fs.predictedDisplayTime, views, head, hv);

  std::vector<XrCompositionLayerBaseHeader*> layers;
  XrCompositionLayerProjection proj{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
  XrCompositionLayerProjectionView pv[2] = {{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}, {XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}};
  if (fs.shouldRender && sock_ >= 0 && LatchVideo()) {
    // The eye poses the PC rendered this frame with (falls back to the current pose).
    XrView frameViews[2] = {views[0], views[1]};
    {
      std::lock_guard<std::mutex> l(viewMutex_);
      auto it = viewHistory_.find(currentMeta_.trackingTs);
      if (it != viewHistory_.end()) {
        frameViews[0] = it->second.views[0];
        frameViews[1] = it->second.views[1];
      }
    }
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
    glUseProgram(program_);
    glBindVertexArray(vao_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, videoTex_);
    glUniform1i(srgbLoc_, srgbSwapchain_ ? 1 : 0);
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    for (int e = 0; e < 2; e++) {
      uint32_t ii = 0;
      XrSwapchainImageAcquireInfo ai{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
      xrAcquireSwapchainImage(swapchain_[e], &ai, &ii);
      XrSwapchainImageWaitInfo w{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
      w.timeout = XR_INFINITE_DURATION;
      xrWaitSwapchainImage(swapchain_[e], &w);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, images_[e][ii].image, 0);
      glViewport(0, 0, GLsizei(eyeW_), GLsizei(eyeH_));
      glUniform4f(regionLoc_, e == 0 ? 0.f : 0.5f, 0.f, e == 0 ? 0.5f : 1.f, 1.f);
      glDrawArrays(GL_TRIANGLES, 0, 3);
      XrSwapchainImageReleaseInfo ri{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
      xrReleaseSwapchainImage(swapchain_[e], &ri);
      pv[e].pose = frameViews[e].pose;
      pv[e].fov = frameViews[e].fov;
      pv[e].subImage.swapchain = swapchain_[e];
      pv[e].subImage.imageRect.offset = {0, 0};
      pv[e].subImage.imageRect.extent = {int32_t(eyeW_), int32_t(eyeH_)};
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    proj.space = stage_;
    proj.viewCount = 2;
    proj.views = pv;
    layers.push_back(reinterpret_cast<XrCompositionLayerBaseHeader*>(&proj));
  }
  XrFrameEndInfo ei{XR_TYPE_FRAME_END_INFO};
  ei.displayTime = fs.predictedDisplayTime;
  ei.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
  ei.layerCount = uint32_t(layers.size());
  ei.layers = layers.data();
  xrEndFrame(session_, &ei);
}

void VrApp::PollEvents(bool* exit) {
  XrEventDataBuffer ev{XR_TYPE_EVENT_DATA_BUFFER};
  while (xrPollEvent(instance_, &ev) == XR_SUCCESS) {
    if (ev.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
      auto* sc = reinterpret_cast<XrEventDataSessionStateChanged*>(&ev);
      state_ = sc->state;
      if (state_ == XR_SESSION_STATE_READY) {
        XrSessionBeginInfo b{XR_TYPE_SESSION_BEGIN_INFO};
        b.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
        running_ = XR_SUCCEEDED(xrBeginSession(session_, &b));
      } else if (state_ == XR_SESSION_STATE_STOPPING) {
        xrEndSession(session_);
        running_ = false;
      } else if (state_ == XR_SESSION_STATE_EXITING || state_ == XR_SESSION_STATE_LOSS_PENDING) {
        *exit = true;
      }
    } else if (ev.type == XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING) {
      *exit = true;
    }
    ev = {XR_TYPE_EVENT_DATA_BUFFER};
  }
}

void VrApp::Shutdown() {
  if (sock_ >= 0) {
    uint8_t out[lvvr::kMaxDatagram];
    size_t m = link_.seal(lvvr::kBye, "", 0, out);
    sendto(sock_, out, m, 0, reinterpret_cast<sockaddr*>(&pcAddr_), pcAddrLen_);
  }
  netRunning_ = false;
  frameCv_.notify_all();
  if (netThread_.joinable()) netThread_.join();
  if (decodeThread_.joinable()) decodeThread_.join();
  if (outputThread_.joinable()) outputThread_.join();
  if (sock_ >= 0) close(sock_);
  if (codec_) {
    AMediaCodec_stop(codec_);
    AMediaCodec_delete(codec_);
  }
  if (currentEglImage_ != EGL_NO_IMAGE_KHR) destroyImage_(egl_, currentEglImage_);
  if (currentImage_) AImage_delete(currentImage_);
  if (reader_) AImageReader_delete(reader_);
  for (auto& s : swapchain_)
    if (s) xrDestroySwapchain(s);
  if (session_) xrDestroySession(session_);
  if (instance_) xrDestroyInstance(instance_);
  CallJava("onVrEnded", "");
}

void VrApp::Run() {
  app_->activity->vm->AttachCurrentThread(&env_, nullptr);
  bool ok = InitXr() && InitEgl() && InitSession() && InitActions() && InitSwapchains() && InitGl();
  if (!ok) {
    LOG("OpenXR initialisation failed");
    CallJava("onVrError", "This headset's OpenXR runtime could not be started.");
    ANativeActivity_finish(app_->activity);
  }
  bool exit = false;
  while (!app_->destroyRequested) {
    int events;
    android_poll_source* src = nullptr;
    while (ALooper_pollOnce(running_ || !ok ? 0 : 100, nullptr, &events, reinterpret_cast<void**>(&src)) >= 0) {
      if (src) src->process(app_, src);
      if (app_->destroyRequested) break;
    }
    if (!ok) continue;
    PollEvents(&exit);
    if (exit) {
      ANativeActivity_finish(app_->activity);
      ok = false;
      continue;
    }
    if (running_) Frame();
  }
  if (ok || instance_) Shutdown();
  app_->activity->vm->DetachCurrentThread();
}

}  // namespace

extern "C" JNIEXPORT void JNICALL Java_io_localview_localview_VrActivity_nativeConnect(JNIEnv* env, jclass, jstring host,
                                                                                         jint port, jstring keyHex) {
  const char* h = env->GetStringUTFChars(host, nullptr);
  const char* k = env->GetStringUTFChars(keyHex, nullptr);
  {
    std::lock_guard<std::mutex> l(g_connMutex);
    g_host = h;
    g_port = port;
    for (int i = 0; i < 32 && k[2 * i] && k[2 * i + 1]; i++) g_key[i] = uint8_t(HexVal(k[2 * i]) * 16 + HexVal(k[2 * i + 1]));
  }
  env->ReleaseStringUTFChars(host, h);
  env->ReleaseStringUTFChars(keyHex, k);
  g_connectRequested = true;
}

void android_main(android_app* app) {
  VrApp vr(app);
  vr.Run();
}
