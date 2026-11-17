#pragma once
#include <winsock2.h>
#include <ws2tcpip.h>

#include <atomic>
#include <functional>
#include <mutex>
#include <thread>

#include "vrproto.h"

// Encrypted UDP endpoint. The headset address is learned from the first
// authenticated datagram (works through NAT when the port is forwarded).
class Network {
 public:
  using Handler = std::function<void(uint8_t type, const uint8_t* payload, size_t len)>;
  bool Start(uint16_t port, const uint8_t key[32], Handler h);
  void Stop();
  void Send(uint8_t type, const void* payload, size_t len);
  bool HasPeer() const { return hasPeer_; }

 private:
  void Loop();
  SOCKET sock_ = INVALID_SOCKET;
  lvvr::SecureLink link_;
  Handler handler_;
  std::thread thread_;
  std::atomic<bool> running_{false};
  std::mutex peerMutex_;
  sockaddr_storage peer_ = {};
  int peerLen_ = 0;
  std::atomic<bool> hasPeer_{false};
};
