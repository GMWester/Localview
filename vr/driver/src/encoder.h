#pragma once
#include <d3d11.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <wrl/client.h>

#include <atomic>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

// Hardware H.264 encoder (Media Foundation async MFT on the GPU vendor's encoder).
class Encoder {
 public:
  using Output = std::function<void(const uint8_t* data, size_t size, bool keyframe, uint64_t userData)>;
  bool Init(ID3D11Device* device, uint32_t width, uint32_t height, float fps, uint32_t bitrateMbps, Output out);
  // Copies `nv12` into an internal slot and queues it. Returns false (frame dropped) when the encoder is behind.
  bool Submit(ID3D11DeviceContext* ctx, ID3D11Texture2D* nv12, uint64_t userData);
  void ForceKeyframe() { forceKey_ = true; }
  void Shutdown();

 private:
  void Loop();
  bool FeedOne();
  void DrainOne();
  bool Configure();

  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<IMFDXGIDeviceManager> manager_;
  UINT resetToken_ = 0;
  Microsoft::WRL::ComPtr<IMFTransform> mft_;
  Microsoft::WRL::ComPtr<IMFMediaEventGenerator> events_;
  Microsoft::WRL::ComPtr<ICodecAPI> codec_;
  std::vector<Microsoft::WRL::ComPtr<ID3D11Texture2D>> slots_;
  std::vector<uint8_t> sequenceHeader_;
  uint32_t width_ = 0, height_ = 0, bitrate_ = 0;
  float fps_ = 90;
  Output out_;
  std::mutex mutex_;
  std::deque<std::pair<int, uint64_t>> queued_;  // slot, userData waiting for NeedInput
  std::deque<uint64_t> inFlight_;                // userData submitted to the MFT, in order
  int nextSlot_ = 0;
  int needInput_ = 0;
  int64_t sampleTime_ = 0;
  std::atomic<bool> forceKey_{false};
  std::atomic<bool> running_{false};
  std::thread thread_;
};
