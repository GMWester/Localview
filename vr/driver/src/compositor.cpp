#include "compositor.h"

#include <d3dcompiler.h>

using Microsoft::WRL::ComPtr;

namespace {
const char* kShader = R"(
cbuffer C : register(b0) { float4 bounds; };
struct V { float4 pos : SV_Position; float2 uv : TEXCOORD0; };
V vs(uint id : SV_VertexID) {
  V o;
  float2 t = float2((id << 1) & 2, id & 2);
  o.pos = float4(t * float2(2, -2) + float2(-1, 1), 0, 1);
  o.uv = lerp(bounds.xy, bounds.zw, t);
  return o;
}
Texture2D tex : register(t0);
SamplerState smp : register(s0);
float4 ps(V i) : SV_Target { return tex.Sample(smp, i.uv); }
)";

DXGI_FORMAT ViewFormat(DXGI_FORMAT f, bool* srgb) {
  *srgb = false;
  switch (f) {
    case DXGI_FORMAT_R8G8B8A8_TYPELESS: return DXGI_FORMAT_R8G8B8A8_UNORM;
    case DXGI_FORMAT_B8G8R8A8_TYPELESS: return DXGI_FORMAT_B8G8R8A8_UNORM;
    case DXGI_FORMAT_B8G8R8X8_TYPELESS: return DXGI_FORMAT_B8G8R8X8_UNORM;
    case DXGI_FORMAT_R10G10B10A2_TYPELESS: return DXGI_FORMAT_R10G10B10A2_UNORM;
    case DXGI_FORMAT_R16G16B16A16_TYPELESS: return DXGI_FORMAT_R16G16B16A16_FLOAT;
    case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
    case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
    case DXGI_FORMAT_B8G8R8X8_UNORM_SRGB:
      *srgb = true;
      return f;
    case DXGI_FORMAT_R16G16B16A16_FLOAT:
    case DXGI_FORMAT_R11G11B10_FLOAT:
      *srgb = true;  // linear float: needs sRGB encoding on output
      return f;
    default: return f;
  }
}
}  // namespace

bool Compositor::Init() {
  ComPtr<IDXGIFactory6> factory;
  ComPtr<IDXGIAdapter1> adapter;
  if (SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
    factory->EnumAdapterByGpuPreference(0, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE, IID_PPV_ARGS(&adapter));
  }
  D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
  HRESULT hr = D3D11CreateDevice(adapter.Get(), adapter ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 flags, levels, 2, D3D11_SDK_VERSION, &device_, nullptr, &ctx_);
  if (FAILED(hr)) {
    LvLog("D3D11CreateDevice failed 0x%08x", hr);
    return false;
  }
  if (adapter) {
    DXGI_ADAPTER_DESC1 d;
    adapter->GetDesc1(&d);
    luid_ = (uint64_t(uint32_t(d.AdapterLuid.HighPart)) << 32) | d.AdapterLuid.LowPart;
    LvLog("GPU: %ls", d.Description);
  }
  ComPtr<ID3DBlob> vsb, psb, err;
  if (FAILED(D3DCompile(kShader, strlen(kShader), "lv", nullptr, nullptr, "vs", "vs_5_0", 0, 0, &vsb, &err)) ||
      FAILED(D3DCompile(kShader, strlen(kShader), "lv", nullptr, nullptr, "ps", "ps_5_0", 0, 0, &psb, &err))) {
    LvLog("shader compile failed: %s", err ? static_cast<const char*>(err->GetBufferPointer()) : "?");
    return false;
  }
  device_->CreateVertexShader(vsb->GetBufferPointer(), vsb->GetBufferSize(), nullptr, &vs_);
  device_->CreatePixelShader(psb->GetBufferPointer(), psb->GetBufferSize(), nullptr, &ps_);
  D3D11_BUFFER_DESC bd = {};
  bd.ByteWidth = 16;
  bd.Usage = D3D11_USAGE_DEFAULT;
  bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
  device_->CreateBuffer(&bd, nullptr, &cb_);
  D3D11_SAMPLER_DESC sd = {};
  sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
  sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
  sd.MaxLOD = D3D11_FLOAT32_MAX;
  device_->CreateSamplerState(&sd, &sampler_);
  D3D11_BLEND_DESC b = {};
  b.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
  device_->CreateBlendState(&b, &blendOpaque_);
  b.RenderTarget[0].BlendEnable = TRUE;
  b.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
  b.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
  b.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
  b.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
  b.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
  b.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
  device_->CreateBlendState(&b, &blendAlpha_);
  D3D11_RASTERIZER_DESC rd = {};
  rd.FillMode = D3D11_FILL_SOLID;
  rd.CullMode = D3D11_CULL_NONE;
  device_->CreateRasterizerState(&rd, &raster_);
  device_.As(&vdev_);
  ctx_.As(&vctx_);
  return vdev_ && vctx_;
}

