// ChaCha20-Poly1305 AEAD (RFC 8439), portable C++ (no dependencies).
// Used by the SteamVR driver and the headset app for the VR media channel.
#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace lvcrypto {

inline uint32_t rotl(uint32_t v, int c) { return (v << c) | (v >> (32 - c)); }
inline uint32_t load32(const uint8_t* p) {
  return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}
inline void store32(uint8_t* p, uint32_t v) {
  p[0] = uint8_t(v); p[1] = uint8_t(v >> 8); p[2] = uint8_t(v >> 16); p[3] = uint8_t(v >> 24);
}
inline void store64(uint8_t* p, uint64_t v) { store32(p, uint32_t(v)); store32(p + 4, uint32_t(v >> 32)); }

#define LV_QR(a, b, c, d) \
  a += b; d ^= a; d = rotl(d, 16); c += d; b ^= c; b = rotl(b, 12); \
  a += b; d ^= a; d = rotl(d, 8);  c += d; b ^= c; b = rotl(b, 7);

inline void chacha20_block(const uint8_t key[32], uint32_t counter, const uint8_t nonce[12], uint8_t out[64]) {
  uint32_t s[16] = {0x61707865, 0x3320646e, 0x79622d32, 0x6b206574};
  for (int i = 0; i < 8; i++) s[4 + i] = load32(key + 4 * i);
  s[12] = counter;
  for (int i = 0; i < 3; i++) s[13 + i] = load32(nonce + 4 * i);
  uint32_t x[16];
  memcpy(x, s, sizeof x);
  for (int i = 0; i < 10; i++) {
    LV_QR(x[0], x[4], x[8], x[12]) LV_QR(x[1], x[5], x[9], x[13]) LV_QR(x[2], x[6], x[10], x[14]) LV_QR(x[3], x[7], x[11], x[15])
    LV_QR(x[0], x[5], x[10], x[15]) LV_QR(x[1], x[6], x[11], x[12]) LV_QR(x[2], x[7], x[8], x[13]) LV_QR(x[3], x[4], x[9], x[14])
  }
  for (int i = 0; i < 16; i++) store32(out + 4 * i, x[i] + s[i]);
}
#undef LV_QR

inline void chacha20_xor(const uint8_t key[32], uint32_t counter, const uint8_t nonce[12], uint8_t* data, size_t len) {
  uint8_t block[64];
  while (len > 0) {
    chacha20_block(key, counter++, nonce, block);
    size_t n = len < 64 ? len : 64;
    for (size_t i = 0; i < n; i++) data[i] ^= block[i];
    data += n;
    len -= n;
  }
}

// Poly1305 (32-bit limbs, poly1305-donna style).
class Poly1305 {
 public:
  explicit Poly1305(const uint8_t key[32]) {
    r_[0] = (load32(key + 0)) & 0x3ffffff;
    r_[1] = (load32(key + 3) >> 2) & 0x3ffff03;
    r_[2] = (load32(key + 6) >> 4) & 0x3ffc0ff;
    r_[3] = (load32(key + 9) >> 6) & 0x3f03fff;
    r_[4] = (load32(key + 12) >> 8) & 0x00fffff;
    for (int i = 0; i < 4; i++) pad_[i] = load32(key + 16 + 4 * i);
  }
  void update(const uint8_t* m, size_t len) {
    if (leftover_) {
      size_t want = 16 - leftover_;
      if (want > len) want = len;
      memcpy(buf_ + leftover_, m, want);
      leftover_ += want; m += want; len -= want;
      if (leftover_ < 16) return;
      blocks(buf_, 16, false);
      leftover_ = 0;
    }
    if (len >= 16) {
      size_t n = len & ~size_t(15);
      blocks(m, n, false);
      m += n; len -= n;
    }
    if (len) { memcpy(buf_, m, len); leftover_ = len; }
  }
  // Pads the current partial block with zeros (AEAD construction).
  void pad16() {
    if (leftover_) {
      memset(buf_ + leftover_, 0, 16 - leftover_);
      blocks(buf_, 16, false);
      leftover_ = 0;
    }
  }
  void finish(uint8_t mac[16]) {
    if (leftover_) {
      buf_[leftover_] = 1;
      for (size_t i = leftover_ + 1; i < 16; i++) buf_[i] = 0;
      blocks(buf_, 16, true);
    }
    uint32_t h0 = h_[0], h1 = h_[1], h2 = h_[2], h3 = h_[3], h4 = h_[4], c;
    c = h1 >> 26; h1 &= 0x3ffffff; h2 += c;
    c = h2 >> 26; h2 &= 0x3ffffff; h3 += c;
    c = h3 >> 26; h3 &= 0x3ffffff; h4 += c;
    c = h4 >> 26; h4 &= 0x3ffffff; h0 += c * 5;
    c = h0 >> 26; h0 &= 0x3ffffff; h1 += c;
    uint32_t g0 = h0 + 5; c = g0 >> 26; g0 &= 0x3ffffff;
    uint32_t g1 = h1 + c; c = g1 >> 26; g1 &= 0x3ffffff;
    uint32_t g2 = h2 + c; c = g2 >> 26; g2 &= 0x3ffffff;
    uint32_t g3 = h3 + c; c = g3 >> 26; g3 &= 0x3ffffff;
    uint32_t g4 = h4 + c - (1u << 26);
    uint32_t mask = (g4 >> 31) - 1;
    g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask; g4 &= mask;
    mask = ~mask;
    h0 = (h0 & mask) | g0; h1 = (h1 & mask) | g1; h2 = (h2 & mask) | g2; h3 = (h3 & mask) | g3; h4 = (h4 & mask) | g4;
    h0 = (h0 | (h1 << 26)) & 0xffffffff;
    h1 = ((h1 >> 6) | (h2 << 20)) & 0xffffffff;
    h2 = ((h2 >> 12) | (h3 << 14)) & 0xffffffff;
    h3 = ((h3 >> 18) | (h4 << 8)) & 0xffffffff;
    uint64_t f;
    f = uint64_t(h0) + pad_[0]; h0 = uint32_t(f);
    f = uint64_t(h1) + pad_[1] + (f >> 32); h1 = uint32_t(f);
    f = uint64_t(h2) + pad_[2] + (f >> 32); h2 = uint32_t(f);
    f = uint64_t(h3) + pad_[3] + (f >> 32); h3 = uint32_t(f);
    store32(mac + 0, h0); store32(mac + 4, h1); store32(mac + 8, h2); store32(mac + 12, h3);
  }

