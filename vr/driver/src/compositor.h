#pragma once
#include <d3d11_1.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

#include <map>
#include <mutex>
#include <vector>

#include "common.h"

// Owns the GPU side of the virtual display: swap textures for SteamVR's
// compositor (direct mode), layer composition into a side-by-side frame and
// RGB -> NV12 conversion for the encoder.
class Compositor {
 public:
  bool Init();
  ID3D11Device* Device() const { return device_.Get(); }
  ID3D11DeviceContext* Context() const { return ctx_.Get(); }
  uint64_t AdapterLuid() const { return luid_; }

  void CreateSwapTextureSet(uint32_t pid, const vr::IVRDriverDirectModeComponent::SwapTextureSetDesc_t* desc,
                            vr::IVRDriverDirectModeComponent::SwapTextureSet_t* out);
  void DestroySwapTextureSet(vr::SharedTextureHandle_t h);
  void DestroyAllSwapTextureSets(uint32_t pid);
  void GetNextSwapTextureSetIndex(vr::SharedTextureHandle_t handles[2], uint32_t (*indices)[2]);
  void SubmitLayer(const vr::IVRDriverDirectModeComponent::SubmitLayerPerEye_t (&perEye)[2]);

  // Composites the submitted layers into an eyeW*2 x eyeH NV12 frame.
  // Returns false if there was nothing to draw. `pose` receives the base layer's render pose.
  bool Present(vr::SharedTextureHandle_t sync, uint32_t eyeW, uint32_t eyeH, ID3D11Texture2D** nv12,
               vr::HmdMatrix34_t* pose);

 private:
  struct Tex {
    Microsoft::WRL::ComPtr<ID3D11Texture2D> tex;
    Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> srv;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> resolved;  // for MSAA sources
    Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> resolvedSrv;
    bool srgb = false;
    uint32_t pid = 0;
    int setId = 0;
    int index = 0;
  };
  struct Layer {
    vr::SharedTextureHandle_t tex[2];
    vr::VRTextureBounds_t bounds[2];
    vr::HmdMatrix34_t pose;
  };
  bool EnsureTargets(uint32_t w, uint32_t h);
  ID3D11ShaderResourceView* SrvFor(vr::SharedTextureHandle_t h, bool* srgb);

  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> ctx_;
  Microsoft::WRL::ComPtr<ID3D11VertexShader> vs_;
  Microsoft::WRL::ComPtr<ID3D11PixelShader> ps_;
  Microsoft::WRL::ComPtr<ID3D11Buffer> cb_;
  Microsoft::WRL::ComPtr<ID3D11SamplerState> sampler_;
  Microsoft::WRL::ComPtr<ID3D11BlendState> blendOpaque_, blendAlpha_;
  Microsoft::WRL::ComPtr<ID3D11RasterizerState> raster_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> rgbTarget_;  // B8G8R8A8_TYPELESS
  Microsoft::WRL::ComPtr<ID3D11RenderTargetView> rtvUnorm_, rtvSrgb_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> rgbCopy_;  // B8G8R8A8_UNORM for the video processor
  Microsoft::WRL::ComPtr<ID3D11Texture2D> nv12_;
  Microsoft::WRL::ComPtr<ID3D11VideoDevice> vdev_;
  Microsoft::WRL::ComPtr<ID3D11VideoContext> vctx_;
  Microsoft::WRL::ComPtr<ID3D11VideoProcessorEnumerator> vpEnum_;
  Microsoft::WRL::ComPtr<ID3D11VideoProcessor> vp_;
  Microsoft::WRL::ComPtr<ID3D11VideoProcessorInputView> vpIn_;
  Microsoft::WRL::ComPtr<ID3D11VideoProcessorOutputView> vpOut_;
  uint32_t targetW_ = 0, targetH_ = 0;
  uint64_t luid_ = 0;

  std::mutex mutex_;
  std::map<vr::SharedTextureHandle_t, Tex> textures_;
  std::map<vr::SharedTextureHandle_t, Microsoft::WRL::ComPtr<ID3D11Texture2D>> syncTextures_;
  std::vector<Layer> layers_;
  int nextSetId_ = 1;
};