void Compositor::CreateSwapTextureSet(uint32_t pid, const vr::IVRDriverDirectModeComponent::SwapTextureSetDesc_t* desc,
                                      vr::IVRDriverDirectModeComponent::SwapTextureSet_t* out) {
  std::lock_guard<std::mutex> l(mutex_);
  D3D11_TEXTURE2D_DESC td = {};
  td.Width = desc->nWidth;
  td.Height = desc->nHeight;
  td.MipLevels = 1;
  td.ArraySize = 1;
  td.Format = DXGI_FORMAT(desc->nFormat);
  td.SampleDesc.Count = desc->nSampleCount ? desc->nSampleCount : 1;
  td.Usage = D3D11_USAGE_DEFAULT;
  td.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
  td.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  int setId = nextSetId_++;
  for (int i = 0; i < 3; i++) {
    Tex t;
    if (FAILED(device_->CreateTexture2D(&td, nullptr, &t.tex))) {
      LvLog("CreateSwapTextureSet failed (%ux%u fmt %u)", desc->nWidth, desc->nHeight, desc->nFormat);
      out->rSharedTextureHandles[i] = 0;
      continue;
    }
    ComPtr<IDXGIResource> res;
    HANDLE h = nullptr;
    if (SUCCEEDED(t.tex.As(&res))) res->GetSharedHandle(&h);
    t.pid = pid;
    t.setId = setId;
    t.index = i;
    auto handle = reinterpret_cast<vr::SharedTextureHandle_t>(h);
    out->rSharedTextureHandles[i] = handle;
    textures_[handle] = t;
  }
  out->unTextureFlags = 0;
}

void Compositor::DestroySwapTextureSet(vr::SharedTextureHandle_t h) {
  std::lock_guard<std::mutex> l(mutex_);
  auto it = textures_.find(h);
  if (it == textures_.end()) return;
  int set = it->second.setId;
  for (auto i = textures_.begin(); i != textures_.end();) {
    if (i->second.setId == set) i = textures_.erase(i); else ++i;
  }
}

void Compositor::DestroyAllSwapTextureSets(uint32_t pid) {
  std::lock_guard<std::mutex> l(mutex_);
  for (auto i = textures_.begin(); i != textures_.end();) {
    if (i->second.pid == pid) i = textures_.erase(i); else ++i;
  }
}

void Compositor::GetNextSwapTextureSetIndex(vr::SharedTextureHandle_t handles[2], uint32_t (*indices)[2]) {
  std::lock_guard<std::mutex> l(mutex_);
  for (int e = 0; e < 2; e++) {
    auto it = textures_.find(handles[e]);
    (*indices)[e] = it == textures_.end() ? 0 : uint32_t((it->second.index + 1) % 3);
  }
}

void Compositor::SubmitLayer(const vr::IVRDriverDirectModeComponent::SubmitLayerPerEye_t (&perEye)[2]) {
  std::lock_guard<std::mutex> l(mutex_);
  Layer layer;
  for (int e = 0; e < 2; e++) {
    layer.tex[e] = perEye[e].hTexture;
    layer.bounds[e] = perEye[e].bounds;
  }
  layer.pose = perEye[0].mHmdPose;
  if (layers_.size() < 16) layers_.push_back(layer);
}