 private:
  void blocks(const uint8_t* m, size_t bytes, bool final) {
    const uint32_t hibit = final ? 0 : (1u << 24);
    uint32_t r0 = r_[0], r1 = r_[1], r2 = r_[2], r3 = r_[3], r4 = r_[4];
    uint32_t s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5;
    uint32_t h0 = h_[0], h1 = h_[1], h2 = h_[2], h3 = h_[3], h4 = h_[4];
    while (bytes >= 16) {
      h0 += (load32(m + 0)) & 0x3ffffff;
      h1 += (load32(m + 3) >> 2) & 0x3ffffff;
      h2 += (load32(m + 6) >> 4) & 0x3ffffff;
      h3 += (load32(m + 9) >> 6) & 0x3ffffff;
      h4 += (load32(m + 12) >> 8) | hibit;
      uint64_t d0 = uint64_t(h0) * r0 + uint64_t(h1) * s4 + uint64_t(h2) * s3 + uint64_t(h3) * s2 + uint64_t(h4) * s1;
      uint64_t d1 = uint64_t(h0) * r1 + uint64_t(h1) * r0 + uint64_t(h2) * s4 + uint64_t(h3) * s3 + uint64_t(h4) * s2;
      uint64_t d2 = uint64_t(h0) * r2 + uint64_t(h1) * r1 + uint64_t(h2) * r0 + uint64_t(h3) * s4 + uint64_t(h4) * s3;
      uint64_t d3 = uint64_t(h0) * r3 + uint64_t(h1) * r2 + uint64_t(h2) * r1 + uint64_t(h3) * r0 + uint64_t(h4) * s4;
      uint64_t d4 = uint64_t(h0) * r4 + uint64_t(h1) * r3 + uint64_t(h2) * r2 + uint64_t(h3) * r1 + uint64_t(h4) * r0;
      uint32_t c = uint32_t(d0 >> 26); h0 = uint32_t(d0) & 0x3ffffff;
      d1 += c; c = uint32_t(d1 >> 26); h1 = uint32_t(d1) & 0x3ffffff;
      d2 += c; c = uint32_t(d2 >> 26); h2 = uint32_t(d2) & 0x3ffffff;
      d3 += c; c = uint32_t(d3 >> 26); h3 = uint32_t(d3) & 0x3ffffff;
      d4 += c; c = uint32_t(d4 >> 26); h4 = uint32_t(d4) & 0x3ffffff;
      h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff;
      h1 += c;
      m += 16;
      bytes -= 16;
    }
    h_[0] = h0; h_[1] = h1; h_[2] = h2; h_[3] = h3; h_[4] = h4;
  }
  uint32_t r_[5];
  uint32_t h_[5] = {0, 0, 0, 0, 0};
  uint32_t pad_[4];
  uint8_t buf_[16];
  size_t leftover_ = 0;
};

inline void aead_tag(const uint8_t key[32], const uint8_t nonce[12], const uint8_t* aad, size_t aadLen,
                     const uint8_t* ct, size_t ctLen, uint8_t tag[16]) {
  uint8_t otk[64];
  chacha20_block(key, 0, nonce, otk);
  Poly1305 p(otk);
  p.update(aad, aadLen); p.pad16();
  p.update(ct, ctLen); p.pad16();
  uint8_t lens[16];
  store64(lens, aadLen); store64(lens + 8, ctLen);
  p.update(lens, 16);
  p.finish(tag);
}

// Encrypts data in place and writes the 16-byte tag.
inline void seal(const uint8_t key[32], const uint8_t nonce[12], const uint8_t* aad, size_t aadLen, uint8_t* data,
                 size_t len, uint8_t tag[16]) {
  chacha20_xor(key, 1, nonce, data, len);
  aead_tag(key, nonce, aad, aadLen, data, len, tag);
}

// Verifies the tag (constant time) and decrypts in place. Returns false on forgery.
inline bool open(const uint8_t key[32], const uint8_t nonce[12], const uint8_t* aad, size_t aadLen, uint8_t* data,
                 size_t len, const uint8_t tag[16]) {
  uint8_t expect[16];
  aead_tag(key, nonce, aad, aadLen, data, len, expect);
  uint8_t diff = 0;
  for (int i = 0; i < 16; i++) diff |= uint8_t(expect[i] ^ tag[i]);
  if (diff != 0) return false;
  chacha20_xor(key, 1, nonce, data, len);
  return true;
}

}  // namespace lvcrypto
