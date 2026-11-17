// Localview VR streaming protocol (UDP), shared by the SteamVR driver (PC) and
// the OpenXR headset app. Every datagram is ChaCha20-Poly1305 sealed with a
// 256-bit key that the PC generates per session and delivers through the
// Localview end-to-end encrypted control channel.
//
// Datagram: [u8 type][u64 counter][payload...][16-byte tag]
//   AAD = type + counter, nonce = 4-byte direction prefix + counter.
// All multi-byte values are little-endian (x86-64 and ARM64 are both LE).
#pragma once
#include <atomic>
#include <cstdint>
#include <cstring>
#include <map>
#include <mutex>
#include <vector>

#include "chachapoly.h"

namespace lvvr {

constexpr uint32_t kProtocolVersion = 1;
constexpr uint16_t kDefaultPort = 47920;
constexpr size_t kMaxDatagram = 1400;
constexpr size_t kHeaderBytes = 9;
constexpr size_t kTagBytes = 16;
constexpr size_t kMaxPayload = kMaxDatagram - kHeaderBytes - kTagBytes;

enum PacketType : uint8_t {
  kHello = 1,       // headset -> PC: display description (repeated until video flows)
  kTracking = 2,    // headset -> PC: head + controllers, every headset frame
  kIdrRequest = 3,  // headset -> PC: decoder needs a keyframe
  kBye = 4,         // headset -> PC: session ended
  kVideo = 10,      // PC -> headset: encoded frame fragment
  kHaptic = 11,     // PC -> headset: controller vibration
  kStatus = 12,     // PC -> headset: streaming status text (UTF-8)
};

#pragma pack(push, 1)
struct Pose {
  float px, py, pz;
  float qx, qy, qz, qw;
};

struct Fov {  // radians, OpenXR convention (left/down negative)
  float left, right, up, down;
};

struct HelloPayload {
  uint32_t version;
  uint32_t eyeWidth, eyeHeight;  // per-eye video resolution requested
  float refreshHz;
  uint32_t bitrateMbps;
  Fov fov[2];
  Pose eyeToHead[2];
  char deviceName[48];
};

enum Buttons : uint32_t {
  kBtnA = 1u << 0, kBtnB = 1u << 1, kBtnX = 1u << 2, kBtnY = 1u << 3,
  kBtnMenu = 1u << 4, kBtnSystem = 1u << 5,
  kBtnStickClick = 1u << 6, kBtnStickTouch = 1u << 7,
  kBtnTriggerTouch = 1u << 8, kBtnThumbrestTouch = 1u << 9,
  kBtnATouch = 1u << 10, kBtnBTouch = 1u << 11, kBtnXTouch = 1u << 12, kBtnYTouch = 1u << 13,
};

struct ControllerState {
  uint8_t active;  // pose valid
  uint8_t hand;    // 0 left, 1 right
  uint16_t reserved;
  Pose pose;       // grip pose in stage space
  float linVel[3];
  float angVel[3];
  uint32_t buttons;
  float trigger, grip, stickX, stickY;
};

struct TrackingPayload {
  uint64_t timestampNs;  // headset predicted display time; echoed back in video frames
  Pose head;
  float headLinVel[3];
  float headAngVel[3];
  ControllerState controller[2];
};

enum VideoFlags : uint8_t { kVideoKeyframe = 1 };

struct VideoHeader {
  uint32_t frameIndex;
  uint16_t fragIndex, fragCount;
  uint32_t frameSize;
  uint8_t flags;
  uint8_t reserved[3];
  uint64_t trackingTimestampNs;  // pose the frame was rendered with
  Pose renderHead;               // the head pose itself (fallback if the timestamp is unknown)
};

struct HapticPayload {
  uint8_t hand;
  uint8_t reserved[3];
  float durationSeconds, frequency, amplitude;
};
#pragma pack(pop)

constexpr size_t kVideoChunk = kMaxPayload - sizeof(VideoHeader);

// Direction prefixes so both sides can share one key without nonce reuse.
constexpr uint32_t kPrefixPcToHeadset = 0x4c56504Bu;  // "KPVL"
constexpr uint32_t kPrefixHeadsetToPc = 0x4c56484Bu;  // "KHVL"

class SecureLink {
 public:
  void reset(const uint8_t key[32], bool isPc) {
    std::lock_guard<std::mutex> l(m_);
    memcpy(key_, key, 32);
    sendPrefix_ = isPc ? kPrefixPcToHeadset : kPrefixHeadsetToPc;
    recvPrefix_ = isPc ? kPrefixHeadsetToPc : kPrefixPcToHeadset;
    sendCounter_ = 1;
    highest_ = 0;
    window_ = 0;
    ready_ = true;
  }
  bool ready() const { return ready_; }

  // Builds a sealed datagram into out. Returns its length.
  size_t seal(uint8_t type, const void* payload, size_t len, uint8_t* out) {
    if (len > kMaxPayload) return 0;
    uint64_t ctr = sendCounter_.fetch_add(1);
    out[0] = type;
    lvcrypto::store64(out + 1, ctr);
    memcpy(out + kHeaderBytes, payload, len);
    uint8_t nonce[12];
    lvcrypto::store32(nonce, sendPrefix_);
    lvcrypto::store64(nonce + 4, ctr);
    lvcrypto::seal(key_, nonce, out, kHeaderBytes, out + kHeaderBytes, len, out + kHeaderBytes + len);
    return kHeaderBytes + len + kTagBytes;
  }