ID3D11ShaderResourceView* Compositor::SrvFor(vr::SharedTextureHandle_t h, bool* srgb) {
  auto it = textures_.find(h);
  if (it == textures_.end()) return nullptr;
  Tex& t = it->second;
  D3D11_TEXTURE2D_DESC td;
  t.tex->GetDesc(&td);
  if (!t.srv) {
    DXGI_FORMAT vf = ViewFormat(td.Format, &t.srgb);
    if (td.SampleDesc.Count > 1) {
      D3D11_TEXTURE2D_DESC rd = td;
      rd.SampleDesc.Count = 1;
      rd.MiscFlags = 0;
      rd.Format = td.Format;
      device_->CreateTexture2D(&rd, nullptr, &t.resolved);
      D3D11_SHADER_RESOURCE_VIEW_DESC sv = {};
      sv.Format = vf;
      sv.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
      sv.Texture2D.MipLevels = 1;
      device_->CreateShaderResourceView(t.resolved.Get(), &sv, &t.resolvedSrv);
      t.srv = t.resolvedSrv;
    } else {
      D3D11_SHADER_RESOURCE_VIEW_DESC sv = {};
      sv.Format = vf;
      sv.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
      sv.Texture2D.MipLevels = 1;
      device_->CreateShaderResourceView(t.tex.Get(), &sv, &t.srv);
    }
  }
  if (t.resolved) {
    bool s;
    ctx_->ResolveSubresource(t.resolved.Get(), 0, t.tex.Get(), 0, ViewFormat(td.Format, &s));
  }
  *srgb = t.srgb;
  return t.srv.Get();
}

bool Compositor::EnsureTargets(uint32_t w, uint32_t h) {
  if (w == targetW_ && h == targetH_ && nv12_) return true;
  D3D11_TEXTURE2D_DESC td = {};
  td.Width = w;
  td.Height = h;
  td.MipLevels = 1;
  td.ArraySize = 1;
  td.Format = DXGI_FORMAT_B8G8R8A8_TYPELESS;
  td.SampleDesc.Count = 1;
  td.Usage = D3D11_USAGE_DEFAULT;
  td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  if (FAILED(device_->CreateTexture2D(&td, nullptr, &rgbTarget_))) return false;
  D3D11_RENDER_TARGET_VIEW_DESC rv = {};
  rv.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
  rv.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  device_->CreateRenderTargetView(rgbTarget_.Get(), &rv, &rtvUnorm_);
  rv.Format = DXGI_FORMAT_B8G8R8A8_UNORM_SRGB;
  device_->CreateRenderTargetView(rgbTarget_.Get(), &rv, &rtvSrgb_);
  td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  if (FAILED(device_->CreateTexture2D(&td, nullptr, &rgbCopy_))) return false;
  td.Format = DXGI_FORMAT_NV12;
  td.BindFlags = D3D11_BIND_RENDER_TARGET;
  if (FAILED(device_->CreateTexture2D(&td, nullptr, &nv12_))) return false;

  D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd = {};
  cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
  cd.InputWidth = cd.OutputWidth = w;
  cd.InputHeight = cd.OutputHeight = h;
  cd.InputFrameRate = {90, 1};
  cd.OutputFrameRate = {90, 1};
  cd.Usage = D3D11_VIDEO_USAGE_OPTIMAL_SPEED;
  if (FAILED(vdev_->CreateVideoProcessorEnumerator(&cd, &vpEnum_)) || FAILED(vdev_->CreateVideoProcessor(vpEnum_.Get(), 0, &vp_))) {
    LvLog("video processor unavailable");
    return false;
  }
  D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC iv = {};
  iv.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
  if (FAILED(vdev_->CreateVideoProcessorInputView(rgbCopy_.Get(), vpEnum_.Get(), &iv, &vpIn_))) return false;
  D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ov = {};
  ov.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
  if (FAILED(vdev_->CreateVideoProcessorOutputView(nv12_.Get(), vpEnum_.Get(), &ov, &vpOut_))) return false;
  D3D11_VIDEO_PROCESSOR_COLOR_SPACE in = {};
  in.RGB_Range = 0;  // full-range RGB
  D3D11_VIDEO_PROCESSOR_COLOR_SPACE out = {};
  out.YCbCr_Matrix = 1;  // BT.709
  out.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
  vctx_->VideoProcessorSetStreamColorSpace(vp_.Get(), 0, &in);
  vctx_->VideoProcessorSetOutputColorSpace(vp_.Get(), &out);
  vctx_->VideoProcessorSetStreamAutoProcessingMode(vp_.Get(), 0, FALSE);
  targetW_ = w;
  targetH_ = h;
  return true;
}

