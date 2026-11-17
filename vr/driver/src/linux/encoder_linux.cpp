#include "encoder_linux.h"

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>

#include "../common.h"

extern char** environ;

namespace {

std::string FindFfmpeg() {
  std::vector<std::string> c;
  if (const char* e = getenv("LOCALVIEW_FFMPEG"); e && *e) c.push_back(e);
  c.insert(c.end(), {"/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/bin/ffmpeg"});
  // User installs (SteamOS has a read-only system: put a static ffmpeg build in one of these).
  if (const char* home = getenv("HOME")) {
    c.push_back(std::string(home) + "/.local/share/localview/ffmpeg/ffmpeg");
    c.push_back(std::string(home) + "/.local/bin/ffmpeg");
  }
  c.push_back("/run/host/usr/bin/ffmpeg");
  if (const char* path = getenv("PATH")) {
    std::string p = path;
    size_t start = 0;
    while (start <= p.size()) {
      size_t end = p.find(':', start);
      if (end == std::string::npos) end = p.size();
      if (end > start) c.push_back(p.substr(start, end - start) + "/ffmpeg");
      start = end + 1;
    }
  }
  for (auto& f : c) {
    if (access(f.c_str(), X_OK) == 0) return f;
  }
  return {};
}

// SteamVR runs the driver with the Steam runtime's library path; the system
// ffmpeg must not inherit it.
std::vector<std::string> CleanEnv() {
  std::vector<std::string> env;
  for (char** e = environ; e && *e; e++) {
    std::string kv = *e;
    if (kv.rfind("LD_LIBRARY_PATH=", 0) == 0 || kv.rfind("LD_PRELOAD=", 0) == 0) continue;
    env.push_back(kv);
  }
  return env;
}

bool WriteAll(int fd, const uint8_t* p, size_t n) {
  while (n > 0) {
    ssize_t w = write(fd, p, n);
    if (w < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    p += w;
    n -= size_t(w);
  }
  return true;
}

}  // namespace

bool LinuxEncoder::Spawn(const std::vector<std::string>& args, pid_t* pid, int* in, int* out, bool quiet) {
  int inPipe[2], outPipe[2];
  if (pipe2(inPipe, O_CLOEXEC) != 0) return false;
  if (pipe2(outPipe, O_CLOEXEC) != 0) {
    close(inPipe[0]);
    close(inPipe[1]);
    return false;
  }
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, inPipe[0], 0);
  posix_spawn_file_actions_adddup2(&fa, outPipe[1], 1);
  if (quiet) posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
  std::vector<char*> argv;
  for (auto& a : args) argv.push_back(const_cast<char*>(a.c_str()));
  argv.push_back(nullptr);
  auto envs = CleanEnv();
  std::vector<char*> envp;
  for (auto& e : envs) envp.push_back(const_cast<char*>(e.c_str()));
  envp.push_back(nullptr);
  int rc = posix_spawn(pid, ffmpeg_.c_str(), &fa, nullptr, argv.data(), envp.data());
  posix_spawn_file_actions_destroy(&fa);
  close(inPipe[0]);
  close(outPipe[1]);
  if (rc != 0) {
    close(inPipe[1]);
    close(outPipe[0]);
    return false;
  }
  *in = inPipe[1];
  *out = outPipe[0];
  return true;
}

