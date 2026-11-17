#include "network.h"

#include "common.h"

#pragma comment(lib, "ws2_32.lib")

bool Network::Start(uint16_t port, const uint8_t key[32], Handler h) {
  WSADATA wsa;
  WSAStartup(MAKEWORD(2, 2), &wsa);
  handler_ = std::move(h);
  link_.reset(key, true);
  sock_ = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
  if (sock_ == INVALID_SOCKET) return false;
  DWORD off = 0;
  setsockopt(sock_, IPPROTO_IPV6, IPV6_V6ONLY, reinterpret_cast<const char*>(&off), sizeof off);
  int buf = 8 << 20;
  setsockopt(sock_, SOL_SOCKET, SO_SNDBUF, reinterpret_cast<const char*>(&buf), sizeof buf);
  setsockopt(sock_, SOL_SOCKET, SO_RCVBUF, reinterpret_cast<const char*>(&buf), sizeof buf);
  DWORD timeout = 200;
  setsockopt(sock_, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeout), sizeof timeout);
  sockaddr_in6 addr = {};
  addr.sin6_family = AF_INET6;
  addr.sin6_port = htons(port);
  addr.sin6_addr = in6addr_any;
  if (bind(sock_, reinterpret_cast<sockaddr*>(&addr), sizeof addr) != 0) {
    LvLog("UDP bind on port %u failed (%d)", port, WSAGetLastError());
    closesocket(sock_);
    sock_ = INVALID_SOCKET;
    return false;
  }
  running_ = true;
  thread_ = std::thread([this] { Loop(); });
  LvLog("listening for the headset on UDP %u", port);
  return true;
}

void Network::Stop() {
  running_ = false;
  if (thread_.joinable()) thread_.join();
  if (sock_ != INVALID_SOCKET) closesocket(sock_);
  sock_ = INVALID_SOCKET;
}

void Network::Loop() {
  uint8_t buf[2048];
  while (running_) {
    sockaddr_storage from = {};
    int fromLen = sizeof from;
    int n = recvfrom(sock_, reinterpret_cast<char*>(buf), sizeof buf, 0, reinterpret_cast<sockaddr*>(&from), &fromLen);
    if (n <= 0) continue;
    uint8_t type;
    uint8_t* payload;
    size_t len;
    if (!link_.open(buf, size_t(n), &type, &payload, &len)) continue;  // not ours / forged / replayed
    {
      std::lock_guard<std::mutex> l(peerMutex_);
      if (!hasPeer_ || memcmp(&peer_, &from, fromLen) != 0) {
        peer_ = from;
        peerLen_ = fromLen;
        if (!hasPeer_) LvLog("headset connected");
        hasPeer_ = true;
      }
    }
    handler_(type, payload, len);
  }
}

void Network::Send(uint8_t type, const void* payload, size_t len) {
  if (!hasPeer_ || sock_ == INVALID_SOCKET) return;
  uint8_t out[lvvr::kMaxDatagram];
  size_t n = link_.seal(type, payload, len, out);
  if (n == 0) return;
  std::lock_guard<std::mutex> l(peerMutex_);
  sendto(sock_, reinterpret_cast<const char*>(out), int(n), 0, reinterpret_cast<const sockaddr*>(&peer_), peerLen_);
}