bool Compositor::Present(vr::SharedTextureHandle_t sync, uint32_t eyeW, uint32_t eyeH, ID3D11Texture2D** nv12,
                         vr::HmdMatrix34_t* pose) {
  std::lock_guard<std::mutex> l(mutex_);
  std::vector<Layer> layers;
  layers.swap(layers_);
  if (layers.empty()) return false;
  if (!EnsureTargets(eyeW * 2, eyeH)) return false;

  // The compositor signals completion of its rendering through a keyed mutex on the sync texture.
  ComPtr<IDXGIKeyedMutex> km;
  if (sync) {
    auto& st = syncTextures_[sync];
    if (!st) device_->OpenSharedResource(reinterpret_cast<HANDLE>(sync), IID_PPV_ARGS(&st));
    if (st) st.As(&km);
  }
  if (km && km->AcquireSync(0, 10) != S_OK) km.Reset();

  ctx_->VSSetShader(vs_.Get(), nullptr, 0);
  ctx_->PSSetShader(ps_.Get(), nullptr, 0);
  ctx_->IASetInputLayout(nullptr);
  ctx_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  ctx_->VSSetConstantBuffers(0, 1, cb_.GetAddressOf());
  ctx_->PSSetSamplers(0, 1, sampler_.GetAddressOf());
  ctx_->RSSetState(raster_.Get());
  float black[4] = {0, 0, 0, 1};
  ctx_->ClearRenderTargetView(rtvUnorm_.Get(), black);
  for (size_t li = 0; li < layers.size(); li++) {
    const Layer& layer = layers[li];
    ctx_->OMSetBlendState(li == 0 ? blendOpaque_.Get() : blendAlpha_.Get(), nullptr, 0xffffffff);
    for (int e = 0; e < 2; e++) {
      bool srgb = false;
      ID3D11ShaderResourceView* srv = SrvFor(layer.tex[e], &srgb);
      if (!srv) continue;
      ID3D11RenderTargetView* rtv = srgb ? rtvSrgb_.Get() : rtvUnorm_.Get();
      ctx_->OMSetRenderTargets(1, &rtv, nullptr);
      D3D11_VIEWPORT vp = {float(e * eyeW), 0, float(eyeW), float(eyeH), 0, 1};
      ctx_->RSSetViewports(1, &vp);
      const vr::VRTextureBounds_t& b = layer.bounds[e];
      float bounds[4] = {b.uMin, b.vMin, b.uMax, b.vMax};
      ctx_->UpdateSubresource(cb_.Get(), 0, nullptr, bounds, 0, 0);
      ctx_->PSSetShaderResources(0, 1, &srv);
      ctx_->Draw(3, 0);
    }
  }
  ID3D11ShaderResourceView* nullSrv = nullptr;
  ctx_->PSSetShaderResources(0, 1, &nullSrv);
  ctx_->OMSetRenderTargets(0, nullptr, nullptr);
  if (km) km->ReleaseSync(0);

  ctx_->CopyResource(rgbCopy_.Get(), rgbTarget_.Get());
  D3D11_VIDEO_PROCESSOR_STREAM stream = {};
  stream.Enable = TRUE;
  stream.pInputSurface = vpIn_.Get();
  if (FAILED(vctx_->VideoProcessorBlt(vp_.Get(), vpOut_.Get(), 0, 1, &stream))) return false;
  *nv12 = nv12_.Get();
  *pose = layers[0].pose;
  return true;
}