std::vector<std::string> LinuxEncoder::Args(const std::string& codec, bool probe) const {
  const std::string size = std::to_string(probe ? 256 : width_) + "x" + std::to_string(probe ? 256 : height_);
  const std::string rate = std::to_string(int(fps_ + 0.5f));
  const std::string mbps = std::to_string(bitrate_ / 1000000u) + "M";
  const std::string buf = std::to_string(std::max<uint32_t>(1, bitrate_ / 1000000u / uint32_t(fps_ / 2))) + "M";
  std::vector<std::string> a = {ffmpeg_, "-hide_banner", "-loglevel", "error"};
  if (codec == "h264_vaapi") a.insert(a.end(), {"-vaapi_device", gpu_.renderNode.empty() ? "/dev/dri/renderD128" : gpu_.renderNode});
  if (probe) {
    a.insert(a.end(), {"-f", "lavfi", "-i", "color=c=gray:s=" + size + ":r=" + rate, "-frames:v", "3", "-pix_fmt", "nv12"});
  } else {
    a.insert(a.end(), {"-probesize", "32", "-analyzeduration", "0", "-f", "rawvideo", "-pix_fmt", "nv12", "-video_size", size, "-framerate", rate, "-i", "pipe:0"});
  }
  if (codec == "h264_nvenc") {
    a.insert(a.end(), {"-c:v", "h264_nvenc", "-preset", "p1", "-tune", "ull", "-zerolatency", "1", "-delay", "0",
                       "-rc", "cbr", "-forced-idr", "1", "-profile:v", "high"});
  } else if (codec == "h264_vaapi") {
    a.insert(a.end(), {"-vf", "format=nv12,hwupload", "-c:v", "h264_vaapi", "-rc_mode", "CBR", "-profile:v", "high"});
  } else {
    a.insert(a.end(), {"-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-threads", "0"});
  }
  // A keyframe every second lets the headset recover from lost packets.
  // Never drop or duplicate frames: every input frame is one output frame, in order
  // (frame metadata is matched by position).
  a.insert(a.end(), {syncOption_, "passthrough"});
  a.insert(a.end(), {"-b:v", mbps, "-maxrate", mbps, "-bufsize", buf, "-g", rate, "-bf", "0", "-flags", "+low_delay",
                     "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv"});
  if (probe) {
    a.insert(a.end(), {"-f", "null", "-"});
  } else {
    a.insert(a.end(), {"-bsf:v", "h264_metadata=aud=insert", "-flush_packets", "1", "-f", "h264", "pipe:1"});
  }
  return a;
}

bool LinuxEncoder::Init(const Gpu& gpu, uint32_t width, uint32_t height, float fps, uint32_t bitrateMbps, Output out) {
  gpu_ = gpu;
  width_ = width;
  height_ = height;
  fps_ = fps;
  bitrate_ = bitrateMbps * 1000000u;
  out_ = std::move(out);
  signal(SIGPIPE, SIG_IGN);
  ffmpeg_ = FindFfmpeg();
  if (ffmpeg_.empty()) {
    LvLog("ffmpeg was not found. Install it (e.g. 'sudo apt install ffmpeg' / 'sudo dnf install ffmpeg-free'), then start PC VR again.");
    return false;
  }
  std::vector<std::string> order;
  if (gpu_.vendorId == 0x10de) order = {"h264_nvenc", "h264_vaapi", "libx264"};
  else order = {"h264_vaapi", "h264_nvenc", "libx264"};
  // -fps_mode needs ffmpeg 5.1+; older versions only know -vsync.
  for (const char* sync : {"-fps_mode", "-vsync"}) {
    syncOption_ = sync;
    for (auto& codec : order) {
      pid_t pid;
      int in, o;
      if (!Spawn(Args(codec, true), &pid, &in, &o, true)) continue;
      close(in);
      close(o);
      int status = 0;
      waitpid(pid, &status, 0);
      if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        name_ = codec;
        break;
      }
      LvLog("encoder %s is not available on this PC (%s)", codec.c_str(), sync);
    }
    if (!name_.empty()) break;
  }
  if (name_.empty()) {
    LvLog("no working H.264 encoder: ffmpeg needs NVENC (NVIDIA), VA-API H.264 encoding (AMD/Intel) or libx264");
    return false;
  }
  if (!Spawn(Args(name_, false), &pid_, &stdin_, &stdout_, false)) {
    LvLog("could not start ffmpeg (%s)", ffmpeg_.c_str());
    return false;
  }
  fcntl(stdin_, F_SETPIPE_SZ, 1 << 20);
  fcntl(stdout_, F_SETPIPE_SZ, 1 << 20);
  running_ = true;
  reader_ = std::thread([this] { ReadLoop(); });
  LvLog("encoding with %s via %s (%ux%u @ %.0f Hz, %u Mbps)", name_.c_str(), ffmpeg_.c_str(), width_, height_, fps_, bitrateMbps);
  return true;
}

