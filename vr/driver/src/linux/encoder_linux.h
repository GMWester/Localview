#pragma once
// H.264 encoder for the Linux driver: feeds NV12 frames to an ffmpeg process
// (NVENC on NVIDIA, VA-API on AMD/Intel incl. Steam Deck, x264 as a last resort)
// and splits its Annex-B output back into frames. Using the ffmpeg program keeps
// the driver independent of the distro's libavcodec version.
#include <sys/types.h>

#include <atomic>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

class LinuxEncoder {
 public:
  using Output = std::function<void(const uint8_t* data, size_t size, bool keyframe, uint64_t userData)>;
  struct Gpu {
    uint32_t vendorId = 0;     // PCI vendor (0x10de NVIDIA, 0x1002 AMD, 0x8086 Intel)
    std::string renderNode;    // e.g. /dev/dri/renderD128
  };
  bool Init(const Gpu& gpu, uint32_t width, uint32_t height, float fps, uint32_t bitrateMbps, Output out);
  // Blocks while the encoder is busy (natural back-pressure). Returns false if ffmpeg died.
  bool Submit(const uint8_t* nv12, size_t size, uint64_t userData);
  void Shutdown();
  const std::string& Name() const { return name_; }

 private:
  bool Spawn(const std::vector<std::string>& args, pid_t* pid, int* in, int* out, bool quiet);
  std::vector<std::string> Args(const std::string& codec, bool probe) const;
  void ReadLoop();
  void EmitFrame(const std::vector<uint8_t>& au);

  Gpu gpu_;
  std::string ffmpeg_;
  std::string name_;
  std::string syncOption_ = "-fps_mode";
  uint32_t width_ = 0, height_ = 0, bitrate_ = 0;
  float fps_ = 90;
  Output out_;
  pid_t pid_ = -1;
  int stdin_ = -1, stdout_ = -1;
  std::thread reader_;
  std::atomic<bool> running_{false};
  std::mutex mutex_;
  std::deque<uint64_t> pending_;  // userData of frames written to ffmpeg, in order
};