  // Verifies + decrypts in place. On success payload/len point inside buf.
  bool open(uint8_t* buf, size_t n, uint8_t* type, uint8_t** payload, size_t* len) {
    if (!ready_ || n < kHeaderBytes + kTagBytes) return false;
    uint64_t ctr = 0;
    for (int i = 7; i >= 0; i--) ctr = (ctr << 8) | buf[1 + i];
    uint8_t nonce[12];
    lvcrypto::store32(nonce, recvPrefix_);
    lvcrypto::store64(nonce + 4, ctr);
    size_t plen = n - kHeaderBytes - kTagBytes;
    {
      std::lock_guard<std::mutex> l(m_);
      if (!acceptCounter(ctr, false)) return false;
    }
    if (!lvcrypto::open(key_, nonce, buf, kHeaderBytes, buf + kHeaderBytes, plen, buf + kHeaderBytes + plen)) return false;
    {
      std::lock_guard<std::mutex> l(m_);
      if (!acceptCounter(ctr, true)) return false;
    }
    *type = buf[0];
    *payload = buf + kHeaderBytes;
    *len = plen;
    return true;
  }

 private:
  // 64-packet sliding replay window.
  bool acceptCounter(uint64_t c, bool commit) {
    if (c == 0) return false;
    if (c > highest_) {
      if (commit) {
        uint64_t shift = c - highest_;
        window_ = shift >= 64 ? 0 : (window_ << shift);
        window_ |= 1;
        highest_ = c;
      }
      return true;
    }
    uint64_t off = highest_ - c;
    if (off >= 64) return false;
    if (window_ & (1ull << off)) return false;
    if (commit) window_ |= (1ull << off);
    return true;
  }

  std::mutex m_;
  uint8_t key_[32] = {};
  uint32_t sendPrefix_ = 0, recvPrefix_ = 0;
  std::atomic<uint64_t> sendCounter_{1};
  uint64_t highest_ = 0, window_ = 0;
  bool ready_ = false;
};

// Splits an encoded frame into video payloads (header + chunk).
inline std::vector<std::vector<uint8_t>> fragmentFrame(uint32_t frameIndex, const uint8_t* data, size_t size,
                                                       bool keyframe, uint64_t trackingTs, const Pose& head) {
  std::vector<std::vector<uint8_t>> out;
  uint16_t count = uint16_t((size + kVideoChunk - 1) / kVideoChunk);
  if (count == 0) count = 1;
  for (uint16_t i = 0; i < count; i++) {
    size_t off = size_t(i) * kVideoChunk;
    size_t n = size - off < kVideoChunk ? size - off : kVideoChunk;
    VideoHeader h{};
    h.frameIndex = frameIndex;
    h.fragIndex = i;
    h.fragCount = count;
    h.frameSize = uint32_t(size);
    h.flags = keyframe ? kVideoKeyframe : 0;
    h.trackingTimestampNs = trackingTs;
    h.renderHead = head;
    std::vector<uint8_t> p(sizeof(VideoHeader) + n);
    memcpy(p.data(), &h, sizeof h);
    memcpy(p.data() + sizeof h, data + off, n);
    out.push_back(std::move(p));
  }
  return out;
}

struct Frame {
  uint32_t index = 0;
  bool keyframe = false;
  uint64_t trackingTimestampNs = 0;
  Pose renderHead{};
  std::vector<uint8_t> data;
};

// Reassembles fragments. A frame that can no longer complete (a newer one
// finished first) marks the stream broken until the next keyframe, so the
// decoder never sees references to missing data.
class Reassembler {
 public:
  // Returns true and fills `out` when a decodable frame is complete.
  // Sets needIdr when a loss was detected.
  bool add(const uint8_t* payload, size_t len, Frame* out, bool* needIdr) {
    *needIdr = false;
    if (len < sizeof(VideoHeader)) return false;
    VideoHeader h;
    memcpy(&h, payload, sizeof h);
    if (h.fragCount == 0 || h.fragIndex >= h.fragCount || h.frameSize > (64u << 20)) return false;
    if (haveLast_ && int32_t(h.frameIndex - lastDone_) <= 0) return false;  // stale
    Pending& p = pending_[h.frameIndex];
    if (p.received.empty()) {
      p.received.assign(h.fragCount, false);
      p.frame.index = h.frameIndex;
      p.frame.keyframe = h.flags & kVideoKeyframe;
      p.frame.trackingTimestampNs = h.trackingTimestampNs;
      p.frame.renderHead = h.renderHead;
      p.frame.data.assign(h.frameSize, 0);
      p.count = 0;
    }
    if (p.received.size() != h.fragCount || p.received[h.fragIndex]) return false;
    size_t off = size_t(h.fragIndex) * kVideoChunk;
    size_t n = len - sizeof h;
    if (off + n > p.frame.data.size()) return false;
    memcpy(p.frame.data.data() + off, payload + sizeof h, n);
    p.received[h.fragIndex] = true;
    p.count++;
    if (p.count < h.fragCount) {
      if (pending_.size() > 8) pending_.erase(pending_.begin());
      return false;
    }
    Frame done = std::move(p.frame);
    // Anything older than this frame is now lost.
    bool lost = false;
    for (auto it = pending_.begin(); it != pending_.end();) {
      if (int32_t(it->first - done.index) < 0) {
        lost = true;
        it = pending_.erase(it);
      } else {
        ++it;
      }
    }
    pending_.erase(done.index);
    if (haveLast_ && done.index != lastDone_ + 1) lost = true;
    lastDone_ = done.index;
    haveLast_ = true;
    if (lost) broken_ = true;
    if (broken_ && !done.keyframe) {
      *needIdr = true;
      return false;
    }
    broken_ = false;
    *out = std::move(done);
    return true;
  }

 private:
  struct Pending {
    Frame frame;
    std::vector<bool> received;
    uint16_t count = 0;
  };
  std::map<uint32_t, Pending> pending_;
  uint32_t lastDone_ = 0;
  bool haveLast_ = false;
  bool broken_ = false;
};

}  // namespace lvvr