bool LinuxEncoder::Submit(const uint8_t* nv12, size_t size, uint64_t userData) {
  if (!running_) return false;
  {
    std::lock_guard<std::mutex> l(mutex_);
    pending_.push_back(userData);
    while (pending_.size() > 64) pending_.pop_front();
  }
  if (!WriteAll(stdin_, nv12, size)) {
    LvLog("the encoder stopped");
    running_ = false;
    return false;
  }
  return true;
}

void LinuxEncoder::EmitFrame(const std::vector<uint8_t>& au) {
  if (au.empty()) return;
  bool key = false, hasSlice = false;
  for (size_t i = 0; i + 3 < au.size(); i++) {
    if (au[i] == 0 && au[i + 1] == 0 && au[i + 2] == 1) {
      int t = au[i + 3] & 0x1f;
      if (t == 5) key = true;
      if (t == 1 || t == 5) hasSlice = true;
    }
  }
  if (!hasSlice) return;
  uint64_t user = 0;
  {
    std::lock_guard<std::mutex> l(mutex_);
    if (!pending_.empty()) {
      user = pending_.front();
      pending_.pop_front();
    }
  }
  out_(au.data(), au.size(), key, user);
}

// Splits ffmpeg's Annex-B stream into access units. Each one starts with an access
// unit delimiter; a unit is complete when the next delimiter arrives or, to avoid a
// frame of extra latency, when ffmpeg goes quiet for 2 ms after writing it.
void LinuxEncoder::ReadLoop() {
  std::vector<uint8_t> buf, au;
  buf.reserve(4 << 20);
  uint8_t chunk[1 << 16];
  auto isAud = [&](size_t i) {
    return i + 4 < buf.size() && buf[i] == 0 && buf[i + 1] == 0 &&
           ((buf[i + 2] == 1 && (buf[i + 3] & 0x1f) == 9) ||
            (buf[i + 2] == 0 && buf[i + 3] == 1 && (buf[i + 4] & 0x1f) == 9));
  };
  while (running_) {
    pollfd pfd{stdout_, POLLIN, 0};
    int ready = poll(&pfd, 1, buf.empty() ? 200 : 2);
    if (ready == 0) {
      if (!buf.empty() && isAud(0)) {
        EmitFrame(buf);
        buf.clear();
      }
      continue;
    }
    if (ready < 0) {
      if (errno == EINTR) continue;
      break;
    }
    ssize_t n = read(stdout_, chunk, sizeof chunk);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) break;
    size_t scanFrom = buf.size() > 4 ? buf.size() - 4 : 0;
    buf.insert(buf.end(), chunk, chunk + n);
    size_t start = 0;
    for (size_t i = std::max<size_t>(scanFrom, 1); i + 4 < buf.size(); i++) {
      if (isAud(i)) {
        au.assign(buf.begin() + long(start), buf.begin() + long(i));
        EmitFrame(au);
        start = i;
      }
    }
    if (start > 0) buf.erase(buf.begin(), buf.begin() + long(start));
  }
  running_ = false;
}

void LinuxEncoder::Shutdown() {
  running_ = false;
  if (stdin_ >= 0) close(stdin_);
  stdin_ = -1;
  if (pid_ > 0) {
    kill(pid_, SIGTERM);
    waitpid(pid_, nullptr, 0);
    pid_ = -1;
  }
  if (reader_.joinable()) reader_.join();
  if (stdout_ >= 0) close(stdout_);
  stdout_ = -1;
}
