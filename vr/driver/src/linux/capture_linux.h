#pragma once
// Linux frame path of the Localview SteamVR driver.
//
// SteamVR's compositor (vrcompositor) renders to a virtual headset display that the
// Localview capture layer (vr/linux/layer, based on ALVR's) provides. The layer shares
// its swapchain images (Vulkan memory + timeline semaphores as file descriptors) over
// a Unix socket and reports every present with the head pose it was rendered for.
// This class imports those images, converts each presented frame to NV12 on the GPU
// and feeds it to the H.264 encoder.
#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <thread>

#include <openvr_driver.h>

#include "encoder_linux.h"

class LinuxStreamer {
 public:
  using FrameRecorder = std::function<uint64_t(const vr::HmdMatrix34_t& renderPose)>;
  bool Start(uint32_t width, uint32_t height, float fps, uint32_t bitrateMbps, FrameRecorder recorder,
             LinuxEncoder::Output out);
  void Stop();

 private:
  void Run();
  int listen_ = -1;
  std::string socketPath_;
  uint32_t width_ = 0, height_ = 0, bitrate_ = 0;
  float fps_ = 90;
  FrameRecorder recorder_;
  LinuxEncoder::Output out_;
  std::thread thread_;
  std::atomic<bool> running_{false};
};
